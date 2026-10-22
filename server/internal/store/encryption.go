package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"yggvion/server/internal/domain"
)

func encryptionKey(ctx context.Context, tx *sql.Tx) (string, error) {
	var key string
	err := tx.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='encryption_key_id'").Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return key, err
}

func (s *Store) EncryptionKey(ctx context.Context) (string, error) {
	var key string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='encryption_key_id'").Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return key, err
}

// EnableEncryption initializes an empty workspace before its first upload.
func (s *Store) EnableEncryption(ctx context.Context, keyID string, envelope domain.PasswordConfig) error {
	if !domain.ValidHash(keyID) || envelope.Validate() != nil || envelope.KeyID != keyID {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	current, err := encryptionKey(ctx, tx)
	if err != nil {
		return err
	}
	if current != "" {
		password, err := passwordConfig(ctx, tx)
		if err != nil {
			return err
		}
		if current == keyID && password != nil && password.KeyID == keyID {
			return nil
		}
		return ErrConflict
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM records)+(SELECT count(*) FROM attachments)").Scan(&count); err != nil {
		return err
	}
	if count != 0 {
		return ErrConflict
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO server_meta VALUES('encryption_key_id',?)", keyID); err != nil {
		return err
	}
	data, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO server_meta VALUES('password_config',?)", string(data)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) GuestProposals(ctx context.Context) ([]domain.Record, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT id,data FROM guest_inbox ORDER BY created,id LIMIT 100")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	records := []domain.Record{}
	for rows.Next() {
		var id, data string
		if err = rows.Scan(&id, &data); err != nil {
			return nil, err
		}
		records = append(records, domain.Record{ID: id, Kind: "task", Data: json.RawMessage(data)})
	}
	return records, rows.Err()
}
