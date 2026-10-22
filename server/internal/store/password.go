package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"yggvion/server/internal/domain"
)

func passwordConfig(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}) (*domain.PasswordConfig, error) {
	var value string
	err := q.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='password_config'").Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var result domain.PasswordConfig
	if err = json.Unmarshal([]byte(value), &result); err != nil {
		return nil, err
	}
	if err = result.Validate(); err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *Store) PasswordConfig(ctx context.Context) (*domain.PasswordConfig, error) {
	return passwordConfig(ctx, s.DB)
}

func (s *Store) RotatePassword(ctx context.Context, generation, keyID string, cursor int64, next domain.PasswordConfig, records []domain.Record) error {
	if next.Validate() != nil || !domain.ValidHash(keyID) || next.KeyID == keyID || cursor < 0 {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	currentKey, err := encryptionKey(ctx, tx)
	if err != nil {
		return err
	}
	var currentGeneration string
	var currentCursor int64
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='generation'").Scan(&currentGeneration); err != nil {
		return err
	}
	if err = tx.QueryRowContext(ctx, "SELECT COALESCE(MAX(seq),0) FROM changes").Scan(&currentCursor); err != nil {
		return err
	}
	if currentKey != keyID || generation != currentGeneration || cursor != currentCursor {
		return ErrConflict
	}
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM records").Scan(&count); err != nil {
		return err
	}
	if len(records) != count {
		return ErrInvalid
	}
	snapshot := Snapshot{Format: 3, Created: time.Now().UTC(), EncryptionKeyID: next.KeyID, PasswordConfig: &next, Records: records, Attachments: []Attachment{}}
	for _, r := range records {
		envelope, err := domain.ReadEnvelope(r)
		if err != nil || envelope.KeyID != next.KeyID || r.Version < 1 {
			return ErrInvalid
		}
	}
	// Include every completed staged upload, even if currently unreferenced.
	// Clients cache these upload acknowledgements for later offline edits.
	rows, err := tx.QueryContext(ctx, "SELECT a.id,a.name,a.size,a.media_type FROM attachments a JOIN encrypted_uploads e ON e.id=a.id WHERE e.key_id=?", next.KeyID)
	if err != nil {
		return err
	}
	for rows.Next() {
		var a Attachment
		if err = rows.Scan(&a.ID, &a.Name, &a.Size, &a.MediaType); err != nil {
			rows.Close()
			return err
		}
		snapshot.Attachments = append(snapshot.Attachments, a)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if err = ValidateSnapshot(snapshot); err != nil {
		return err
	}
	if err = replaceSnapshot(ctx, tx, snapshot, "password"); err != nil {
		return err
	}
	return tx.Commit()
}
