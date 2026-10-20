package store

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"yggvion/server/internal/domain"
)

func TestRestoreClosesRunningTimerAtSnapshotAndRejectsFutureStartAtomically(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	device, _, err := s.Pair(ctx, "test")
	if err != nil {
		t.Fatal(err)
	}
	created := time.Now().UTC().Add(-time.Hour)
	task, _ := json.Marshal(domain.Task{Title: "Test", Status: "todo"})
	session, _ := json.Marshal(domain.Session{TaskID: "task1", DeviceID: device, Start: created.Add(-time.Hour)})
	snapshot := Snapshot{Format: 1, Created: created, Records: []domain.Record{
		{ID: "task1", Kind: "task", Data: task},
		{ID: "session1", Kind: "session", Data: session},
	}}
	if err = s.Restore(ctx, snapshot); err != nil {
		t.Fatal(err)
	}
	got, err := s.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range got.Records {
		if r.Kind == "session" {
			var timer domain.Session
			if err = json.Unmarshal(r.Data, &timer); err != nil {
				t.Fatal(err)
			}
			if timer.End == nil || !timer.End.Equal(created) {
				t.Fatal("timer not stopped at snapshot time")
			}
		}
	}
	generation, _, err := s.Generation(ctx)
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Records[1].Data, _ = json.Marshal(domain.Session{TaskID: "task1", DeviceID: device, Start: created.Add(time.Hour)})
	if err = s.Restore(ctx, snapshot); err == nil {
		t.Fatal("future timer accepted")
	}
	unchanged, _, err := s.Generation(ctx)
	if err != nil || generation != unchanged {
		t.Fatal("failed restore changed generation", err)
	}
	after, err := s.Export(ctx)
	if err != nil || len(after.Records) != len(got.Records) {
		t.Fatal("failed restore lost records", err)
	}
	for i := range got.Records {
		if string(got.Records[i].Data) != string(after.Records[i].Data) {
			t.Fatal("failed restore changed data")
		}
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
