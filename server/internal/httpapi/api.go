package httpapi

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"yggvion/server/internal/backup"
	"yggvion/server/internal/domain"
	"yggvion/server/internal/metrics"
	"yggvion/server/internal/store"
)

type API struct {
	PublicURL    string
	EnsurePublic func(context.Context) (string, error)
	ShareClock   func() time.Time
	shareLimit   shareLimiter
	limits       apiLimits
	Store        *store.Store
	PairingKey   string
	Files        string
	DataMu       sync.RWMutex
	Backups      *backup.Manager
	Lifetime     context.Context
	CAPEM        string
	Metrics      *metrics.Collector
	pairWindow   time.Time
	pairAttempts int
	mu           sync.Mutex
	subscribers  map[chan struct{}]struct{}
}
type deviceKey struct{}

func New(s *store.Store, key, files string) *API {
	return &API{Store: s, PairingKey: key, Files: files, Lifetime: context.Background(), Metrics: metrics.New(filepath.Dir(files)), subscribers: make(map[chan struct{}]struct{})}
}
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { write(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("POST /api/v1/pair", a.pair)
	mux.Handle("POST /api/v1/sync", a.auth(a.current(http.HandlerFunc(a.push))))
	mux.Handle("GET /api/v1/changes", a.auth(a.current(http.HandlerFunc(a.changes))))
	mux.Handle("GET /api/v1/events", a.auth(http.HandlerFunc(a.events)))
	mux.Handle("GET /api/v1/devices", a.auth(http.HandlerFunc(a.devices)))
	mux.Handle("DELETE /api/v1/devices/{id}", a.auth(http.HandlerFunc(a.revoke)))
	mux.Handle("PUT /api/v1/attachments/{id}", a.auth(a.current(http.HandlerFunc(a.upload))))
	mux.Handle("GET /api/v1/attachments/{id}", a.auth(a.current(http.HandlerFunc(a.download))))
	mux.Handle("GET /api/v1/state", a.auth(http.HandlerFunc(a.state)))
	mux.Handle("POST /api/v1/invitations", a.auth(http.HandlerFunc(a.invite)))
	mux.Handle("GET /api/v1/metrics", a.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		snapshot, err := a.Metrics.Read(r.Context())
		if err != nil {
			fail(w, 503, "metrics_unavailable")
			return
		}
		write(w, 200, snapshot)
	})))
	a.encryptionRoutes(mux)
	a.backupRoutes(mux)
	a.calendarShareRoutes(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		a.guard(mux).ServeHTTP(w, r)
	})
}
func write(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if e := json.NewEncoder(w).Encode(v); e != nil {
		slog.Warn("response write failed", "error", e)
	}
}
func fail(w http.ResponseWriter, status int, code string) {
	write(w, status, map[string]string{"error": code})
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if e := dec.Decode(v); e != nil {
		return e
	}
	if e := dec.Decode(&struct{}{}); e != io.EOF {
		return errors.New("extra JSON data")
	}
	return nil
}
func (a *API) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		source := requestSource(r)
		if !a.limits.beginAuth(source, time.Now()) {
			limited(w)
			return
		}
		header := r.Header.Get("Authorization")
		token := strings.TrimPrefix(header, "Bearer ")
		if !strings.HasPrefix(header, "Bearer ") || !domain.ValidHash(token) {
			a.limits.endAuth(source, true)
			fail(w, 401, "unauthorized")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		id, err := a.Store.Authorize(ctx, token)
		cancel()
		a.limits.endAuth(source, err != nil)
		if err != nil {
			fail(w, 401, "unauthorized")
			return
		}
		release, ok := a.limits.beginDevice(id, r.URL.Path)
		if !ok {
			limited(w)
			return
		}
		defer release()
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey{}, id)))
	})
}
func (a *API) pair(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	if time.Since(a.pairWindow) > time.Minute {
		a.pairWindow = time.Now()
		a.pairAttempts = 0
	}
	a.pairAttempts++
	allowed := a.pairAttempts <= 30
	a.mu.Unlock()
	if !allowed {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "rate_limited")
		return
	}
	var input struct {
		Name string `json:"name"`
		Key  string `json:"key"`
	}
	if decode(w, r, &input) != nil {
		fail(w, 400, "invalid_json")
		return
	}
	if strings.TrimSpace(input.Name) == "" || len(input.Name) > 100 {
		fail(w, 400, "invalid_device_name")
		return
	}
	id, token, e := a.Store.PairInvitation(r.Context(), input.Key, input.Name)
	if errors.Is(e, sql.ErrNoRows) {
		got, want := sha256.Sum256([]byte(input.Key)), sha256.Sum256([]byte(a.PairingKey))
		if len(a.PairingKey) < 32 || subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			fail(w, 401, "invalid_pairing_key")
			return
		}
		id, token, e = a.Store.Pair(r.Context(), input.Name)
	}
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 201, map[string]any{"device_id": id, "token": token, "protocol": 6})
}
func (a *API) push(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Mutations []domain.Mutation `json:"mutations"`
	}
	if decode(w, r, &input) != nil || len(input.Mutations) == 0 || len(input.Mutations) > 100 {
		fail(w, 400, "invalid_batch")
		return
	}
	results, e := a.Store.Apply(r.Context(), r.Context().Value(deviceKey{}).(string), input.Mutations)
	if e != nil {
		code := store.SafeError(e)
		status := 400
		if code == "storage_error" {
			status = 500
			slog.Error("sync failed", "error", e)
		}
		fail(w, status, code)
		return
	}
	write(w, 200, map[string]any{"results": results})
	a.broadcast()
}
func (a *API) changes(w http.ResponseWriter, r *http.Request) {
	after := int64(0)
	if value := r.URL.Query().Get("after"); value != "" {
		v, e := strconv.ParseInt(value, 10, 64)
		if e != nil || v < 0 {
			fail(w, 400, "invalid_cursor")
			return
		}
		after = v
	}
	rows, cursor, more, e := a.Store.Changes(r.Context(), after, 500)
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"records": rows, "cursor": cursor, "has_more": more})
}
func (a *API) devices(w http.ResponseWriter, r *http.Request) {
	devices, e := a.Store.Devices(r.Context())
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"devices": devices})
}
func (a *API) revoke(w http.ResponseWriter, r *http.Request) {
	if !domain.ValidID(r.PathValue("id")) {
		fail(w, 400, "invalid_id")
		return
	}
	if e := a.Store.Revoke(r.Context(), r.PathValue("id")); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	w.WriteHeader(204)
}
func (a *API) broadcast() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for c := range a.subscribers {
		select {
		case c <- struct{}{}:
		default:
		}
	}
}
func (a *API) events(w http.ResponseWriter, r *http.Request) {
	f, ok := w.(http.Flusher)
	if !ok {
		fail(w, 500, "stream_unavailable")
		return
	}
	c := make(chan struct{}, 1)
	a.mu.Lock()
	a.subscribers[c] = struct{}{}
	a.mu.Unlock()
	defer func() { a.mu.Lock(); delete(a.subscribers, c); a.mu.Unlock() }()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(10 * time.Second))
		if _, e := io.WriteString(w, "event: sync\ndata: {}\n\n"); e != nil {
			return
		}
		f.Flush()
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
			_, err := a.Store.Authorize(ctx, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
			cancel()
			if err != nil {
				return
			}
		case <-c:
		}
	}
}
func attachmentID(id string) bool {
	if len(id) != 64 {
		return false
	}
	_, e := hex.DecodeString(id)
	return e == nil && strings.ToLower(id) == id
}

const maxAttachmentBytes = 300 << 20

func (a *API) upload(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	keyID, err := a.Store.EncryptionKey(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	uploadedKey := r.Header.Get("X-Yggvion-Encryption")
	if !domain.ValidHash(keyID) || !domain.ValidHash(uploadedKey) ||
		(uploadedKey != keyID && r.Header.Get("X-Yggvion-Rekey-From") != keyID) {
		fail(w, 400, "encryption_required")
		return
	}
	limit := int64(maxAttachmentBytes + 1024*1024)
	if !attachmentID(id) {
		fail(w, 400, "invalid_hash")
		return
	}
	if r.ContentLength > limit {
		fail(w, 413, "file_too_large_or_incomplete")
		return
	}
	// Large uploads need more time than ordinary API requests, while remaining bounded.
	if e := http.NewResponseController(w).SetReadDeadline(time.Now().Add(15 * time.Minute)); e != nil && !errors.Is(e, http.ErrNotSupported) {
		fail(w, 500, "storage_error")
		return
	}
	if e := os.MkdirAll(a.Files, 0700); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	f, e := os.CreateTemp(a.Files, "upload-")
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	h := sha256.New()
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	n, e := io.Copy(io.MultiWriter(f, h), r.Body)
	if e != nil {
		fail(w, 413, "file_too_large_or_incomplete")
		return
	}
	if hex.EncodeToString(h.Sum(nil)) != id {
		fail(w, 400, "hash_mismatch")
		return
	}
	if e = f.Sync(); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	if e = f.Close(); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	if e = os.Rename(f.Name(), filepath.Join(a.Files, id)); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	name, mediaType := "encrypted", "application/octet-stream"
	_, e = a.Store.DB.ExecContext(r.Context(), "INSERT INTO attachments(id,name,size,media_type) VALUES(?,?,?,?) ON CONFLICT(id) DO NOTHING", id, name, n, mediaType)
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	if _, e = a.Store.DB.ExecContext(r.Context(), "INSERT INTO encrypted_uploads VALUES(?,?) ON CONFLICT(id) DO UPDATE SET key_id=excluded.key_id", id, uploadedKey); e != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 201, map[string]any{"id": id, "size": n})
}
func (a *API) download(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !attachmentID(id) {
		fail(w, 400, "invalid_hash")
		return
	}
	var mediaType string
	e := a.Store.DB.QueryRowContext(r.Context(), "SELECT media_type FROM attachments WHERE id=?", id).Scan(&mediaType)
	if errors.Is(e, sql.ErrNoRows) {
		fail(w, 404, "not_found")
		return
	}
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	f, e := os.Open(filepath.Join(a.Files, id))
	if e != nil {
		fail(w, 404, "not_found")
		return
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		fail(w, 500, "storage_error")
		return
	}
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, id))
	http.ServeContent(w, r, id, info.ModTime(), f)
}
