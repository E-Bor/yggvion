package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"yggvion/server/internal/domain"
)

func TestNoteFoldersAndNotesStayOpaque(t *testing.T) {
	s, h, token := setup(t)
	folder := encryptedRecord("folder", "note_folder", "Work folder")
	note := encryptedRecord("note", "note", "Title [other](note:target)")
	results := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "f", Record: folder}, domain.Mutation{OperationID: "n", Record: note}))
	if len(results) != 2 {
		t.Fatal(results)
	}
	var content string
	if err := s.DB.QueryRow("SELECT data FROM records WHERE id='note'").Scan(&content); err != nil {
		t.Fatal(err)
	}
	if content != string(note.Data) || strings.Contains(content, "Title") {
		t.Fatal("altered/leaked note")
	}
}
func TestMetricsAreAuthenticatedAndLazy(t *testing.T) {
	s, _, token := setup(t)
	dir := t.TempDir()
	a := New(s, "", filepath.Join(dir, "attachments"))
	a.Metrics.ProcDir = dir
	h := a.Handler()
	// No /proc files: constructing the API did not try to sample anything.
	if w := request(t, h, "GET", "/api/v1/metrics", "", nil); w.Code != 401 {
		t.Fatal(w.Code)
	}
	os.Mkdir(filepath.Join(dir, "self"), 0700)
	os.WriteFile(filepath.Join(dir, "stat"), []byte("cpu 1 0 0 10\n"), 0600)
	os.WriteFile(filepath.Join(dir, "meminfo"), []byte("MemTotal: 1024 kB\nMemAvailable: 512 kB\n"), 0600)
	os.WriteFile(filepath.Join(dir, "self/status"), []byte("VmRSS: 20 kB\n"), 0600)
	w := request(t, h, "GET", "/api/v1/metrics", token, nil)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var data map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if data["memory_used_bytes"] != float64(512*1024) {
		t.Fatal(data)
	}
	os.Remove(filepath.Join(dir, "stat"))
	r := httptest.NewRequest("GET", "/api/v1/metrics", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	cached := httptest.NewRecorder()
	h.ServeHTTP(cached, r)
	if cached.Code != 200 || cached.Body.String() != w.Body.String() {
		t.Fatal("metrics not cached")
	}
}
