package store

import (
	"context"
	"database/sql"
	"time"
)

const (
	maxOperationReceipts = 4096
	maxOperationBytes    = 64 << 20
	operationLifetime    = 7 * 24 * time.Hour
	maxChangePageBytes   = 8 << 20
)

// Receipts provide exact retries for recent requests. After eviction Apply's
// version check still prevents a delayed retry from overwriting newer data.
// Only small size/timestamp columns are read here, never the encrypted payloads.
func compactOperations(ctx context.Context, tx *sql.Tx, now time.Time) error {
	if _, err := tx.ExecContext(ctx, "DELETE FROM operations WHERE created < ?", now.Add(-operationLifetime).Unix()); err != nil {
		return err
	}
	rows, err := tx.QueryContext(ctx, "SELECT rowid,payload_bytes FROM operations ORDER BY rowid DESC")
	if err != nil {
		return err
	}
	var cutoff, total int64
	count := 0
	for rows.Next() {
		var id, size int64
		if err = rows.Scan(&id, &size); err != nil {
			rows.Close()
			return err
		}
		if count > 0 && (count >= maxOperationReceipts || total+size > maxOperationBytes) {
			break
		}
		cutoff, total, count = id, total+size, count+1
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if cutoff == 0 {
		return nil
	}
	_, err = tx.ExecContext(ctx, "DELETE FROM operations WHERE rowid < ?", cutoff)
	return err
}
