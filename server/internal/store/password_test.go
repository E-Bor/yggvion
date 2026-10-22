package store

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"yggvion/server/internal/domain"
)

func passwordFixture(key string, _ int64) domain.PasswordConfig {
	return domain.PasswordConfig{Version: 2, KeyID: key, KDF: "argon2id", Memory: 19456, Iterations: 2, Parallelism: 1, Salt: base64.StdEncoding.EncodeToString(make([]byte, 16))}
}

func TestPasswordRotationCompareAndSwapAndRestore(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	key := strings.Repeat("a", 64)
	first := passwordFixture(key, 1)
	if err = s.EnableEncryption(ctx, key, first); err != nil {
		t.Fatal(err)
	}
	old, err := s.Export(ctx)
	if err != nil || old.PasswordConfig == nil || *old.PasswordConfig != first {
		t.Fatal(err)
	}
	generation, _ := s.Generation(ctx)
	next := passwordFixture(strings.Repeat("b", 64), 1)
	if err = s.RotatePassword(ctx, generation, key, old.Cursor+1, next, nil); err != ErrConflict {
		t.Fatal("stale cursor", err)
	}
	if err = s.RotatePassword(ctx, "stale", key, old.Cursor, next, nil); err != ErrConflict {
		t.Fatal("stale generation", err)
	}
	if err = s.RotatePassword(ctx, generation, key, old.Cursor, next, nil); err != nil {
		t.Fatal(err)
	}
	newGeneration, _ := s.Generation(ctx)
	if generation == newGeneration {
		t.Fatal("generation not changed")
	}
	if err = s.RotatePassword(ctx, generation, key, old.Cursor, next, nil); err != ErrConflict {
		t.Fatal("replayed rotation", err)
	}
	current, err := s.PasswordConfig(ctx)
	if err != nil || current == nil || *current != next {
		t.Fatal("rotation not saved", err)
	}
	if err = s.Restore(ctx, old); err != nil {
		t.Fatal(err)
	}
	current, err = s.PasswordConfig(ctx)
	if err != nil || current == nil || *current != first {
		t.Fatal("archive password not restored", err)
	}
	fresh, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	if err = fresh.Restore(ctx, old); err != nil {
		t.Fatal(err)
	}
	current, err = fresh.PasswordConfig(ctx)
	if err != nil || current == nil || *current != first {
		t.Fatal("fresh restore", err)
	}
}

func TestPasswordRotationPreservesVersionsAndValidatesStagedFiles(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	oldKey, nextKey := strings.Repeat("a", 64), strings.Repeat("b", 64)
	first, next := passwordFixture(oldKey, 1), passwordFixture(nextKey, 1)
	if err = s.EnableEncryption(ctx, oldKey, first); err != nil {
		t.Fatal(err)
	}
	device, _, _ := s.Pair(ctx, "test")
	results, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "old1", Record: sealedRecord("old-note", "note", oldKey)}})
	if err != nil {
		t.Fatal(err)
	}
	record := results[0].Record
	if _, err = s.Apply(ctx, device, []domain.Mutation{{OperationID: "old2", Record: record}}); err != nil {
		t.Fatal(err)
	}
	original, err := s.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	generation, _ := s.Generation(ctx)
	stagedID := strings.Repeat("c", 64)
	if _, err = s.DB.Exec("INSERT INTO attachments VALUES(?,?,?,?)", stagedID, "encrypted", 32, "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("INSERT INTO encrypted_uploads VALUES(?,?)", stagedID, nextKey); err != nil {
		t.Fatal(err)
	}
	snapshot, err := s.Export(ctx)
	if err != nil || len(snapshot.Attachments) != 0 {
		t.Fatal("staged file leaked into old backup", err)
	}
	replacement := sealedRecord("new-note", "note", nextKey)
	replacement.Version = original.Records[0].Version
	env, _ := domain.ReadEnvelope(replacement)
	env.Files = []string{strings.Repeat("d", 64)}
	replacement.Data, _ = json.Marshal(env)
	if err = s.RotatePassword(ctx, generation, oldKey, original.Cursor, next, []domain.Record{replacement}); err != ErrInvalid {
		t.Fatal("missing file accepted", err)
	}
	unchanged, _ := s.Export(ctx)
	if unchanged.EncryptionKeyID != oldKey || string(unchanged.Records[0].Data) != string(original.Records[0].Data) {
		t.Fatal("failed rotation changed data")
	}
	if err = s.RotatePassword(ctx, generation, oldKey, original.Cursor, next, nil); err != ErrInvalid {
		t.Fatal("partial snapshot accepted", err)
	}
	env.Files = []string{stagedID}
	replacement.Data, _ = json.Marshal(env)
	if err = s.RotatePassword(ctx, generation, oldKey, original.Cursor, next, []domain.Record{replacement}); err != nil {
		t.Fatal(err)
	}
	after, err := s.Export(ctx)
	if err != nil || len(after.Attachments) != 1 || after.Records[0].Version != original.Records[0].Version {
		t.Fatal("lost versions or staged files", err)
	}
	var reason string
	if err = s.DB.QueryRow("SELECT value FROM server_meta WHERE key='generation_reason'").Scan(&reason); err != nil || reason != "password" {
		t.Fatal("wrong reconciliation reason", reason, err)
	}
	var timerMarkers int
	if err = s.DB.QueryRow("SELECT count(*) FROM server_meta WHERE key IN ('snapshot_cursor','snapshot_created')").Scan(&timerMarkers); err != nil || timerMarkers != 0 {
		t.Fatal("rotation would stop timers", err)
	}
	// Offline clients can still apply edits against the pre-rotation version.
	result, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "offline", Record: after.Records[0]}})
	if err != nil || result[0].Status != "applied" {
		t.Fatal("offline edit conflicted", result, err)
	}
}

func TestPasswordParametersAreBounded(t *testing.T) {
	valid := passwordFixture(strings.Repeat("c", 64), 1)
	for name, change := range map[string]func(*domain.PasswordConfig){
		"memory":      func(p *domain.PasswordConfig) { p.Memory = 999999999 },
		"iterations":  func(p *domain.PasswordConfig) { p.Iterations = 999999999 },
		"parallelism": func(p *domain.PasswordConfig) { p.Parallelism = 1000 },
		"salt":        func(p *domain.PasswordConfig) { p.Salt = "short" },
		"version":     func(p *domain.PasswordConfig) { p.Version = 1 },
		"key":         func(p *domain.PasswordConfig) { p.KeyID = "invalid" },
	} {
		t.Run(name, func(t *testing.T) {
			value := valid
			change(&value)
			if value.Validate() == nil {
				t.Fatal("accepted invalid password configuration")
			}
		})
	}
}
