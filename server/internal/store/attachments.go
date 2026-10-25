package store

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"yggvion/server/internal/domain"
)

var ErrAttachmentUsed = errors.New("attachment is referenced")

// DeleteAttachment serializes the reference check, catalog tombstone and file
// removal with sync writes. An offline writer must upload the file again before
// a new reference can be accepted by Apply.
func (s *Store) DeleteAttachment(ctx context.Context, root, id string, record domain.Record) (domain.Record, error) {
	if !domain.ValidHash(id) || record.Kind != "attachment" || !record.Deleted {
		return domain.Record{}, ErrInvalid
	}
	envelope, err := domain.ReadEnvelope(record)
	if err != nil || len(envelope.Files) != 0 {
		return domain.Record{}, ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return domain.Record{}, err
	}
	defer tx.Rollback()
	key, err := encryptionKey(ctx, tx)
	if err != nil {
		return domain.Record{}, err
	}
	if envelope.KeyID != key {
		return domain.Record{}, ErrInvalid
	}
	current, err := read(ctx, tx, record.ID)
	if err != nil {
		return domain.Record{}, err
	}
	if current.Kind != "attachment" {
		return domain.Record{}, ErrInvalid
	}
	if !current.Deleted {
		if current.Version != record.Version {
			return domain.Record{}, ErrConflict
		}
		old, err := domain.ReadEnvelope(current)
		if err != nil {
			return domain.Record{}, err
		}
		found := false
		for _, file := range old.Files {
			if file == id {
				found = true
			}
		}
		if !found {
			return domain.Record{}, ErrInvalid
		}
	}
	var used int
	err = tx.QueryRowContext(ctx, `SELECT count(*) FROM records r, json_each(r.data,'$.files') f WHERE r.deleted=0 AND r.id<>? AND f.value=?`, record.ID, id).Scan(&used)
	if err != nil {
		return domain.Record{}, err
	}
	if used != 0 {
		return domain.Record{}, ErrAttachmentUsed
	}
	result := current
	if !current.Deleted {
		result, err = save(ctx, tx, record)
		if err != nil {
			return domain.Record{}, err
		}
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM encrypted_uploads WHERE id=?", id); err != nil {
		return domain.Record{}, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM attachments WHERE id=?", id); err != nil {
		return domain.Record{}, err
	}
	// Commit metadata first. A failed unlink leaves an unreferenced blob, never a
	// live record pointing to absent bytes; retries can safely remove it.
	if err = tx.Commit(); err != nil {
		return domain.Record{}, err
	}
	if err = os.Remove(filepath.Join(root, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return domain.Record{}, err
	}
	return result, nil
}

func (s *Store) PresentAttachments(ctx context.Context, ids []string) ([]string, error) {
	if len(ids) > 1000 {
		return nil, ErrInvalid
	}
	for _, id := range ids {
		if !domain.ValidHash(id) {
			return nil, ErrInvalid
		}
	}
	encoded, err := json.Marshal(ids)
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT id FROM encrypted_uploads WHERE id IN (SELECT value FROM json_each(?))`, string(encoded))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	present := make([]string, 0, len(ids))
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		present = append(present, id)
	}
	return present, rows.Err()
}
