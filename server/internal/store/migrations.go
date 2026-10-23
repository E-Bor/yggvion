package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

const SchemaVersion = 8

// Schema 7 is the direct-password E2EE baseline. Schema 8 bounds sync history.
// Earlier encryption formats are still rejected.
// Creating the schema and its version marker is atomic.
func migrate(db *sql.DB, version int) error {
	if version == SchemaVersion {
		return nil
	}
	if version == 7 {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		for _, query := range []string{
			"ALTER TABLE operations ADD COLUMN created INTEGER NOT NULL DEFAULT 0",
			"ALTER TABLE operations ADD COLUMN payload_bytes INTEGER NOT NULL DEFAULT 0",
			"UPDATE operations SET created=unixepoch(),payload_bytes=length(CAST(result AS BLOB))",
			"CREATE INDEX operations_created ON operations(created)",
			"CREATE INDEX records_seq ON records(seq)",
			"DELETE FROM changes WHERE NOT EXISTS (SELECT 1 FROM records WHERE records.seq=changes.seq)",
			"PRAGMA user_version=8",
		} {
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
