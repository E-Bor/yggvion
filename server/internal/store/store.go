package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
	"yggvion/server/internal/domain"
)

//go:embed schema.sql
var schema string

var ErrConflict = errors.New("operation id reused with different payload")
var ErrInvalid = errors.New("invalid relationship")

type Store struct {
	DB *sql.DB
	mu sync.Mutex
}

func Open(path string) (*Store, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	for _, query := range []string{"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000", "PRAGMA foreign_keys=ON", schema} {
		if _, err = db.Exec(query); err != nil {
			db.Close()
			return nil, err
		}
	}
	if path != ":memory:" {
		if err = os.Chmod(path, 0600); err != nil {
			db.Close()
			return nil, err
		}
	}
	return &Store{DB: db}, nil
}

func hash(value string) string { h := sha256.Sum256([]byte(value)); return hex.EncodeToString(h[:]) }
func (s *Store) Pair(ctx context.Context, name string) (string, string, error) {
	id := make([]byte, 16)
	token := make([]byte, 32)
	if _, e := rand.Read(id); e != nil {
		return "", "", e
	}
	if _, e := rand.Read(token); e != nil {
		return "", "", e
	}
	deviceID, secret := hex.EncodeToString(id), hex.EncodeToString(token)
	_, err := s.DB.ExecContext(ctx, "INSERT INTO devices(id,name,token_hash) VALUES (?,?,?)", deviceID, name, hash(secret))
	return deviceID, secret, err
}
func (s *Store) Authorize(ctx context.Context, token string) (string, error) {
	var id string
	err := s.DB.QueryRowContext(ctx, "SELECT id FROM devices WHERE token_hash=? AND revoked=0", hash(token)).Scan(&id)
	return id, err
}
func (s *Store) Revoke(ctx context.Context, id string) error {
	_, e := s.DB.ExecContext(ctx, "UPDATE devices SET revoked=1 WHERE id=?", id)
	return e
}
func read(ctx context.Context, tx *sql.Tx, id string) (domain.Record, error) {
	var r domain.Record
	var data string
	err := tx.QueryRowContext(ctx, "SELECT id,kind,version,deleted,data,seq FROM records WHERE id=?", id).Scan(&r.ID, &r.Kind, &r.Version, &r.Deleted, &data, &r.Seq)
	r.Data = json.RawMessage(data)
	return r, err
}
func save(ctx context.Context, tx *sql.Tx, r domain.Record) (domain.Record, error) {
	r.Version++
	r.Seq = 0
	encoded, err := json.Marshal(r)
	if err != nil {
		return r, err
	}
	result, err := tx.ExecContext(ctx, "INSERT INTO changes(record) VALUES (?)", string(encoded))
	if err != nil {
		return r, err
	}
	r.Seq, err = result.LastInsertId()
	if err != nil {
		return r, err
	}
	encoded, err = json.Marshal(r)
	if err != nil {
		return r, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE changes SET record=? WHERE seq=?", string(encoded), r.Seq); err != nil {
		return r, err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO records(id,kind,version,deleted,data,seq) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,deleted=excluded.deleted,data=excluded.data,seq=excluded.seq`, r.ID, r.Kind, r.Version, r.Deleted, string(r.Data), r.Seq)
	return r, err
}
func linked(ctx context.Context, tx *sql.Tx, id, kind string) bool {
	r, e := read(ctx, tx, id)
	return e == nil && r.Kind == kind && !r.Deleted
}

func (s *Store) Apply(ctx context.Context, deviceID string, mutations []domain.Mutation) ([]domain.Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	results := make([]domain.Result, 0, len(mutations))
	for _, m := range mutations {
		if !domain.ValidID(m.OperationID) {
			return nil, ErrInvalid
		}
		if e := domain.Validate(m.Record); e != nil {
			return nil, e
		}
		encoded, _ := json.Marshal(m.Record)
		fingerprint := hash(string(encoded))
		var oldHash, oldResult, oldDevice string
		err = tx.QueryRowContext(ctx, "SELECT request_hash,result,device_id FROM operations WHERE id=?", m.OperationID).Scan(&oldHash, &oldResult, &oldDevice)
		if err == nil {
			if fingerprint != oldHash || oldDevice != deviceID {
				return nil, ErrConflict
			}
			var result domain.Result
			if err = json.Unmarshal([]byte(oldResult), &result); err != nil {
				return nil, err
			}
			results = append(results, result)
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		current, e := read(ctx, tx, m.Record.ID)
		if e != nil && !errors.Is(e, sql.ErrNoRows) {
			return nil, e
		}
		if e == nil && current.Kind != m.Record.Kind {
			return nil, ErrInvalid
		}
		result := domain.Result{OperationID: m.OperationID, Status: "applied"}
		if current.Version != m.Record.Version && current.Deleted == m.Record.Deleted && equalJSON(current.Data, m.Record.Data) {
			// Two offline devices can independently materialize the same occurrence
			// or initialize the same fixed notes. Equivalent content is not a conflict.
			result.Record = current
		} else if current.Version != m.Record.Version {
			result.Status = "conflict"
			result.Record = current
		} else {
			if !m.Record.Deleted {
				var taskID, projectID string
				switch m.Record.Kind {
				case "task":
					var t domain.Task
					json.Unmarshal(m.Record.Data, &t)
					projectID = t.ProjectID
				case "series":
					var t domain.Series
					json.Unmarshal(m.Record.Data, &t)
					projectID = t.ProjectID
				case "block":
					var b domain.Block
					json.Unmarshal(m.Record.Data, &b)
					taskID = b.TaskID
				case "session":
					var v domain.Session
					json.Unmarshal(m.Record.Data, &v)
					taskID = v.TaskID
				case "snooze":
					var v domain.Snooze
					json.Unmarshal(m.Record.Data, &v)
					taskID = v.TaskID
				}
				if taskID != "" && !linked(ctx, tx, taskID, "task") {
					// A late offline block/session for a cancelled occurrence is
					// acknowledged as deleted, so it cannot block the sync queue.
					parent, parentErr := read(ctx, tx, taskID)
					var task domain.Task
					if parentErr != nil || parent.Kind != "task" || !parent.Deleted || json.Unmarshal(parent.Data, &task) != nil || task.SeriesID == "" {
						return nil, ErrInvalid
					}
					m.Record.Deleted = true
				}
				if projectID != "" && !linked(ctx, tx, projectID, "project") {
					return nil, ErrInvalid
				}
				if m.Record.Kind == "session" && !m.Record.Deleted {
					var v domain.Session
					json.Unmarshal(m.Record.Data, &v)
					parent, e := read(ctx, tx, v.TaskID)
					if e != nil {
						return nil, e
					}
					var task domain.Task
					if e = json.Unmarshal(parent.Data, &task); e != nil {
						return nil, e
					}
					if v.End == nil && !v.Discarded && task.Status != "done" {
						if v.DeviceID != deviceID {
							return nil, ErrInvalid
						}
						// A connected client explicitly stops timers it has seen. An
						// unknown timer from another device retains overlap for reconciliation.
						rows, e := tx.QueryContext(ctx, `SELECT id,kind,version,deleted,data,seq FROM records WHERE kind='session' AND deleted=0 AND id<>? AND json_extract(data,'$.end') IS NULL AND COALESCE(json_extract(data,'$.discarded'),0)=0`, m.Record.ID)
						if e != nil {
							return nil, e
						}
						var active []domain.Record
						for rows.Next() {
							var a domain.Record
							var d string
							if e = rows.Scan(&a.ID, &a.Kind, &a.Version, &a.Deleted, &d, &a.Seq); e != nil {
								rows.Close()
								return nil, e
							}
							a.Data = json.RawMessage(d)
							active = append(active, a)
						}
						e = rows.Err()
						rows.Close()
						if e != nil {
							return nil, e
						}
						for _, a := range active {
							var prior domain.Session
							json.Unmarshal(a.Data, &prior)
							end := v.Start
							if prior.DeviceID != v.DeviceID {
								end = time.Now().UTC()
							}
							if !end.After(prior.Start) {
								end = prior.Start.Add(time.Millisecond)
							}
							prior.End = &end
							a.Data, _ = json.Marshal(prior)
							if _, e = save(ctx, tx, a); e != nil {
								return nil, e
							}
						}
					}
				}
			}
			result.Record, err = save(ctx, tx, m.Record)
			if err != nil {
				return nil, err
			}
		}
		payload, err := json.Marshal(result)
		if err != nil {
			return nil, err
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO operations(id,device_id,request_hash,result) VALUES (?,?,?,?)", m.OperationID, deviceID, fingerprint, string(payload)); err != nil {
			return nil, err
		}
		results = append(results, result)
	}
	if err = pruneCancelledOccurrences(ctx, tx); err != nil {
		return nil, err
	}
	if err = closeFinishedTimers(ctx, tx); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return results, nil
}

// Series cancellation is authoritative for instances materialized on offline
// devices too. Run inside the mutation transaction and publish tombstones through
// the normal changes feed, including children sent in a later sync batch.
func pruneCancelledOccurrences(ctx context.Context, tx *sql.Tx) error {
	rows, err := tx.QueryContext(ctx, `SELECT t.id,t.kind,t.version,t.deleted,t.data,t.seq,s.deleted,s.data FROM records t JOIN records s ON s.id=json_extract(t.data,'$.series_id') WHERE t.kind='task' AND t.deleted=0 AND s.kind='series'`)
	if err != nil {
		return err
	}
	var cancelled []domain.Record
	for rows.Next() {
		var r domain.Record
		var data, seriesData string
		var deleted bool
		if err := rows.Scan(&r.ID, &r.Kind, &r.Version, &r.Deleted, &data, &r.Seq, &deleted, &seriesData); err != nil {
			rows.Close()
			return err
		}
		r.Data = json.RawMessage(data)
		var task domain.Task
		var series domain.Series
		if err := json.Unmarshal(r.Data, &task); err != nil {
			rows.Close()
			return err
		}
		if err := json.Unmarshal([]byte(seriesData), &series); err != nil {
			rows.Close()
			return err
		}
		if deleted || cancelledOccurrence(series, task.Occurrence) {
			r.Deleted = true
			cancelled = append(cancelled, r)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, r := range cancelled {
		if _, err := save(ctx, tx, r); err != nil {
			return err
		}
	}
	rows, err = tx.QueryContext(ctx, `SELECT c.id,c.kind,c.version,c.deleted,c.data,c.seq FROM records c JOIN records t ON t.id=json_extract(c.data,'$.task_id') WHERE c.kind IN ('block','session','snooze') AND c.deleted=0 AND t.kind='task' AND t.deleted=1 AND COALESCE(json_extract(t.data,'$.series_id'),'')<>''`)
	if err != nil {
		return err
	}
	cancelled = nil
	for rows.Next() {
		var r domain.Record
		var data string
		if err := rows.Scan(&r.ID, &r.Kind, &r.Version, &r.Deleted, &data, &r.Seq); err != nil {
			rows.Close()
			return err
		}
		r.Data, r.Deleted = json.RawMessage(data), true
		cancelled = append(cancelled, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, r := range cancelled {
		if _, err := save(ctx, tx, r); err != nil {
			return err
		}
	}
	return nil
}

func cancelledOccurrence(series domain.Series, value string) bool {
	occurrence, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return false
	}
	for _, exception := range series.Exceptions {
		at, err := time.Parse(time.RFC3339Nano, exception)
		if err == nil && at.Truncate(time.Second).Equal(occurrence.Truncate(time.Second)) {
			return true
		}
	}
	if series.CancelledFrom != "" {
		cutoff, err := time.Parse(time.RFC3339Nano, series.CancelledFrom)
		if err == nil {
			return !occurrence.Before(cutoff)
		}
	}
	return false
}

// Completion is authoritative even when a stale offline timer arrives later.
// Run after the batch so an explicit client stop retains its exact timestamp.
func closeFinishedTimers(ctx context.Context, tx *sql.Tx) error {
	rows, err := tx.QueryContext(ctx, `SELECT s.id,s.kind,s.version,s.deleted,s.data,s.seq FROM records s JOIN records t ON t.id=json_extract(s.data,'$.task_id') WHERE s.kind='session' AND s.deleted=0 AND json_extract(s.data,'$.end') IS NULL AND COALESCE(json_extract(s.data,'$.discarded'),0)=0 AND (t.deleted=1 OR json_extract(t.data,'$.status')='done')`)
	if err != nil {
		return err
	}
	var active []domain.Record
	for rows.Next() {
		var r domain.Record
		var data string
		if err = rows.Scan(&r.ID, &r.Kind, &r.Version, &r.Deleted, &data, &r.Seq); err != nil {
			rows.Close()
			return err
		}
		r.Data = json.RawMessage(data)
		active = append(active, r)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, r := range active {
		var session domain.Session
		if err = json.Unmarshal(r.Data, &session); err != nil {
			return err
		}
		end := time.Now().UTC()
		if !end.After(session.Start) {
			end = session.Start.Add(time.Millisecond)
		}
		session.End = &end
		r.Data, err = json.Marshal(session)
		if err != nil {
			return err
		}
		if _, err = save(ctx, tx, r); err != nil {
			return err
		}
	}
	return nil
}

func equalJSON(left, right json.RawMessage) bool {
	var a, b any
	return json.Unmarshal(left, &a) == nil && json.Unmarshal(right, &b) == nil && reflect.DeepEqual(a, b)
}

func (s *Store) Changes(ctx context.Context, after int64, limit int) ([]domain.Record, int64, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT record,seq FROM changes WHERE seq>? ORDER BY seq LIMIT ?", after, limit)
	if err != nil {
		return nil, after, err
	}
	defer rows.Close()
	records := []domain.Record{}
	cursor := after
	for rows.Next() {
		var data string
		var seq int64
		if err = rows.Scan(&data, &seq); err != nil {
			return nil, after, err
		}
		var r domain.Record
		if err = json.Unmarshal([]byte(data), &r); err != nil {
			return nil, after, err
		}
		records = append(records, r)
		cursor = seq
	}
	return records, cursor, rows.Err()
}
func (s *Store) Devices(ctx context.Context) ([]map[string]string, error) {
	rows, e := s.DB.QueryContext(ctx, "SELECT id,name FROM devices WHERE revoked=0 ORDER BY name")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []map[string]string{}
	for rows.Next() {
		var id, name string
		if e = rows.Scan(&id, &name); e != nil {
			return nil, e
		}
		out = append(out, map[string]string{"id": id, "name": name})
	}
	return out, rows.Err()
}
func SafeError(err error) string {
	if errors.Is(err, ErrConflict) {
		return "operation_id_reused"
	}
	if errors.Is(err, ErrInvalid) {
		return "invalid_relationship"
	}
	if strings.HasPrefix(err.Error(), "invalid") || strings.HasPrefix(err.Error(), "unknown record") {
		return err.Error()
	}
	return "storage_error"
}
func (s *Store) Close() error   { return s.DB.Close() }
func (s *Store) String() string { return fmt.Sprintf("SQLite store") }
