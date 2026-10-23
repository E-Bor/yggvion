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
var ErrInvalid = errors.New("invalid record or request")

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
	var schemaVersion int
	if err = db.QueryRow("PRAGMA user_version").Scan(&schemaVersion); err != nil || (schemaVersion != 0 && schemaVersion != 7 && schemaVersion != SchemaVersion) {
		db.Close()
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("unsupported database version %d; create a fresh server data directory", schemaVersion)
	}
	for _, query := range []string{"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000", "PRAGMA foreign_keys=ON", "PRAGMA secure_delete=ON"} {
		if _, err = db.Exec(query); err != nil {
			db.Close()
			return nil, err
		}
	}
	if err = migrate(db, schemaVersion); err != nil {
		db.Close()
		return nil, err
	}

	if path != ":memory:" {
		if err = os.Chmod(path, 0600); err != nil {
			db.Close()
			return nil, err
		}
	}
	s := &Store{DB: db}
	if _, err = db.Exec("INSERT OR IGNORE INTO server_meta(key,value) VALUES('generation',?)", RandomSecret()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
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
	// Keep the latest change of every record, including tombstones. Sequence
	// numbers never go backwards, so any offline cursor can still catch up.
	if _, err = tx.ExecContext(ctx, "DELETE FROM changes WHERE seq=(SELECT seq FROM records WHERE id=?)", r.ID); err != nil {
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

func (s *Store) Apply(ctx context.Context, deviceID string, mutations []domain.Mutation) ([]domain.Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	keyID, err := encryptionKey(ctx, tx)
	if err != nil {
		return nil, err
	}
	if keyID == "" {
		return nil, ErrInvalid
	}
	results := make([]domain.Result, 0, len(mutations))
	for _, m := range mutations {
		if !domain.ValidID(m.OperationID) {
			return nil, ErrInvalid
		}
		envelope, e := domain.ReadEnvelope(m.Record)
		if e != nil || envelope.KeyID != keyID {
			return nil, ErrInvalid
		}
		for _, id := range envelope.Files {
			var registered string
			if e = tx.QueryRowContext(ctx, "SELECT key_id FROM encrypted_uploads WHERE id=?", id).Scan(&registered); e != nil || registered != keyID {
				return nil, ErrInvalid
			}
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
			result.Record = current
		} else if current.Version != m.Record.Version {
			result.Status = "conflict"
			result.Record = current
		} else {
			result.Record, err = save(ctx, tx, m.Record)
			if err != nil {
				return nil, err
			}
		}
		payload, err := json.Marshal(result)
		if err != nil {
			return nil, err
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO operations(id,device_id,request_hash,result,created,payload_bytes) VALUES (?,?,?,?,?,?)", m.OperationID, deviceID, fingerprint, string(payload), time.Now().Unix(), len(payload)); err != nil {
			return nil, err
		}
		if result.Status == "applied" {
			if _, err = tx.ExecContext(ctx, "DELETE FROM guest_inbox WHERE id=?", m.Record.ID); err != nil {
				return nil, err
			}
		}
		results = append(results, result)
	}
	if err = compactOperations(ctx, tx, time.Now()); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return results, nil
}

func equalJSON(left, right json.RawMessage) bool {
	var a, b any
	return json.Unmarshal(left, &a) == nil && json.Unmarshal(right, &b) == nil && reflect.DeepEqual(a, b)
}

func (s *Store) Changes(ctx context.Context, after int64, limit int) ([]domain.Record, int64, bool, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT record,seq FROM changes WHERE seq>? ORDER BY seq LIMIT ?", after, limit+1)
	if err != nil {
		return nil, after, false, err
	}
	defer rows.Close()
	records := []domain.Record{}
	cursor, bytes := after, 0
	more := false
	for rows.Next() {
		var data string
		var seq int64
		if err = rows.Scan(&data, &seq); err != nil {
			return nil, after, false, err
		}
		if len(records) >= limit || (len(records) > 0 && bytes+len(data) > maxChangePageBytes) {
			more = true
			break
		}
		var r domain.Record
		if err = json.Unmarshal([]byte(data), &r); err != nil {
			return nil, after, false, err
		}
		records = append(records, r)
		cursor = seq
		bytes += len(data)
	}
	return records, cursor, more, rows.Err()
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
