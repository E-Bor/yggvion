package httpapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http/httptest"
	"strings"
	"testing"

	"yggvion/server/internal/domain"
)

func withAttachment(t *testing.T, record domain.Record, id string) domain.Record {
	t.Helper()
	var envelope domain.Envelope
	if err := json.Unmarshal(record.Data, &envelope); err != nil {
		t.Fatal(err)
	}
	envelope.Files = []string{id}
	record.Data, _ = json.Marshal(envelope)
	return record
}

func TestAttachmentCleanupProtectsReferencesAndSync(t *testing.T) {
	_, h, token := setup(t)
	content := []byte("opaque encrypted test attachment")
	sum := sha256.Sum256(content)
	id := hex.EncodeToString(sum[:])
	path := "/api/v1/attachments/" + id
	upload := httptest.NewRequest("PUT", path, bytes.NewReader(content))
	authorizeTestRequest(t, h, upload, token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, upload)
	if w.Code != 201 {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	catalog := withAttachment(t, encryptedRecord("catalog-one", "attachment", "metadata"), id)
	note := withAttachment(t, encryptedRecord("note-one", "note", "private text"), id)
	results := decodeResults(t, push(t, h, token,
		domain.Mutation{OperationID: "catalog-create", Record: catalog},
		domain.Mutation{OperationID: "note-create", Record: note}))
	catalog, note = results[0].Record, results[1].Record
	tombstone := encryptedRecord(catalog.ID, "attachment", "deleted catalog")
	tombstone.Version, tombstone.Deleted = catalog.Version, true
	body := map[string]any{"record": tombstone}
	if w = request(t, h, "DELETE", path, "", body); w.Code != 401 {
		t.Fatalf("anonymous delete: %d", w.Code)
	}
	if w = request(t, h, "POST", "/api/v1/attachments/present", "", map[string]any{"ids": []string{id}}); w.Code != 401 {
		t.Fatalf("anonymous inventory: %d", w.Code)
	}
	if w = request(t, h, "DELETE", path, token, body); w.Code != 409 || !strings.Contains(w.Body.String(), "attachment_in_use") {
		t.Fatalf("referenced delete: %d %s", w.Code, w.Body.String())
	}
	if w = request(t, h, "GET", path, token, nil); w.Code != 200 {
		t.Fatalf("lost protected file: %d", w.Code)
	}

	// A deleted note must not keep its files alive forever.
	note.Deleted = true
	note = decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "note-delete", Record: note}))[0].Record
	stale := tombstone
	stale.Version = 0
	if w = request(t, h, "DELETE", path, token, map[string]any{"record": stale}); w.Code != 409 {
		t.Fatalf("stale catalog: %d", w.Code)
	}
	wrongKind := tombstone
	wrongKind.Kind = "note"
	if w = request(t, h, "DELETE", path, token, map[string]any{"record": wrongKind}); w.Code != 400 {
		t.Fatalf("invalid kind: %d", w.Code)
	}
	if w = request(t, h, "DELETE", "/api/v1/attachments/"+strings.Repeat("b", 64), token, body); w.Code != 400 {
		t.Fatalf("wrong file: %d", w.Code)
	}

	staleGeneration := httptest.NewRequest("DELETE", path, bytes.NewReader(mustJSON(t, body)))
	authorizeTestRequest(t, h, staleGeneration, token)
	staleGeneration.Header.Set("X-Yggvion-Generation", "old-generation")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, staleGeneration)
	if w.Code != 409 {
		t.Fatalf("generation: %d %s", w.Code, w.Body.String())
	}

	if w = request(t, h, "DELETE", path, token, body); w.Code != 200 {
		t.Fatalf("delete: %d %s", w.Code, w.Body.String())
	}
	var deleted struct {
		Record domain.Record `json:"record"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &deleted); err != nil {
		t.Fatal(err)
	}
	if !deleted.Record.Deleted || deleted.Record.Version != catalog.Version+1 {
		t.Fatalf("missing catalog tombstone: %+v", deleted.Record)
	}
	if w = request(t, h, "GET", path, token, nil); w.Code != 404 {
		t.Fatalf("file retained: %d", w.Code)
	}
	if w = request(t, h, "DELETE", path, token, body); w.Code != 200 {
		t.Fatalf("retry: %d %s", w.Code, w.Body.String())
	}
	present := request(t, h, "POST", "/api/v1/attachments/present", token, map[string]any{"ids": []string{id}})
	if present.Code != 200 || !strings.Contains(present.Body.String(), `"ids":[]`) {
		t.Fatalf("presence: %d %s", present.Code, present.Body.String())
	}
	// A stale/offline writer cannot publish a dangling reference. It must
	// re-upload the encrypted bytes before retrying with the new envelope.
	note.Deleted = false
	if w = push(t, h, token, domain.Mutation{OperationID: "offline-note", Record: note}); w.Code != 400 {
		t.Fatalf("dangling reference accepted: %d %s", w.Code, w.Body.String())
	}
	if w = request(t, h, "POST", "/api/v1/attachments/present", token, map[string]any{"ids": []string{"../bad"}}); w.Code != 400 {
		t.Fatalf("invalid inventory: %d", w.Code)
	}
	tooMany := make([]string, 1001)
	for i := range tooMany {
		tooMany[i] = id
	}
	if w = request(t, h, "POST", "/api/v1/attachments/present", token, map[string]any{"ids": tooMany}); w.Code != 400 {
		t.Fatalf("unbounded inventory: %d", w.Code)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type delayedAttachmentBody struct {
	started chan struct{}
	release chan struct{}
	source  io.Reader
}

func (b *delayedAttachmentBody) Read(p []byte) (int, error) {
	if b.started != nil {
		close(b.started)
		b.started = nil
		<-b.release
	}
	return b.source.Read(p)
}

func TestAttachmentCleanupDoesNotLockDuringBodyRead(t *testing.T) {
	s, _, token := setup(t)
	a := New(s, strings.Repeat("test", 8), t.TempDir())
	h := a.Handler()
	record := encryptedRecord("missing-catalog", "attachment", "deleted")
	record.Deleted = true
	started, release := make(chan struct{}), make(chan struct{})
	body := &delayedAttachmentBody{started: started, release: release, source: bytes.NewReader(mustJSON(t, map[string]any{"record": record}))}
	r := httptest.NewRequest("DELETE", "/api/v1/attachments/"+strings.Repeat("a", 64), body)
	authorizeTestRequest(t, h, r, token)
	done := make(chan struct{})
	go func() { h.ServeHTTP(httptest.NewRecorder(), r); close(done) }()
	<-started
	unlocked := a.DataMu.TryRLock()
	if unlocked {
		a.DataMu.RUnlock()
	}
	close(release)
	<-done
	if !unlocked {
		t.Fatal("slow body held the workspace write lock")
	}

	r = httptest.NewRequest("DELETE", "/api/v1/attachments/"+strings.Repeat("a", 64), bytes.NewReader(mustJSON(t, map[string]any{"record": record})))
	authorizeTestRequest(t, h, r, token)
	a.DataMu.RLock()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	a.DataMu.RUnlock()
	if w.Code != 409 || !strings.Contains(w.Body.String(), "server_busy") {
		t.Fatalf("busy cleanup: %d %s", w.Code, w.Body.String())
	}
}
