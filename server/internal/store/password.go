package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"yggvion/server/internal/domain"
)

func passwordEnvelope(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}) (*domain.PasswordEnvelope, error) {
	var value string
	err := q.QueryRowContext(ctx, "SELECT value FROM server_meta WHERE key='password_envelope'").Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var result domain.PasswordEnvelope
	if err = json.Unmarshal([]byte(value), &result); err != nil {
		return nil, err
	}
	if err = result.Validate(); err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *Store) PasswordEnvelope(ctx context.Context) (*domain.PasswordEnvelope, error) {
	return passwordEnvelope(ctx, s.DB)
}

func (s *Store) SetPasswordEnvelope(ctx context.Context, keyID string, expected int64, next domain.PasswordEnvelope) error {
	if next.Validate() != nil || next.KeyID != keyID || expected < 1 || next.Revision != expected+1 {
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
	if currentKey != keyID {
		return ErrConflict
	}
	current, err := passwordEnvelope(ctx, tx)
	if err != nil {
		return err
	}
	if current != nil && *current == next {
		return nil
	} // Lost successful response.
	if current == nil || current.Revision != expected {
		return ErrConflict
	}
	data, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO server_meta VALUES('password_envelope',?)", string(data)); err != nil {
		return err
	}
	return tx.Commit()
}
