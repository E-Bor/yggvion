package store

import (
	"database/sql"
	"fmt"
)

const SchemaVersion = 7

// Schema 7 is the direct-password E2EE baseline. Earlier databases are not migrated.
// Creating the schema and its version marker is atomic.
func migrate(db *sql.DB, version int) error {
	if version == SchemaVersion {
		return nil
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
