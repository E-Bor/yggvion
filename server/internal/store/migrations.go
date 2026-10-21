package store

import (
	"database/sql"
	"fmt"
)

const SchemaVersion = 3

// Each migration runs once, in the same transaction as its version marker.
// Future changes append a step; existing migrations remain immutable.
func migrate(db *sql.DB, version int) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if version < 2 {
		if _, err = tx.Exec(schema); err != nil {
			return fmt.Errorf("schema 2: %w", err)
		}
	}
	if version < 3 {
		if _, err = tx.Exec(`CREATE INDEX IF NOT EXISTS records_kind ON records(kind,deleted);
   CREATE INDEX IF NOT EXISTS invitations_expires ON invitations(expires);
   PRAGMA user_version=3;`); err != nil {
			return fmt.Errorf("schema 3: %w", err)
		}
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
