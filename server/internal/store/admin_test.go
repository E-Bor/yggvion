package store

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"yggvion/server/internal/domain"
)

func TestRestoreRejectsLegacySnapshotsAndPreservesCiphertext(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	key := strings.Repeat("a", 64)
	password := passwordFixture(key, 1)
	snapshot := Snapshot{Format: 2, Created: time.Now().UTC().Add(-time.Hour),
		EncryptionKeyID: key, PasswordEnvelope: &password,
		Records: []domain.Record{sealedRecord("session", "session", key)}}
	if err = s.Restore(ctx, snapshot); err != nil {
		t.Fatal(err)
	}
	got, err := s.Export(ctx)
	if err != nil || len(got.Records) != 1 || string(got.Records[0].Data) != string(snapshot.Records[0].Data) {
		t.Fatal("ciphertext changed", err)
	}
	generation, _ := s.Generation(ctx)
	for name, mutate := range map[string]func(*Snapshot){
		"legacy format": func(v *Snapshot) { v.Format = 1 },
		"no password":   func(v *Snapshot) { v.PasswordEnvelope = nil },
		"no key":        func(v *Snapshot) { v.EncryptionKeyID = "" },
		"plaintext": func(v *Snapshot) {
			v.Records = []domain.Record{{ID: "note", Kind: "note", Data: json.RawMessage(`{"title":"old"}`)}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			bad := snapshot
			mutate(&bad)
			if err := s.Restore(ctx, bad); err == nil {
				t.Fatal("legacy snapshot accepted")
			}
			after, _ := s.Generation(ctx)
			if after != generation {
				t.Fatal("failed restore changed live data")
			}
		})
	}
}

func TestOpenRefusesFutureSchemaWithoutDowngrading(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("PRAGMA user_version=999"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	if future, err := Open(path); err == nil {
		future.Close()
		t.Fatal("future schema was silently downgraded")
	}
}
