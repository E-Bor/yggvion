package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"yggvion/server/internal/domain"
)

func testPasswordEnvelope(key string, revision int64) domain.PasswordEnvelope {
	return domain.PasswordEnvelope{
		Version: 1, KeyID: key, Revision: revision,
		KDF: "argon2id", Memory: 19456, Iterations: 2, Parallelism: 1,
		Salt:  base64.StdEncoding.EncodeToString(make([]byte, 16)),
		Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)),
		Box:   base64.StdEncoding.EncodeToString(make([]byte, 48)),
		MAC:   base64.StdEncoding.EncodeToString(make([]byte, 32)),
	}
}

func TestLegacyEncryptionAndInvitationInputsAreRejected(t *testing.T) {
	_, h, token := setupEmpty(t)
	w := request(t, h, "POST", "/api/v1/encryption", token, map[string]any{"key_id": testKeyID})
	if w.Code != 400 {
		t.Fatal("key-only initialization accepted", w.Code, w.Body)
	}
	w = request(t, h, "POST", "/api/v1/invitations", token, map[string]any{"key_envelope": "old-wrapped-key"})
	if w.Code != 400 {
		t.Fatal("legacy invitation accepted", w.Code, w.Body)
	}
	w = request(t, h, "POST", "/api/v1/invitations", token, map[string]any{})
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	var invite map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}
	paired := request(t, h, "POST", "/api/v1/pair", "", map[string]any{"name": "new", "key": invite["code"]})
	if paired.Code != 201 {
		t.Fatal(paired.Code, paired.Body)
	}
	var result map[string]any
	if err := json.Unmarshal(paired.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result) != 3 || result["protocol"] != float64(5) || result["key_envelope"] != nil {
		t.Fatal(result)
	}
}

func TestEncryptionBootstrapAndPrivateAPIBoundary(t *testing.T) {
	s, h, token := setupEmpty(t)
	generation, err := s.Generation(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, data any, encrypted string) *httptest.ResponseRecorder {
		body, _ := json.Marshal(data)
		r := httptest.NewRequest(method, path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Yggvion-Generation", generation)
		r.Header.Set("X-Yggvion-Encryption", encrypted)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	key := strings.Repeat("a", 64)
	if w := request(t, h, "POST", "/api/v1/encryption", "", map[string]any{"key_id": key, "password_envelope": testPasswordEnvelope(key, 1)}); w.Code != 401 {
		t.Fatal(w.Code)
	}
	missingBody, _ := json.Marshal(map[string]any{"key_id": key, "password_envelope": testPasswordEnvelope(key, 1)})
	missing := httptest.NewRequest("POST", "/api/v1/encryption", bytes.NewReader(missingBody))
	missing.Header.Set("Authorization", "Bearer "+token)
	missingResult := httptest.NewRecorder()
	h.ServeHTTP(missingResult, missing)
	if missingResult.Code != 409 {
		t.Fatal("missing generation", missingResult.Code)
	}

	if w := call("POST", "/api/v1/encryption", map[string]any{"key_id": key, "password_envelope": testPasswordEnvelope(key, 1)}, ""); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", "/api/v1/encryption", map[string]any{"key_id": strings.Repeat("b", 64), "password_envelope": testPasswordEnvelope(strings.Repeat("b", 64), 1)}, ""); w.Code != 409 {
		t.Fatal("replaced key", w.Code)
	}
	w := request(t, h, "POST", "/api/v1/sync", token, map[string]any{"mutations": []any{map[string]any{
		"operation_id": "op", "record": map[string]any{"id": "secret", "kind": "note", "data": map[string]string{"title": "private", "content": "private"}},
	}}})
	if w.Code != 400 {
		t.Fatal("plaintext record", w.Code, w.Body)
	}
	box := base64.StdEncoding.EncodeToString(make([]byte, 32))
	w = call("POST", "/api/v1/sync", map[string]any{"mutations": []any{map[string]any{
		"operation_id": "encrypted-op", "record": map[string]any{"id": "note1", "kind": "note", "data": map[string]any{
			"e2ee": 1, "key_id": key, "nonce": base64.StdEncoding.EncodeToString(make([]byte, 12)), "box": box, "files": []string{},
		}},
	}}}, "")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	state := request(t, h, "GET", "/api/v1/state", token, nil)
	if !strings.Contains(state.Body.String(), key) || strings.Contains(state.Body.String(), "yggkey1:") {
		t.Fatal(state.Body)
	}

	ciphertext := []byte("opaque test ciphertext")
	sum := sha256.Sum256(ciphertext)
	id := hex.EncodeToString(sum[:])
	for _, marker := range []string{"", strings.Repeat("b", 64), key} {
		r := httptest.NewRequest("PUT", "/api/v1/attachments/"+id, bytes.NewReader(ciphertext))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Yggvion-Encryption", marker)
		r.Header.Set("X-Yggvion-Generation", generation)
		r.Header.Set("X-File-Name", "PRIVATE_FILENAME.txt")
		response := httptest.NewRecorder()
		h.ServeHTTP(response, r)
		if marker != key && response.Code != 400 {
			t.Fatal("unmarked upload", response.Code)
		}
		if marker == key && response.Code != 201 {
			t.Fatal(response.Code, response.Body)
		}
	}
	var name string
	if err = s.DB.QueryRow("SELECT name FROM attachments WHERE id=?", id).Scan(&name); err != nil || name != "encrypted" {
		t.Fatal(name, err)
	}
}

func TestPasswordAPIRequiresAuthenticationAndCurrentRevision(t *testing.T) {
	s, h, token := setupEmpty(t)
	key := strings.Repeat("d", 64)
	if err := s.EnableEncryption(context.Background(), key, testPasswordEnvelope(key, 1)); err != nil {
		t.Fatal(err)
	}
	generation, _ := s.Generation(context.Background())
	next := testPasswordEnvelope(key, 2)
	input := map[string]any{"key_id": key, "expected_revision": 1, "password_envelope": next}
	for _, methodPath := range [][2]string{{"GET", "/api/v1/state"}, {"PUT", "/api/v1/encryption/password"}} {
		if w := request(t, h, methodPath[0], methodPath[1], "", input); w.Code != 401 {
			t.Fatal("unauthenticated", methodPath, w.Code)
		}
	}
	call := func(data any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(data)
		r := httptest.NewRequest("PUT", "/api/v1/encryption/password", bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Yggvion-Generation", generation)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	missingBody, _ := json.Marshal(input)
	missing := httptest.NewRequest("PUT", "/api/v1/encryption/password", bytes.NewReader(missingBody))
	missing.Header.Set("Authorization", "Bearer "+token)
	missingResult := httptest.NewRecorder()
	h.ServeHTTP(missingResult, missing)
	if missingResult.Code != 409 {
		t.Fatal("missing generation", missingResult.Code)
	}

	for i := 0; i < 2; i++ {
		if w := call(input); w.Code != 200 {
			t.Fatal("rotation/retry", w.Code, w.Body)
		}
	}
	input["password_envelope"] = testPasswordEnvelope(key, 3)
	if w := call(input); w.Code != 400 {
		t.Fatal("invalid revision increment", w.Code)
	}
	different := next
	different.Salt = base64.StdEncoding.EncodeToString([]byte("different-salt!!"))
	input["password_envelope"] = different
	if w := call(input); w.Code != 409 {
		t.Fatal("lost update", w.Code, w.Body)
	}
	state := request(t, h, "GET", "/api/v1/state", token, nil)
	var got struct {
		Protocol int
		Envelope domain.PasswordEnvelope `json:"password_envelope"`
	}
	if err := json.Unmarshal(state.Body.Bytes(), &got); err != nil || got.Protocol != 5 || got.Envelope != next {
		t.Fatal("state password envelope", state.Body, err)
	}
}
