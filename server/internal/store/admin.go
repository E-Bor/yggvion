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

func (s *Store) Generation(ctx context.Context) (string, bool, error) {
	var generation string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='generation'").Scan(&generation)
	var count int
	if err == nil {
		err = s.DB.QueryRowContext(ctx, "SELECT count(*) FROM server_meta WHERE key='restored'").Scan(&count)
	}
	return generation, count > 0, err
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
	if _, err = tx.ExecContext(ctx, "INSERT INTO invitations VALUES(?,?,?)", hash(secret), time.Now().Add(10*time.Minute).Unix(), issuer); err != nil {
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
	n, err := result.RowsAffected()
	if err != nil || n != 1 {
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
	Format      int             `json:"format"`
	Created     time.Time       `json:"created"`
	Records     []domain.Record `json:"records"`
	Attachments []Attachment    `json:"attachments"`
}

// Export uses a consistent SQLite read transaction, including committed WAL data.
// Device credentials, invitations and TLS keys are intentionally not exported.
func (s *Store) Export(ctx context.Context) (Snapshot, error) {
	out := Snapshot{Format: 1, Created: time.Now().UTC(), Records: []domain.Record{}, Attachments: []Attachment{}}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return out, err
	}
	defer tx.Rollback()
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
	return out, tx.Commit()
}

func ValidateSnapshot(v Snapshot) error {
	if v.Format != 1 || v.Created.IsZero() || v.Created.After(time.Now().Add(time.Minute)) {
		return ErrInvalid
	}
	byID := map[string]domain.Record{}
	for _, r := range v.Records {
		if _, ok := byID[r.ID]; ok {
			return ErrInvalid
		}
		if err := domain.Validate(r); err != nil {
			return err
		}
		byID[r.ID] = r
	}
	for _, r := range v.Records {
		if r.Deleted {
			continue
		}
		var d map[string]any
		if err := json.Unmarshal(r.Data, &d); err != nil {
			return err
		}
		for field, kind := range map[string]string{"project_id": "project", "task_id": "task"} {
			id, _ := d[field].(string)
			if id != "" {
				parent, ok := byID[id]
				if !ok || parent.Kind != kind {
					return ErrInvalid
				}
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
	for _, table := range []string{"records", "changes", "operations", "attachments", "invitations", "calendar_shares"} {
		if _, err = tx.ExecContext(ctx, "DELETE FROM "+table); err != nil {
			return err
		}
	}
	for _, r := range v.Records {
		if r.Kind == "session" && !r.Deleted {
			var d map[string]any
			if err = json.Unmarshal(r.Data, &d); err != nil {
				return err
			}
			if d["end"] == nil {
				var start time.Time
				if text, ok := d["start"].(string); ok {
					start, err = time.Parse(time.RFC3339Nano, text)
				}
				if err != nil || start.After(v.Created) {
					return ErrInvalid
				}
				d["end"] = v.Created.Format(time.RFC3339Nano)
				r.Data, err = json.Marshal(d)
				if err != nil {
					return err
				}
			}
		}
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
	if _, err = tx.ExecContext(ctx, "UPDATE server_meta SET value=? WHERE key='generation'", RandomSecret()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta(key,value) VALUES('restored',?)", time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
		return err
	}
	return tx.Commit()
}
