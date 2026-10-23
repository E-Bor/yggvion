package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

const SchemaVersion = 9

// Schema 7 is the direct-password E2EE baseline. Schema 8 bounds sync history.
// Schema 9 retains temporary, share-scoped proposal intervals and statuses.
// Earlier encryption formats are still rejected.
// Creating the schema and its version marker is atomic.
func migrate(db *sql.DB, version int) error {
	if version == SchemaVersion {
		return nil
	}
	if version == 7 || version == 8 {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		queries := []string{}
		if version == 7 {
			queries = append(queries, []string{
				"ALTER TABLE operations ADD COLUMN created INTEGER NOT NULL DEFAULT 0",
				"ALTER TABLE operations ADD COLUMN payload_bytes INTEGER NOT NULL DEFAULT 0",
				"UPDATE operations SET created=unixepoch(),payload_bytes=length(CAST(result AS BLOB))",
				"CREATE INDEX operations_created ON operations(created)",
				"CREATE INDEX records_seq ON records(seq)",
				"DELETE FROM changes WHERE NOT EXISTS (SELECT 1 FROM records WHERE records.seq=changes.seq)",
			}...)
		}
		queries = append(queries,
			"ALTER TABLE calendar_proposals ADD COLUMN start TEXT NOT NULL DEFAULT ''",
			"ALTER TABLE calendar_proposals ADD COLUMN end TEXT NOT NULL DEFAULT ''",
			"ALTER TABLE calendar_proposals ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'",
			`UPDATE calendar_proposals SET start=COALESCE((SELECT json_extract(data,'$.proposal.start') FROM guest_inbox WHERE id=task_id),''),end=COALESCE((SELECT json_extract(data,'$.proposal.end') FROM guest_inbox WHERE id=task_id),'')`,
			"PRAGMA user_version=9",
		)
		for _, query := range queries {
			if _, err = tx.Exec(query); err != nil {
				return fmt.Errorf("migrate sync history: %w", err)
			}
		}
		if err = compactOperations(context.Background(), tx, time.Now()); err != nil {
			return err
		}
		return tx.Commit()
	}
	if version != 0 {
		return fmt.Errorf("unsupported database version %d; create a fresh server data directory", version)
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var tables int
	if err = tx.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").Scan(&tables); err != nil {
		return err
	}
	if tables != 0 {
		return fmt.Errorf("unversioned non-empty database is unsupported; create a fresh server data directory")
	}
	if _, err = tx.Exec(schema); err != nil {
		return fmt.Errorf("initialize schema %d: %w", SchemaVersion, err)
	}
	return tx.Commit()
}

// SnapshotDatabase does not run migrations: it protects the previous version
// before a new binary first opens the database. The service must be stopped.
func SnapshotDatabase(path, destination string) error {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return err
	}
	defer db.Close()
	_, err = db.Exec("VACUUM INTO ?", destination)
	return err
}
