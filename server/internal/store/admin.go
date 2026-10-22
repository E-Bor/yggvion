package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"yggvion/server/internal/domain"
)

func RandomSecret() string {
	var b [32]byte
	// crypto/rand.Read never returns an error on supported Go platforms.
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (s *Store) Generation(ctx context.Context) (string, error) {
	var generation string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='generation'").Scan(&generation)
	return generation, err
}

func (s *Store) Invite(ctx context.Context, issuer string) (string, error) {
	secret := RandomSecret()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM invitations WHERE expires<=?", time.Now().Unix()); err != nil {
		return "", err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM invitations").Scan(&count); err != nil {
		return "", err
	}
	if count >= 32 {
		return "", errors.New("too many invitations")
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO invitations(token_hash,expires,issuer) VALUES(?,?,?)", hash(secret), time.Now().Add(10*time.Minute).Unix(), issuer); err != nil {
		return "", err
	}
	return secret, tx.Commit()
}

// PairInvitation consumes the code and creates the device in one transaction.
func (s *Store) PairInvitation(ctx context.Context, secret, name string) (string, string, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE token_hash=? AND expires>? AND
 (issuer='bootstrap' OR EXISTS(SELECT 1 FROM devices WHERE id=issuer AND revoked=0))`, hash(secret), time.Now().Unix())
	if err != nil {
		return "", "", err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return "", "", err
	}
	if count != 1 {
		return "", "", sql.ErrNoRows
	}
	id, token := RandomSecret()[:32], RandomSecret()
	if _, err = tx.ExecContext(ctx, "INSERT INTO devices(id,name,token_hash) VALUES(?,?,?)", id, name, hash(token)); err != nil {
		return "", "", err
	}
	return id, token, tx.Commit()
}

type Attachment struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	MediaType string `json:"media_type"`
}

type Snapshot struct {
	PasswordEnvelope *domain.PasswordEnvelope `json:"password_envelope"`
	EncryptionKeyID  string                   `json:"encryption_key_id"`
	Format           int                      `json:"format"`
	Created          time.Time                `json:"created"`
	Records          []domain.Record          `json:"records"`
	Attachments      []Attachment             `json:"attachments"`
}

// Export uses a consistent SQLite read transaction, including committed WAL data.
// Device credentials, invitations and TLS keys are intentionally not exported.
func (s *Store) Export(ctx context.Context) (Snapshot, error) {
	out := Snapshot{Format: 2, Created: time.Now().UTC(), Records: []domain.Record{}, Attachments: []Attachment{}}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return out, err
	}
	defer tx.Rollback()
	out.EncryptionKeyID, err = encryptionKey(ctx, tx)
	if err != nil {
		return out, err
	}
	out.PasswordEnvelope, err = passwordEnvelope(ctx, tx)
	if err != nil {
		return out, err
	}
	rows, err := tx.QueryContext(ctx, "SELECT id,kind,version,deleted,data,seq FROM records ORDER BY id")
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var r domain.Record
		var data string
		if err = rows.Scan(&r.ID, &r.Kind, &r.Version, &r.Deleted, &data, &r.Seq); err != nil {
			rows.Close()
			return out, err
		}
		r.Data = json.RawMessage(data)
		out.Records = append(out.Records, r)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return out, err
	}
	rows, err = tx.QueryContext(ctx, "SELECT id,name,size,media_type FROM attachments ORDER BY id")
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var a Attachment
		if err = rows.Scan(&a.ID, &a.Name, &a.Size, &a.MediaType); err != nil {
			rows.Close()
			return out, err
		}
		out.Attachments = append(out.Attachments, a)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return out, err
	}
	if err = ValidateSnapshot(out); err != nil {
		return out, err
	}
	return out, tx.Commit()
}

func ValidateSnapshot(v Snapshot) error {
	if v.Format != 2 || v.Created.IsZero() || v.Created.After(time.Now().Add(time.Minute)) ||
		!domain.ValidHash(v.EncryptionKeyID) || v.PasswordEnvelope == nil ||
		v.PasswordEnvelope.Validate() != nil || v.PasswordEnvelope.KeyID != v.EncryptionKeyID {
		return ErrInvalid
	}
	files := make(map[string]bool, len(v.Attachments))
	for _, a := range v.Attachments {
		if !domain.ValidHash(a.ID) || files[a.ID] || a.Size < 0 || a.Size > 301*1024*1024 ||
			a.Name != "encrypted" || a.MediaType != "application/octet-stream" {
			return ErrInvalid
		}
		files[a.ID] = true
	}
	records := make(map[string]bool, len(v.Records))
	for _, r := range v.Records {
		if records[r.ID] {
			return ErrInvalid
		}
		records[r.ID] = true
		envelope, err := domain.ReadEnvelope(r)
		if err != nil || envelope.KeyID != v.EncryptionKeyID {
			return ErrInvalid
		}
		for _, id := range envelope.Files {
			if !files[id] {
				return ErrInvalid
			}
		}
	}
	return nil
}

// Restore replaces only user data in a single transaction. Authentication and
// current device revocations survive. The caller holds the API maintenance lock.
func (s *Store) Restore(ctx context.Context, v Snapshot) error {
	if err := ValidateSnapshot(v); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	keyID, err := encryptionKey(ctx, tx)
	if err != nil {
		return err
	}
	currentPassword, err := passwordEnvelope(ctx, tx)
	if err != nil {
		return err
	}
	if keyID == v.EncryptionKeyID && currentPassword != nil {
		v.PasswordEnvelope = currentPassword
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM server_meta WHERE key='password_envelope'"); err != nil {
		return err
	}
	data, err := json.Marshal(v.PasswordEnvelope)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO server_meta VALUES('password_envelope',?)", string(data)); err != nil {
		return err
	}
	for _, table := range []string{"records", "changes", "operations", "attachments", "invitations", "calendar_shares", "guest_inbox", "encrypted_uploads"} {
		if _, err = tx.ExecContext(ctx, "DELETE FROM "+table); err != nil {
			return err
		}
	}
	for _, r := range v.Records {
		r.Version = 0
		if _, err = save(ctx, tx, r); err != nil {
			return err
		}
	}
	for _, a := range v.Attachments {
		if _, err = tx.ExecContext(ctx, "INSERT INTO attachments VALUES(?,?,?,?)", a.ID, a.Name, a.Size, a.MediaType); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta VALUES('encryption_key_id',?)", v.EncryptionKeyID); err != nil {
		return err
	}
	for _, a := range v.Attachments {
		if _, err = tx.ExecContext(ctx, "INSERT INTO encrypted_uploads VALUES(?,?)", a.ID, v.EncryptionKeyID); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta SELECT 'snapshot_cursor', CAST(COALESCE(MAX(seq),0) AS TEXT) FROM changes"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta VALUES('generation_reason','restore')"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta VALUES('snapshot_created',?)", v.Created.Format(time.RFC3339Nano)); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE server_meta SET value=? WHERE key='generation'", RandomSecret()); err != nil {
		return err
	}
	return tx.Commit()
}
