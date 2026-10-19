package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"
	"yggvion/server/internal/domain"
)

func localDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "local.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { db.Close() })
	for _, q := range []string{
		"CREATE TABLE records(id TEXT PRIMARY KEY,kind TEXT,payload TEXT,deleted INTEGER)",
		"CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)",
		"CREATE TABLE outbox(id TEXT PRIMARY KEY,operation_id TEXT,payload TEXT,ordinal INTEGER)",
	} {
		if _, err = db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	return db
}
func putLocal(t *testing.T, db *sql.DB, id, kind string, data any) {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(domain.Record{ID: id, Kind: kind, Data: raw})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT OR REPLACE INTO records VALUES(?,?,?,0)", id, kind, string(encoded)); err != nil {
		t.Fatal(err)
	}
}
func TestDeliveryClaimAndRetry(t *testing.T) {
	ctx := context.Background()
	db := localDB(t)
	now := time.Date(2026, 10, 19, 10, 0, 0, 0, time.UTC)
	putLocal(t, db, "task", "task", domain.Task{Title: "Напомнить", Status: "todo"})
	block := domain.Block{TaskID: "task", Start: now, End: now.Add(time.Hour), Reminders: []int{0}, Timezone: "UTC"}
	putLocal(t, db, "block", "block", block)
	calls := 0
	fail := func(context.Context, reminder) error { calls++; return errors.New("unavailable") }
	if err := tick(ctx, db, now, fail); err == nil {
		t.Fatal("failure not reported")
	}
	send := func(_ context.Context, r reminder) error {
		calls++
		if r.deliveryKey() != "notified:block:0:1792404000000" {
			t.Fatal(r.deliveryKey())
		}
		return nil
	}
	if err := tick(ctx, db, now, send); err != nil {
		t.Fatal(err)
	}
	if err := tick(ctx, db, now, send); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("calls=%d", calls)
	}
	// A moved block has a fresh identity while the original notification remains claimed.
	block.Start = now.Add(time.Minute)
	block.End = block.Start.Add(time.Hour)
	putLocal(t, db, "block", "block", block)
	if err := tick(ctx, db, block.Start, func(context.Context, reminder) error { calls++; return nil }); err != nil {
		t.Fatal(err)
	}
	if calls != 3 {
		t.Fatal(calls)
	}
	putLocal(t, db, "task", "task", domain.Task{Title: "Напомнить", Status: "done"})
	block.Start = now.Add(2 * time.Minute)
	block.End = block.Start.Add(time.Hour)
	putLocal(t, db, "block", "block", block)
	if err := tick(ctx, db, block.Start, func(context.Context, reminder) error { t.Fatal("done task notified"); return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestBirthdayAbsoluteRemindersOverrideOffsetsAndRespectCompletion(t *testing.T) {
	db := localDB(t)
	ctx := context.Background()
	start := time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC)
	putLocal(t, db, "birthday", "task", domain.Task{Title: "Анна — день рождения", Status: "todo", BirthdayDate: "1990-03-31"})
	// Previously persisted month/week notices must not fire after updating.
	month := time.Date(2026, 2, 28, 9, 0, 0, 0, time.UTC)
	week := start.Add(-7*24*time.Hour + 9*time.Hour)
	block := domain.Block{TaskID: "birthday", Start: start, End: start.Add(24 * time.Hour), Timezone: "UTC", Reminders: []int{0}, ReminderAt: []time.Time{month, week, start.Add(9 * time.Hour)}}
	putLocal(t, db, "birthday_block", "block", block)
	calls := 0
	send := func(_ context.Context, r reminder) error {
		calls++
		if r.key != "birthday_block:at:2" || !r.at.Equal(start.Add(9*time.Hour)) || r.body != "Сегодня день рождения. Не забудьте поздравить!" {
			t.Fatal(r)
		}
		return nil
	}
	for _, at := range []time.Time{month, week, start, start.Add(9 * time.Hour), start.Add(9 * time.Hour)} {
		if err := tick(ctx, db, at, send); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 1 {
		t.Fatal(calls)
	}
	block.ReminderAt = []time.Time{start.Add(9 * time.Hour)}
	putLocal(t, db, "birthday_block", "block", block)
	if err := tick(ctx, db, block.ReminderAt[0], send); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatal("refreshing old reminders duplicated delivery", calls)
	}
	putLocal(t, db, "birthday", "task", domain.Task{Title: "Анна — день рождения", Status: "done", BirthdayDate: "1990-03-31"})
	block.ReminderAt = []time.Time{start.Add(10 * time.Hour)}
	putLocal(t, db, "birthday_block", "block", block)
	if err := tick(ctx, db, block.ReminderAt[0], send); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatal("completed birthday notified", calls)
	}
}
func TestSnoozePersistsOfflineAndQueuesSync(t *testing.T) {
	db := localDB(t)
	at := time.Date(2026, 10, 19, 10, 0, 0, 0, time.UTC)
	if err := snooze(context.Background(), db, "task", at); err != nil {
		t.Fatal(err)
	}
	var payload string
	var ordinal int
	if err := db.QueryRow("SELECT payload,ordinal FROM outbox").Scan(&payload, &ordinal); err != nil {
		t.Fatal(err)
	}
	var r domain.Record
	if err := json.Unmarshal([]byte(payload), &r); err != nil {
		t.Fatal(err)
	}
	if err := domain.Validate(r); err != nil {
		t.Fatal(err)
	}
	var s domain.Snooze
	json.Unmarshal(r.Data, &s)
	if s.TaskID != "task" || !s.At.Equal(at) || ordinal != 1 {
		t.Fatal(r, ordinal)
	}
}
