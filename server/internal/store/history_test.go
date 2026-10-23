package store

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"yggvion/server/internal/domain"
)

func historyFixture(t *testing.T, path string) (*Store, string, string) {
	t.Helper()
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	device, _, err := s.Pair(context.Background(), "offline-capable device")
	if err != nil {
		t.Fatal(err)
	}
	key := strings.Repeat("a", 64)
	if err = s.EnableEncryption(context.Background(), key, passwordFixture(key, 1)); err != nil {
		t.Fatal(err)
	}
	return s, device, key
}

func TestCompactionKeepsLatestRecordsTombstonesAndOfflineCursors(t *testing.T) {
	s, device, key := historyFixture(t, ":memory:")
	ctx := context.Background()
	records := []domain.Record{sealedRecord("note-a", "note", key), sealedRecord("note-b", "note", key)}
	var oldest int64
	for i := 0; i < 40; i++ {
		j := i % 2
		if i == 39 {
			records[j].Deleted = true
		}
		results, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: fmt.Sprint("edit-", i), Record: records[j]}})
		if err != nil {
			t.Fatal(err)
		}
		records[j] = results[0].Record
		if i == 0 {
			oldest = records[j].Seq
		}
	}
	var count int
	if err := s.DB.QueryRow("SELECT count(*) FROM changes").Scan(&count); err != nil || count != 2 {
		t.Fatal("intermediate revisions retained", count, err)
	}
	for _, start := range []int64{0, oldest} {
		cursor := start
		seen := map[string]domain.Record{}
		for {
			page, next, more, err := s.Changes(ctx, cursor, 1)
			if err != nil {
				t.Fatal(err)
			}
			if len(page) == 0 || next <= cursor {
				t.Fatal("cursor failed to advance", cursor, next)
			}
			seen[page[0].ID] = page[0]
			cursor = next
			if !more {
				break
			}
		}
		if len(seen) != 2 || seen["note-a"].Version != 20 || !seen["note-b"].Deleted {
			t.Fatal("offline snapshot lost latest state or deletion", seen)
		}
		page, next, more, err := s.Changes(ctx, cursor, 500)
		if err != nil || len(page) != 0 || next != cursor || more {
			t.Fatal(page, next, more, err)
		}
	}
}

func TestEvictedReceiptCannotOverwriteAnAdvancedRecord(t *testing.T) {
	s, device, key := historyFixture(t, ":memory:")
	ctx := context.Background()
	original := domain.Mutation{OperationID: "first", Record: sealedRecord("note", "note", key)}
	first, err := s.Apply(ctx, device, []domain.Mutation{original})
	if err != nil {
		t.Fatal(err)
	}
	current := first[0].Record
	var envelope domain.Envelope
	if err = json.Unmarshal(current.Data, &envelope); err != nil {
		t.Fatal(err)
	}
	envelope.Box = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("new", 32)))
	current.Data, _ = json.Marshal(envelope)
	if _, err = s.DB.Exec("UPDATE operations SET created=?", time.Now().Add(-operationLifetime-time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	second, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "second", Record: current}})
	if err != nil {
		t.Fatal(err)
	}
	var count int
	s.DB.QueryRow("SELECT count(*) FROM operations WHERE id='first'").Scan(&count)
	if count != 0 {
		t.Fatal("expired receipt retained")
	}
	retry, err := s.Apply(ctx, device, []domain.Mutation{original})
	if err != nil {
		t.Fatal(err)
	}
	if retry[0].Status != "conflict" || retry[0].Record.Version != second[0].Record.Version || !equalJSON(retry[0].Record.Data, second[0].Record.Data) {
		t.Fatal("expired retry overwrote newer data", retry)
	}
	// The retained receipt is still exactly idempotent after history compaction.
	again, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "second", Record: current}})
	if err != nil || again[0].Record.Version != second[0].Record.Version {
		t.Fatal(again, err)
	}
}

func TestOperationReceiptsHaveCountAndByteBudgets(t *testing.T) {
	for _, tc := range []struct {
		name              string
		count, size, want int
	}{
		{"count", maxOperationReceipts + 20, 2, maxOperationReceipts},
		{"bytes", 70, 1 << 20, 64},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, _, _ := historyFixture(t, ":memory:")
			tx, err := s.DB.Begin()
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			payload := strings.Repeat(" ", tc.size)
			for i := 0; i < tc.count; i++ {
				if _, err = tx.Exec("INSERT INTO operations VALUES(?,?,?,?,?,?)", fmt.Sprint("receipt-", i), "device", "hash", payload, time.Now().Unix(), len(payload)); err != nil {
					t.Fatal(err)
				}
			}
			if err = compactOperations(context.Background(), tx, time.Now()); err != nil {
				t.Fatal(err)
			}
			var count, size int
			if err = tx.QueryRow("SELECT count(*),sum(payload_bytes) FROM operations").Scan(&count, &size); err != nil || count != tc.want || size > maxOperationBytes {
				t.Fatal(count, size, err)
			}
			if err = tx.Commit(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestChangesPaginateByBytesWithoutDroppingRecords(t *testing.T) {
	s, device, key := historyFixture(t, ":memory:")
	ctx := context.Background()
	for i := 0; i < 8; i++ {
		r := sealedRecord(fmt.Sprint("large-", i), "note", key)
		var envelope domain.Envelope
		json.Unmarshal(r.Data, &envelope)
		envelope.Box = base64.StdEncoding.EncodeToString(make([]byte, 1<<20))
		r.Data, _ = json.Marshal(envelope)
		if _, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: r.ID, Record: r}}); err != nil {
			t.Fatal(err)
		}
	}
	first, cursor, more, err := s.Changes(ctx, 0, 500)
	if err != nil || len(first) == 0 || len(first) >= 8 || !more {
		t.Fatal(len(first), more, err)
	}
	second, next, more, err := s.Changes(ctx, cursor, 500)
	if err != nil || len(first)+len(second) != 8 || more || next <= cursor {
		t.Fatal(len(second), more, err)
	}
}

func TestSchemaSevenCompactsWithoutResettingIdentityOrCursor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "existing.db")
	s, device, key := historyFixture(t, path)
	ctx := context.Background()
	generation, _ := s.Generation(ctx)
	r := sealedRecord("note", "note", key)
	first, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "first", Record: r}})
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "second", Record: first[0].Record}})
	if err != nil {
		t.Fatal(err)
	}
	// Recreate the previous schema and its historical row, as on an existing VPS.
	encoded, _ := json.Marshal(first[0].Record)
	if _, err = s.DB.Exec("INSERT INTO changes(seq,record) VALUES(?,?)", first[0].Record.Seq, string(encoded)); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{"DROP INDEX operations_created", "DROP INDEX records_seq", "ALTER TABLE operations DROP COLUMN created", "ALTER TABLE operations DROP COLUMN payload_bytes", "PRAGMA user_version=7"} {
		if _, err = s.DB.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	reopened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	nextGeneration, _ := reopened.Generation(ctx)
	if generation != nextGeneration {
		t.Fatal("migration reset generation")
	}
	page, cursor, _, err := reopened.Changes(ctx, 0, 500)
	if err != nil || len(page) != 1 || cursor != second[0].Record.Seq || page[0].Version != 2 {
		t.Fatal(page, cursor, err)
	}
	var count, version int
	reopened.DB.QueryRow("SELECT count(*) FROM devices WHERE id=?", device).Scan(&count)
	reopened.DB.QueryRow("PRAGMA user_version").Scan(&version)
	if count != 1 || version != SchemaVersion {
		t.Fatal("identity or migration failed", count, version)
	}
	if _, err = reopened.Apply(ctx, device, []domain.Mutation{{OperationID: "third", Record: page[0]}}); err != nil {
		t.Fatal(err)
	}
}
