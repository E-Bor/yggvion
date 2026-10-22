package store

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
)

func TestOldSchemasAreRejectedWithoutChangingData(t *testing.T) {
	for _, version := range []int{0, 1, 2, 3, 4, 5, 6, 999} {
		t.Run(fmt.Sprint(version), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "old.db")
			old, err := sql.Open("sqlite", path)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = old.Exec("CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('keep');"); err != nil {
				t.Fatal(err)
			}
			if _, err = old.Exec(fmt.Sprintf("PRAGMA user_version=%d", version)); err != nil {
				t.Fatal(err)
			}
			old.Close()
			if _, err = Open(path); err == nil {
				t.Fatal("old schema accepted")
			}
			check, err := sql.Open("sqlite", path)
			if err != nil {
				t.Fatal(err)
			}
			defer check.Close()
			var gotVersion int
			var value string
			check.QueryRow("PRAGMA user_version").Scan(&gotVersion)
			check.QueryRow("SELECT value FROM sentinel").Scan(&value)
			if gotVersion != version || value != "keep" {
				t.Fatal("old database changed", gotVersion, value)
			}
		})
	}
}
func TestCurrentSchemaReopensAndSafetySnapshotKeepsIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "current.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	generation, _ := s.Generation(context.Background())
	device, token, err := s.Pair(context.Background(), "Phone")
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if err = SnapshotDatabase(path, path+".safety"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{path, path + ".safety"} {
		reopened, err := Open(name)
		if err != nil {
			t.Fatal(err)
		}
		got, err := reopened.Generation(context.Background())
		if err != nil || got != generation {
			t.Fatal("generation", err)
		}
		id, err := reopened.Authorize(context.Background(), token)
		if err != nil || id != device {
			t.Fatal("identity", err)
		}
		reopened.Close()
	}
}
