package httpapi

import (
	"context"
	"io"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"yggvion/server/internal/backup"
)

func TestGuestsCannotReferenceOrUploadPrivateFiles(t *testing.T) {
	f := newShareFixture(t)
	_, token := f.share(t)
	for i, value := range []string{
		"[file](attachment:" + strings.Repeat("a", 64) + ")",
		"![image](AtTaChMeNt:" + strings.Repeat("b", 64) + ")",
		"```\nattachment:" + strings.Repeat("c", 64) + "\n```",
	} {
		for _, title := range []bool{false, true} {
			p := f.propose("files")
			if title {
				p.Title = strings.ReplaceAll(value, "\n", " ")
			} else {
				p.Description = value
			}
			if w := f.call("POST", "/public/proposals", token, p); w.Code != 400 {
				t.Fatalf("case %d title=%v: %d", i, title, w.Code)
			}
		}
	}
	if w := f.call("PUT", "/api/v1/attachments/"+strings.Repeat("a", 64), token, nil); w.Code != 401 {
		t.Fatal("guest upload allowed", w.Code)
	}
	if w := f.call("GET", "/api/v1/attachments/"+strings.Repeat("a", 64), token, nil); w.Code != 401 {
		t.Fatal("guest read allowed", w.Code)
	}
	proposals, err := f.api.Store.GuestProposals(context.Background())
	if err != nil || len(proposals) != 0 {
		t.Fatal("invalid guest input reached inbox", proposals, err)
	}
	p := f.propose("valid-text")
	p.Description = "Обычный текст и [сайт](https://example.com)"
	if w := f.call("POST", "/public/proposals", token, p); w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
}

func TestPrivateAuthBudgetAndSourceCannotBeSpoofed(t *testing.T) {
	s, _, token := setup(t)
	a := New(s, "", t.TempDir())
	h := a.Handler()
	call := func(source, credential string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v1/devices", nil)
		r.RemoteAddr = source
		r.Header.Set("Authorization", "Bearer "+credential)
		r.Header.Set("X-Forwarded-For", time.Now().String())
		r.Header.Set("X-Real-IP", "198.51.100.99")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for i := 0; i < 30; i++ {
		if w := call("192.0.2.1:1000", strings.Repeat("f", 64)); w.Code != 401 {
			t.Fatal(i, w.Code)
		}
	}
	if w := call("192.0.2.1:2000", strings.Repeat("e", 64)); w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatal(w.Code, w.Header())
	}
	if w := call("192.0.2.2:1000", token); w.Code != 200 {
		t.Fatal("another source blocked", w.Code)
	}
	// Closing SQLite proves exhausted attempts are rejected before DB lookup.
	s.Close()
	if w := call("192.0.2.1:3000", token); w.Code != 429 {
		t.Fatal("exhausted source reached storage", w.Code)
	}
}

func TestPrivateConcurrencyCapsReleaseAndDoNotMixStreams(t *testing.T) {
	var limits apiLimits
	var streams []func()
	for i := 0; i < 2; i++ {
		release, ok := limits.beginDevice("phone", "/api/v1/events")
		if !ok {
			t.Fatal("stream refused")
		}
		streams = append(streams, release)
	}
	if _, ok := limits.beginDevice("phone", "/api/v1/events"); ok {
		t.Fatal("third stream allowed")
	}
	release, ok := limits.beginDevice("phone", "/api/v1/changes")
	if !ok {
		t.Fatal("SSE blocked ordinary sync")
	}
	release()
	heavy, ok := limits.beginDevice("desktop", "/api/v1/snapshot")
	if !ok {
		t.Fatal("snapshot refused")
	}
	if _, ok = limits.beginDevice("phone", "/api/v1/encryption/password"); ok {
		t.Fatal("parallel memory-heavy request allowed")
	}
	heavy()
	heavy, ok = limits.beginDevice("phone", "/api/v1/encryption/password")
	if !ok {
		t.Fatal("slot leaked")
	}
	heavy()
	for _, release := range streams {
		release()
	}
	if len(limits.devices) != 0 || limits.streams != 0 || limits.requests != 0 {
		t.Fatal("activity leaked")
	}
}

func TestPrivateLimiterBoundsMemoryAndIgnoresIPv6HostRotation(t *testing.T) {
	var l apiLimits
	now := time.Now()
	for i := 0; i < 120; i++ {
		if !l.allow("source", now) {
			t.Fatal(i)
		}
	}
	if l.allow("source", now) {
		t.Fatal("burst was unlimited")
	}
	if !l.allow("other", now) {
		t.Fatal("one source exhausted global budget")
	}
	if !l.allow("source", now.Add(time.Second)) {
		t.Fatal("budget not refilled")
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "[2001:db8:1:2::1]:1"
	first := requestSource(r)
	r.RemoteAddr = "[2001:db8:1:2::ffff]:2"
	if first != requestSource(r) {
		t.Fatal("IPv6 host rotation bypasses budget")
	}
	l.allow("later", now.Add(6*time.Minute))
	if len(l.sources) != 1 {
		t.Fatal("stale sources retained")
	}
}

type unreadBody struct{ t *testing.T }

func (b unreadBody) Read([]byte) (int, error) {
	b.t.Error("rejected upload body was read")
	return 0, io.EOF
}
func (b unreadBody) Close() error { return nil }

type signalReader struct {
	io.Reader
	entered   chan struct{}
	signalled bool
}

func (s *signalReader) Read(p []byte) (int, error) {
	if !s.signalled {
		s.signalled = true
		close(s.entered)
	}
	return s.Reader.Read(p)
}

func TestImportReservesJobBeforeReadingBodyAndCleansInterruptedUpload(t *testing.T) {
	s, _, token := setup(t)
	a := New(s, "", t.TempDir())
	var err error
	a.Backups, err = backup.Open(s, t.TempDir(), a.Files, &a.DataMu)
	if err != nil {
		t.Fatal(err)
	}
	h := a.Handler()
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	body := &signalReader{Reader: reader, entered: make(chan struct{})}
	r := httptest.NewRequest("POST", "/api/v1/backups/import", body)
	r.Header.Set("Authorization", "Bearer "+token)
	first := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { defer close(done); h.ServeHTTP(first, r) }()
	select {
	case <-body.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("upload did not start")
	}
	second := httptest.NewRequest("POST", "/api/v1/backups/import", nil)
	second.Body = unreadBody{t}
	second.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, second)
	if w.Code != 409 {
		t.Fatal("parallel upload not rejected", w.Code, w.Body)
	}
	writer.CloseWithError(io.ErrUnexpectedEOF)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("interrupted upload did not stop")
	}
	if first.Code != 400 || a.Backups.Status().Running {
		t.Fatal("failed upload retained slot", first.Code)
	}
	files, _ := filepath.Glob(filepath.Join(a.Backups.Dir, ".upload-*"))
	if len(files) != 0 {
		t.Fatal("partial upload remains", files)
	}
	tooLarge := httptest.NewRequest("POST", "/api/v1/backups/import", nil)
	tooLarge.Body = unreadBody{t}
	tooLarge.ContentLength = backup.MaxImportBytes + 1
	tooLarge.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, tooLarge)
	if w.Code != 413 || a.Backups.Status().Running {
		t.Fatal("oversized upload retained slot", w.Code)
	}
}
