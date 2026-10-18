// Linux desktop notification companion. It reads the Flutter database locally;
// no server connection or credentials are required for already synced reminders.
package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
	"yggvion/server/internal/domain"
)

type reminder struct {
	key, taskID, title string
	at                 time.Time
}

func (r reminder) deliveryKey() string { return fmt.Sprintf("notified:%s:%d", r.key, r.at.UnixMilli()) }

func main() {
	path := flag.String("database", "", "Path to the Flutter yggvion.sqlite database")
	flag.Parse()
	if *path == "" {
		slog.Error("--database is required")
		os.Exit(1)
	}
	if _, e := os.Stat(*path); e != nil {
		slog.Error("database unavailable", "error", e)
		os.Exit(1)
	}
	if _, e := exec.LookPath("notify-send"); e != nil {
		slog.Error("Install libnotify-bin / libnotify")
		os.Exit(1)
	}
	db, e := sql.Open("sqlite", *path)
	if e != nil {
		slog.Error("database", "error", e)
		os.Exit(1)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, e = db.Exec("PRAGMA busy_timeout=5000"); e != nil {
		slog.Error("database", "error", e)
		os.Exit(1)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	send := func(ctx context.Context, r reminder) error {
		go func() {
			if e := deliver(ctx, db, r); e != nil {
				slog.Warn("notification delivery", "error", e)
				if _, e = db.ExecContext(ctx, "DELETE FROM metadata WHERE key=?", r.deliveryKey()); e != nil && ctx.Err() == nil {
					slog.Warn("release notification", "error", e)
				}
			}
		}()
		return nil
	}
	for {
		if e = tick(ctx, db, time.Now(), send); e != nil {
			slog.Warn("reminder check", "error", e)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func tick(ctx context.Context, db *sql.DB, now time.Time, send func(context.Context, reminder) error) error {
	rows, e := db.QueryContext(ctx, "SELECT payload FROM records WHERE deleted=0 AND kind IN ('task','block','snooze')")
	if e != nil {
		return e
	}
	tasks := map[string]domain.Task{}
	var records []domain.Record
	for rows.Next() {
		var payload string
		if e = rows.Scan(&payload); e != nil {
			rows.Close()
			return e
		}
		var r domain.Record
		if e = json.Unmarshal([]byte(payload), &r); e != nil {
			rows.Close()
			return e
		}
		if r.Kind == "task" {
			var t domain.Task
			if e = json.Unmarshal(r.Data, &t); e != nil {
				rows.Close()
				return e
			}
			tasks[r.ID] = t
		} else {
			records = append(records, r)
		}
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, r := range records {
		var list []reminder
		if r.Kind == "block" {
			var b domain.Block
			if e = json.Unmarshal(r.Data, &b); e != nil {
				return e
			}
			if b.Historical {
				continue
			}
			for _, offset := range b.Reminders {
				list = append(list, reminder{key: fmt.Sprintf("%s:%d", r.ID, offset), taskID: b.TaskID, at: b.Start.Add(-time.Duration(offset) * time.Minute)})
			}
		}
		if r.Kind == "snooze" {
			var s domain.Snooze
			if e = json.Unmarshal(r.Data, &s); e != nil {
				return e
			}
			list = append(list, reminder{key: r.ID, taskID: s.TaskID, at: s.At})
		}
		for _, rem := range list {
			task, ok := tasks[rem.taskID]
			if !ok || task.Status == "done" || rem.at.After(now) || now.Sub(rem.at) > 15*time.Minute {
				continue
			}
			rem.title = strings.ReplaceAll(task.Title, "\x00", "")
			result, e := db.ExecContext(ctx, "INSERT OR IGNORE INTO metadata(key,value) VALUES(?,?)", rem.deliveryKey(), now.UTC().Format(time.RFC3339Nano))
			if e != nil {
				return e
			}
			claimed, e := result.RowsAffected()
			if e != nil {
				return e
			}
			if claimed == 0 {
				continue
			}
			if e = send(ctx, rem); e != nil {
				_, releaseErr := db.ExecContext(ctx, "DELETE FROM metadata WHERE key=?", rem.deliveryKey())
				if releaseErr != nil {
					return fmt.Errorf("release failed: %w (delivery: %v)", releaseErr, e)
				}
				return e
			}
		}
	}
	return nil
}

func deliver(ctx context.Context, db *sql.DB, r reminder) error {
	commandCtx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(commandCtx, "notify-send", "--app-name=Yggvion", "--icon=appointment-soon", "--wait", "--action=snooze=Через 10 минут", "--", r.title, "Пора начать").Output()
	// A notification remaining in the notification center is not a failed delivery.
	if commandCtx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(out)) == "snooze" {
		return snooze(ctx, db, r.taskID, time.Now().Add(10*time.Minute))
	}
	return nil
}

func snooze(ctx context.Context, db *sql.DB, taskID string, at time.Time) error {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return err
	}
	id := "snooze_" + hex.EncodeToString(random)
	data, err := json.Marshal(domain.Snooze{TaskID: taskID, At: at.UTC()})
	if err != nil {
		return err
	}
	record := domain.Record{ID: id, Kind: "snooze", Data: data}
	payload, err := json.Marshal(record)
	if err != nil {
		return err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "INSERT INTO records(id,kind,payload,deleted) VALUES(?,'snooze',?,0)", id, string(payload)); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO metadata(key,value) VALUES('ordinal','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO outbox(id,operation_id,payload,ordinal) SELECT ?,?,?,CAST(value AS INTEGER) FROM metadata WHERE key='ordinal'", id, id, string(payload)); err != nil {
		return err
	}
	return tx.Commit()
}
