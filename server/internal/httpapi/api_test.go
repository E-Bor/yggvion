package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func setupEmpty(t *testing.T) (*store.Store, http.Handler, string) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	_, token, err := s.Pair(context.Background(), "Test device")
	if err != nil {
		t.Fatal(err)
	}
	return s, New(s, strings.Repeat("test", 8), t.TempDir()).Handler(), token
}

const testKeyID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func encryptedRecord(id, kind, content string) domain.Record {
	// Opaque deterministic test bytes: crypto is exercised by Flutter integration tests.
	box := sha256.Sum256([]byte(content))
	data, _ := json.Marshal(domain.Envelope{E2EE: 1, KeyID: testKeyID,
		Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)),
		Box:   base64.StdEncoding.EncodeToString(box[:]), Files: []string{}})
	return domain.Record{ID: id, Kind: kind, Data: data}
}
func authorizeTestRequest(t *testing.T, h http.Handler, r *http.Request, token string) {
	t.Helper()
	r.Header.Set("Authorization", "Bearer "+token)
	state := httptest.NewRequest("GET", "/api/v1/state", nil)
	state.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	h.ServeHTTP(response, state)
	var data struct{ Generation string }
	if response.Code == 200 {
		if err := json.Unmarshal(response.Body.Bytes(), &data); err != nil {
			t.Fatal(err)
		}
		r.Header.Set("X-Yggvion-Generation", data.Generation)
	}
	r.Header.Set("X-Yggvion-Encryption", testKeyID)
}

func setup(t *testing.T) (*store.Store, http.Handler, string) {
	t.Helper()
	s, h, token := setupEmpty(t)
	if err := s.EnableEncryption(context.Background(), testKeyID, testPasswordEnvelope(testKeyID, 1)); err != nil {
		t.Fatal(err)
	}
	return s, h, token
}
func request(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var b []byte
	if body != nil {
		var e error
		b, e = json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	if token != "" {
		authorizeTestRequest(t, h, r, token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func task(id, title string) domain.Record {
	return encryptedRecord(id, "task", title)
}
func push(t *testing.T, h http.Handler, token string, mutations ...domain.Mutation) *httptest.ResponseRecorder {
	return request(t, h, "POST", "/api/v1/sync", token, map[string]any{"mutations": mutations})
}
func decodeResults(t *testing.T, w *httptest.ResponseRecorder) []domain.Result {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var out struct {
		Results []domain.Result `json:"results"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &out); e != nil {
		t.Fatal(e)
	}
	return out.Results
}

func TestAuthAndPairing(t *testing.T) {
	s, h, token := setup(t)
	for _, path := range []string{"/api/v1/changes", "/api/v1/devices", "/api/v1/attachments/abc", "/api/v1/events"} {
		if w := request(t, h, "GET", path, "", nil); w.Code != 401 {
			t.Fatalf("unprotected %s: %d", path, w.Code)
		}
	}
	if w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "Device", "key": "wrong"}); w.Code != 401 {
		t.Fatal(w.Code)
	}
	w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "Phone", "key": strings.Repeat("test", 8)})
	if w.Code != 201 {
		t.Fatal(w.Body.String())
	}
	id, e := s.Authorize(context.Background(), token)
	if e != nil {
		t.Fatal(e)
	}
	if w = request(t, h, "DELETE", "/api/v1/devices/"+id, token, nil); w.Code != 204 {
		t.Fatal(w.Code)
	}
	if w = request(t, h, "GET", "/api/v1/changes", token, nil); w.Code != 401 {
		t.Fatal("revoked token accepted")
	}
}

func TestVersionConflictAndIdempotency(t *testing.T) {
	_, h, token := setup(t)
	m := domain.Mutation{OperationID: "op-1", Record: task("task-1", "Original")}
	first := decodeResults(t, push(t, h, token, m))[0]
	if first.Record.Version != 1 || first.Record.Seq != 1 {
		t.Fatal(first)
	}
	retry := decodeResults(t, push(t, h, token, m))[0]
	if retry.Record.Version != 1 {
		t.Fatal("duplicate write")
	}
	changed := m
	changed.Record = task("task-1", "Changed")
	if w := push(t, h, token, changed); w.Code != 400 {
		t.Fatal("reused operation id accepted")
	}
	changed.OperationID = "op-2"
	conflict := decodeResults(t, push(t, h, token, changed))[0]
	if conflict.Status != "conflict" || conflict.Record.Version != 1 {
		t.Fatal(conflict)
	}
	changed.OperationID = "op-3"
	changed.Record.Version = 1
	if result := decodeResults(t, push(t, h, token, changed))[0]; result.Record.Version != 2 {
		t.Fatal(result)
	}
	w := request(t, h, "GET", "/api/v1/changes?after=1", token, nil)
	var changes struct {
		Records []domain.Record `json:"records"`
		Cursor  int64           `json:"cursor"`
	}
	json.Unmarshal(w.Body.Bytes(), &changes)
	if len(changes.Records) != 1 || changes.Cursor != 2 {
		t.Fatal(w.Body.String())
	}
}

func TestAtomicInvalidBatch(t *testing.T) {
	s, h, token := setup(t)
	invalid := domain.Record{ID: "block-1", Kind: "block", Data: json.RawMessage(`{"task_id":"missing","start":"2026-10-19T09:00:00Z","end":"2026-10-19T10:00:00Z","timezone":"UTC","reminders":[]}`)}
	w := push(t, h, token, domain.Mutation{OperationID: "one", Record: task("task-1", "Task")}, domain.Mutation{OperationID: "two", Record: invalid})
	if w.Code != 400 {
		t.Fatal(w.Body.String())
	}
	records, _, e := s.Changes(context.Background(), 0, 100)
	if e != nil {
		t.Fatal(e)
	}
	if len(records) != 0 {
		t.Fatal("partial transaction committed")
	}
}

func TestValidation(t *testing.T) {
	_, h, token := setup(t)
	valid := task("valid", "Task")
	for name, record := range map[string]domain.Record{
		"plaintext": {ID: "plain", Kind: "task", Data: json.RawMessage(`{"title":"private","status":"todo"}`)},
		"id":        {ID: "../bad", Kind: valid.Kind, Data: valid.Data},
		"kind":      {ID: "bad-kind", Kind: "unknown", Data: valid.Data},
		"version":   {ID: "bad-version", Kind: valid.Kind, Version: -1, Data: valid.Data},
		"payload":   {ID: "bad-box", Kind: valid.Kind, Data: json.RawMessage(`{"e2ee":1}`)},
	} {
		t.Run(name, func(t *testing.T) {
			if w := push(t, h, token, domain.Mutation{OperationID: name, Record: record}); w.Code != 400 {
				t.Fatal(w.Code, w.Body)
			}
		})
	}
}
func TestEncryptedKindsRoundTripWithoutServerSideRewrites(t *testing.T) {
	s, h, token := setup(t)
	var mutations []domain.Mutation
	for _, kind := range []string{"task", "block", "session", "note", "note_folder", "project", "settings", "series", "snooze"} {
		mutations = append(mutations, domain.Mutation{OperationID: kind, Record: encryptedRecord(kind, kind, "opaque "+kind)})
	}
	results := decodeResults(t, push(t, h, token, mutations...))
	records, _, err := s.Changes(context.Background(), 0, 100)
	if err != nil || len(records) != len(mutations) {
		t.Fatal(records, err)
	}
	for i, record := range records {
		if !bytes.Equal(record.Data, mutations[i].Record.Data) {
			t.Fatal("server changed opaque payload", record.Kind)
		}
		results[i].Record.Deleted = true
		mutations[i] = domain.Mutation{OperationID: "delete-" + record.Kind, Record: results[i].Record}
	}
	deleted := decodeResults(t, push(t, h, token, mutations...))
	for _, result := range deleted {
		if !result.Record.Deleted || result.Record.Version != 2 {
			t.Fatal(result)
		}
	}
}

func TestConcurrentDevices(t *testing.T) {
	s, h, token := setup(t)
	initial := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "create", Record: task("task", "Original")}))[0].Record
	var group sync.WaitGroup
	results := make(chan string, 2)
	for _, op := range []string{"a", "b"} {
		group.Add(1)
		go func(id string) {
			defer group.Done()
			record := initial
			record.Data = task("task", id).Data
			w := push(t, h, token, domain.Mutation{OperationID: id, Record: record})
			if w.Code != 200 {
				results <- "error"
				return
			}
			var body struct {
				Results []domain.Result `json:"results"`
			}
			json.Unmarshal(w.Body.Bytes(), &body)
			results <- body.Results[0].Status
		}(op)
	}
	group.Wait()
	close(results)
	counts := map[string]int{}
	for r := range results {
		counts[r]++
	}
	if counts["applied"] != 1 || counts["conflict"] != 1 {
		t.Fatal(counts)
	}
	records, _, e := s.Changes(context.Background(), 0, 10)
	if e != nil || len(records) != 2 {
		t.Fatal(records, e)
	}
}

func TestAttachmentValidation(t *testing.T) {
	_, h, token := setup(t)
	r := httptest.NewRequest("PUT", "/api/v1/attachments/"+strings.Repeat("0", 64), strings.NewReader("not the expected hash"))
	authorizeTestRequest(t, h, r, token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w = request(t, h, "GET", "/api/v1/attachments/not-a-hash", token, nil); w.Code != 400 {
		t.Fatal(w.Code)
	}
}

func TestClipboardAttachmentRoundTrip(t *testing.T) {
	_, h, token := setup(t)
	for _, content := range [][]byte{[]byte("config: true\n"), {0, 255, 4, 128, 0}, {}} {
		hash := sha256.Sum256(content)
		path := "/api/v1/attachments/" + hex.EncodeToString(hash[:])
		r := httptest.NewRequest("PUT", path, bytes.NewReader(content))
		authorizeTestRequest(t, h, r, token)
		r.Header.Set("Content-Type", "application/octet-stream")
		r.Header.Set("X-File-Name", "clipboard.custom")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusCreated {
			t.Fatalf("upload: %d %s", w.Code, w.Body.String())
		}
		w = request(t, h, "GET", path, token, nil)
		if w.Code != http.StatusOK || !bytes.Equal(w.Body.Bytes(), content) {
			t.Fatalf("download: %d %x", w.Code, w.Body.Bytes())
		}
	}
}
