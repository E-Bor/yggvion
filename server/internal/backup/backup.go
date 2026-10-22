// Package backup implements portable snapshots of end-to-end encrypted user data.
// It never restores authentication, server identity or executable database code.
package backup

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"yggvion/server/internal/store"
)

var ErrBusy = errors.New("backup operation already running")
var validID = regexp.MustCompile(`^[a-f0-9]{32}$`)
var validHash = regexp.MustCompile(`^[a-f0-9]{64}$`)

type Entry struct {
	ID      string    `json:"id"`
	Created time.Time `json:"created"`
	Bytes   int64     `json:"bytes"`
	Records int       `json:"records"`
	Files   int       `json:"files"`
	Reason  string    `json:"reason"`
}
type Config struct {
	EveryHours int `json:"every_hours"`
	KeepDaily  int `json:"keep_daily"`
	KeepWeekly int `json:"keep_weekly"`
}
type Status struct {
	Running   bool       `json:"running"`
	Operation string     `json:"operation"`
	Error     string     `json:"error,omitempty"`
	Finished  *time.Time `json:"finished,omitempty"`
}
type Manager struct {
	Store      *store.Store
	Dir, Files string
	DataMu     *sync.RWMutex
	mu         sync.Mutex
	config     Config
	status     Status
}

func Open(s *store.Store, dir, files string, lock *sync.RWMutex) (*Manager, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	m := &Manager{Store: s, Dir: dir, Files: files, DataMu: lock, config: Config{24, 7, 4}}
	data, err := os.ReadFile(filepath.Join(dir, "schedule.json"))
	if err == nil {
		if err = json.Unmarshal(data, &m.config); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if !validConfig(m.config) {
		return nil, errors.New("invalid backup configuration")
	}
	return m, nil
}
func writeFile(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".write-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func (m *Manager) Config() Config { m.mu.Lock(); defer m.mu.Unlock(); return m.config }
func validConfig(c Config) bool {
	return (c.EveryHours == 0 || c.EveryHours == 6 || c.EveryHours == 12 || c.EveryHours == 24 || c.EveryHours == 168) && c.KeepDaily >= 1 && c.KeepDaily <= 90 && c.KeepWeekly >= 0 && c.KeepWeekly <= 52
}
func (m *Manager) Configure(c Config) error {
	if !validConfig(c) {
		return errors.New("invalid schedule")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	if err = writeFile(filepath.Join(m.Dir, "schedule.json"), b); err != nil {
		return err
	}
	m.config = c
	return nil
}
func (m *Manager) Status() Status { m.mu.Lock(); defer m.mu.Unlock(); return m.status }

// Start owns the operation until completion; request cancellation does not kill
// an accepted job. Server shutdown does, through the supplied lifetime context.
func (m *Manager) Start(ctx context.Context, operation string, work func(context.Context) error) error {
	m.mu.Lock()
	if m.status.Running {
		m.mu.Unlock()
		return ErrBusy
	}
	m.status = Status{Running: true, Operation: operation}
	m.mu.Unlock()
	go func() {
		job, cancel := context.WithTimeout(ctx, 2*time.Hour)
		defer cancel()
		err := work(job)
		now := time.Now().UTC()
		m.mu.Lock()
		defer m.mu.Unlock()
		m.status.Running = false
		m.status.Finished = &now
		if err != nil {
			slog.Error("backup job failed", "operation", operation, "error", err)
			m.status.Error = "Операция не завершена. Проверьте свободное место, целостность архива и полноту вложений."
		}
	}()
	return nil
}
func (m *Manager) Path(id string) (string, error) {
	if !validID.MatchString(id) {
		return "", errors.New("invalid backup id")
	}
	return filepath.Join(m.Dir, id+".yggbackup"), nil
}
func (m *Manager) List() ([]Entry, error) {
	paths, err := filepath.Glob(filepath.Join(m.Dir, "*.json"))
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	for _, path := range paths {
		id := filepath.Base(path)
		id = id[:len(id)-5]
		if !validID.MatchString(id) {
			continue
		}
		b, e := os.ReadFile(path)
		if e != nil {
			return nil, e
		}
		var v Entry
		if e = json.Unmarshal(b, &v); e != nil {
			return nil, e
		}
		if v.ID != id {
			return nil, errors.New("invalid backup metadata")
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created.After(out[j].Created) })
	return out, nil
}
func (m *Manager) Delete(id string) error {
	path, err := m.Path(id)
	if err != nil {
		return err
	}
	if err = os.Remove(filepath.Join(m.Dir, id+".json")); err != nil {
		return err
	}
	return os.Remove(path)
}
func copyContext(ctx context.Context, w io.Writer, r io.Reader) (int64, error) {
	var total int64
	b := make([]byte, 128<<10)
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		n, err := r.Read(b)
		if n > 0 {
			nw, e := w.Write(b[:n])
			total += int64(nw)
			if e != nil {
				return total, e
			}
			if nw != n {
				return total, io.ErrShortWrite
			}
		}
		if err == io.EOF {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}
func add(ctx context.Context, t *tar.Writer, name string, size int64, r io.Reader) error {
	if err := t.WriteHeader(&tar.Header{Name: name, Size: size, Mode: 0600, Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	n, err := copyContext(ctx, t, io.LimitReader(r, size))
	if err == nil && n != size {
		err = io.ErrUnexpectedEOF
	}
	return err
}

func (m *Manager) Create(ctx context.Context, reason string) (Entry, error) {
	var entry Entry
	m.DataMu.RLock()
	snapshot, err := m.Store.Export(ctx)
	m.DataMu.RUnlock()
	if err != nil {
		return entry, err
	}
	if _, err = attachmentIndex(snapshot.Attachments); err != nil {
		return entry, err
	}
	b, err := json.Marshal(snapshot)
	if err != nil {
		return entry, err
	}
	if len(b) > 512<<20 {
		return entry, errors.New("snapshot too large")
	}
	f, err := os.CreateTemp(m.Dir, ".backup-*")
	if err != nil {
		return entry, err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	gz := gzip.NewWriter(f)
	archive := tar.NewWriter(gz)
	if err = add(ctx, archive, "snapshot.json", int64(len(b)), bytes.NewReader(b)); err != nil {
		return entry, err
	}
	sum := sha256.Sum256(b)
	checksum := hex.EncodeToString(sum[:])
	if err = add(ctx, archive, "snapshot.sha256", int64(len(checksum)), strings.NewReader(checksum)); err != nil {
		return entry, err
	}
	for _, a := range snapshot.Attachments {
		file, e := os.Open(filepath.Join(m.Files, a.ID))
		if e != nil {
			return entry, e
		}
		h := sha256.New()
		err = add(ctx, archive, "attachments/"+a.ID, a.Size, io.TeeReader(file, h))
		file.Close()
		if err != nil {
			return entry, err
		}
		if hex.EncodeToString(h.Sum(nil)) != a.ID {
			return entry, errors.New("attachment checksum mismatch")
		}
	}
	for _, w := range []io.Closer{archive, gz} {
		if err = w.Close(); err != nil {
			return entry, err
		}
	}
	if err = f.Sync(); err != nil {
		return entry, err
	}
	info, err := f.Stat()
	if err != nil {
		return entry, err
	}
	if err = f.Close(); err != nil {
		return entry, err
	}
	entry = Entry{ID: store.RandomSecret()[:32], Created: snapshot.Created, Bytes: info.Size(), Records: len(snapshot.Records), Files: len(snapshot.Attachments), Reason: reason}
	path, _ := m.Path(entry.ID)
	if err = os.Rename(f.Name(), path); err != nil {
		return entry, err
	}
	metadata, err := json.Marshal(entry)
	if err != nil {
		return entry, err
	}
	if err = writeFile(filepath.Join(m.Dir, entry.ID+".json"), metadata); err != nil {
		os.Remove(path)
		return entry, err
	}
	return entry, nil
}

func attachmentIndex(entries []store.Attachment) (map[string]store.Attachment, error) {
	index := make(map[string]store.Attachment, len(entries))
	var total int64
	for _, a := range entries {
		if !validHash.MatchString(a.ID) || a.Size < 0 || a.Size > 301<<20 {
			return nil, errors.New("invalid attachment")
		}
		if _, exists := index[a.ID]; exists {
			return nil, errors.New("duplicate attachment")
		}
		total += a.Size
		if total > 100<<30 {
			return nil, errors.New("uncompressed attachments exceed 100 GiB")
		}
		index[a.ID] = a
	}
	return index, nil
}

// Requiring EOF validates the gzip checksum without draining
// arbitrary compressed padding or extra gzip members from an untrusted archive.
func requireEOF(reader io.Reader) error {
	var one [1]byte
	n, err := io.ReadFull(reader, one[:])
	if n != 0 {
		return errors.New("unexpected trailing backup data")
	}
	if err != io.EOF {
		return err
	}
	return nil
}

// stage never uses archive paths as filesystem paths. Only expected content
// hashes are written; links, extra entries and duplicate entries are rejected.
func (m *Manager) stage(ctx context.Context, path string) (store.Snapshot, string, error) {
	var snapshot store.Snapshot
	f, err := os.Open(path)
	if err != nil {
		return snapshot, "", err
	}
	defer f.Close()
	buffered := bufio.NewReader(f)
	gz, err := gzip.NewReader(buffered)
	if err != nil {
		return snapshot, "", err
	}
	defer gz.Close()
	gz.Multistream(false)
	archive := tar.NewReader(gz)
	h, err := archive.Next()
	if err != nil {
		return snapshot, "", err
	}
	if h.Name != "snapshot.json" || h.Typeflag != tar.TypeReg || h.Size < 0 || h.Size > 512<<20 {
		return snapshot, "", errors.New("invalid snapshot header")
	}
	data, err := io.ReadAll(io.LimitReader(archive, 512<<20+1))
	if err != nil {
		return snapshot, "", err
	}
	h, err = archive.Next()
	if err != nil {
		return snapshot, "", err
	}
	if h.Name != "snapshot.sha256" || h.Typeflag != tar.TypeReg || h.Size != sha256.Size*2 {
		return snapshot, "", errors.New("invalid snapshot checksum header")
	}
	checksum, err := io.ReadAll(archive)
	if err != nil {
		return snapshot, "", err
	}
	sum := sha256.Sum256(data)
	if string(checksum) != hex.EncodeToString(sum[:]) {
		return snapshot, "", errors.New("snapshot checksum mismatch")
	}
	if err = json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, "", err
	}
	if err = store.ValidateSnapshot(snapshot); err != nil {
		return snapshot, "", err
	}
	stage, err := os.MkdirTemp(m.Dir, ".restore-*")
	if err != nil {
		return snapshot, "", err
	}
	success := false
	defer func() {
		if !success {
			os.RemoveAll(stage)
		}
	}()
	expected, err := attachmentIndex(snapshot.Attachments)
	if err != nil {
		return snapshot, "", err
	}
	seen := map[string]bool{}
	for {
		h, err = archive.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return snapshot, "", err
		}
		id := filepath.Base(h.Name)
		a, ok := expected[id]
		if !ok || h.Name != "attachments/"+id || seen[id] || h.Typeflag != tar.TypeReg || h.Size != a.Size {
			return snapshot, "", errors.New("unexpected archive entry")
		}
		seen[id] = true
		file, e := os.OpenFile(filepath.Join(stage, id), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return snapshot, "", e
		}
		hash := sha256.New()
		n, e := copyContext(ctx, io.MultiWriter(file, hash), archive)
		syncErr := file.Sync()
		closeErr := file.Close()
		if e != nil {
			return snapshot, "", e
		}
		if syncErr != nil {
			return snapshot, "", syncErr
		}
		if closeErr != nil {
			return snapshot, "", closeErr
		}
		if n != a.Size || hex.EncodeToString(hash.Sum(nil)) != id {
			return snapshot, "", errors.New("checksum mismatch")
		}
	}
	if err = requireEOF(gz); err != nil {
		return snapshot, "", err
	}
	if err = requireEOF(buffered); err != nil {
		return snapshot, "", err
	}
	if len(seen) != len(expected) {
		return snapshot, "", errors.New("missing attachments")
	}
	success = true
	return snapshot, stage, nil
}

func (m *Manager) Restore(ctx context.Context, path string) error {
	snapshot, stage, err := m.stage(ctx, path)
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	// Hold the exclusive lock from the safety snapshot through replacement so
	// edits cannot slip between them and disappear during restore.
	m.DataMu.Lock()
	defer m.DataMu.Unlock()
	keyID, err := m.Store.EncryptionKey(ctx)
	if err != nil {
		return err
	}
	if keyID == "" {
		// A new server has nothing to back up. Reject any unexpected unconfigured data.
		var count int
		if err = m.Store.DB.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM records)+(SELECT count(*) FROM attachments)").Scan(&count); err != nil {
			return err
		}
		if count != 0 {
			return errors.New("unconfigured server contains private data")
		}
	} else {
		// Create's read-lock is already owned exclusively here; keep the shared lock.
		safety := &Manager{Store: m.Store, Dir: m.Dir, Files: m.Files, DataMu: &sync.RWMutex{}}
		if _, err = safety.Create(ctx, "before_restore"); err != nil {
			return fmt.Errorf("safety backup: %w", err)
		}
	}
	if err = os.MkdirAll(m.Files, 0700); err != nil {
		return err
	}
	for _, a := range snapshot.Attachments {
		if err = os.Rename(filepath.Join(stage, a.ID), filepath.Join(m.Files, a.ID)); err != nil {
			return err
		}
	}
	return m.Store.Restore(ctx, snapshot)
}

func (m *Manager) Import(ctx context.Context, path string) (Entry, error) {
	var out Entry
	snapshot, stage, err := m.stage(ctx, path)
	if err != nil {
		return out, err
	}
	defer os.RemoveAll(stage)
	source, err := os.Open(path)
	if err != nil {
		return out, err
	}
	defer source.Close()
	target, err := os.CreateTemp(m.Dir, ".import-*")
	if err != nil {
		return out, err
	}
	defer os.Remove(target.Name())
	defer target.Close()
	if _, err = copyContext(ctx, target, source); err != nil {
		return out, err
	}
	if err = target.Sync(); err != nil {
		return out, err
	}
	info, err := target.Stat()
	if err != nil {
		return out, err
	}
	if err = target.Close(); err != nil {
		return out, err
	}
	out = Entry{ID: store.RandomSecret()[:32], Created: snapshot.Created, Bytes: info.Size(), Records: len(snapshot.Records), Files: len(snapshot.Attachments), Reason: "import"}
	dest, _ := m.Path(out.ID)
	if err = os.Rename(target.Name(), dest); err != nil {
		return out, err
	}
	data, err := json.Marshal(out)
	if err != nil {
		os.Remove(dest)
		return out, err
	}
	if err = writeFile(filepath.Join(m.Dir, out.ID+".json"), data); err != nil {
		os.Remove(dest)
		return out, err
	}
	return out, nil
}

func (m *Manager) Prune() error {
	entries, err := m.List()
	if err != nil {
		return err
	}
	c := m.Config()
	days, weeks := map[string]bool{}, map[string]bool{}
	for _, entry := range entries {
		if entry.Reason != "scheduled" {
			continue
		}
		day := entry.Created.Format("2006-01-02")
		y, w := entry.Created.ISOWeek()
		week := fmt.Sprintf("%d-%d", y, w)
		keep := false
		if !days[day] && len(days) < c.KeepDaily {
			days[day] = true
			keep = true
		}
		if !weeks[week] && len(weeks) < c.KeepWeekly {
			weeks[week] = true
			keep = true
		}
		if !keep {
			if err = m.Delete(entry.ID); err != nil {
				return err
			}
		}
	}
	return nil
}
func (m *Manager) Run(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c := m.Config()
			if c.EveryHours == 0 {
				continue
			}
			entries, err := m.List()
			if err != nil {
				continue
			}
			if len(entries) > 0 && time.Since(entries[0].Created) < time.Duration(c.EveryHours)*time.Hour {
				continue
			}
			_ = m.Start(ctx, "scheduled", func(ctx context.Context) error {
				entry, err := m.Create(ctx, "scheduled")
				if err != nil {
					return err
				}
				if err = m.Replicate(ctx, entry); err != nil {
					return err
				}
				return m.Prune()
			})
		}
	}
}
