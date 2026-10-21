package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestUpgradePreservesDataIdentityAndCanBeReopened(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = old.Exec(schema); err != nil {
		t.Fatal(err)
	}
	if _, err = old.Exec(`INSERT INTO records VALUES('note','note',4,0,'{"title":"Title","content":"body","pinned":""}',1);
 INSERT INTO devices VALUES('device','phone','tokenhash',1);
 INSERT INTO server_meta VALUES('generation','same-generation');`); err != nil {
		t.Fatal(err)
	}
	old.Close()
	if err = SnapshotDatabase(path, path+".safety"); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		db, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		var version int
		db.DB.QueryRow("PRAGMA user_version").Scan(&version)
		if version != SchemaVersion {
			t.Fatal(version)
		}
		snapshot, err := db.Export(context.Background())
		if err != nil || len(snapshot.Records) != 1 || snapshot.Records[0].Version != 4 {
			t.Fatal(snapshot, err)
		}
		var revoked int
		db.DB.QueryRow("SELECT revoked FROM devices WHERE id='device'").Scan(&revoked)
		generation, _, err := db.Generation(context.Background())
		if revoked != 1 || generation != "same-generation" || err != nil {
			t.Fatal(revoked, generation, err)
		}
		db.Close()
	}
	previous, _ := sql.Open("sqlite", path+".safety")
	defer previous.Close()
	var version int
	previous.QueryRow("PRAGMA user_version").Scan(&version)
	if version != 2 {
		t.Fatal("safety snapshot was migrated")
	}
	future, _ := sql.Open("sqlite", path)
	future.Exec("PRAGMA user_version=999")
	future.Close()
	if _, err := Open(path); err == nil {
		t.Fatal("future schema accepted")
	}
}
