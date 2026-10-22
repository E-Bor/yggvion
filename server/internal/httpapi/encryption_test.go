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

func testPasswordConfig(key string, _ int64) domain.PasswordConfig {
	return domain.PasswordConfig{Version: 2, KeyID: key, KDF: "argon2id", Memory: 19456, Iterations: 2, Parallelism: 1, Salt: base64.StdEncoding.EncodeToString(make([]byte, 16))}
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
	if len(result) != 3 || result["protocol"] != float64(6) || result["key_envelope"] != nil {
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
	if w := request(t, h, "POST", "/api/v1/encryption", "", map[string]any{"key_id": key, "password_config": testPasswordConfig(key, 1)}); w.Code != 401 {
		t.Fatal(w.Code)
	}
	missingBody, _ := json.Marshal(map[string]any{"key_id": key, "password_config": testPasswordConfig(key, 1)})
	missing := httptest.NewRequest("POST", "/api/v1/encryption", bytes.NewReader(missingBody))
	missing.Header.Set("Authorization", "Bearer "+token)
	missingResult := httptest.NewRecorder()
	h.ServeHTTP(missingResult, missing)
	if missingResult.Code != 409 {
		t.Fatal("missing generation", missingResult.Code)
	}

	if w := call("POST", "/api/v1/encryption", map[string]any{"key_id": key, "password_config": testPasswordConfig(key, 1)}, ""); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", "/api/v1/encryption", map[string]any{"key_id": strings.Repeat("b", 64), "password_config": testPasswordConfig(strings.Repeat("b", 64), 1)}, ""); w.Code != 409 {
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

func TestPasswordAPIRequiresAuthenticationAndCurrentSnapshot(t *testing.T) {
	s, h, token := setupEmpty(t)
	key := strings.Repeat("d", 64)
	if err := s.EnableEncryption(context.Background(), key, testPasswordConfig(key, 1)); err != nil {
		t.Fatal(err)
	}
	generation, _ := s.Generation(context.Background())
	next := testPasswordConfig(strings.Repeat("e", 64), 1)
	input := map[string]any{"key_id": key, "cursor": 0, "records": []domain.Record{}, "password_config": next}
	for _, methodPath := range [][2]string{{"GET", "/api/v1/state"}, {"GET", "/api/v1/snapshot"}, {"PUT", "/api/v1/encryption/password"}} {
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

	for _, field := range []string{"cursor", "records"} {
		incomplete := map[string]any{}
		for key, value := range input {
			if key != field {
				incomplete[key] = value
			}
		}
		if w := call(incomplete); w.Code != 400 {
			t.Fatal("missing required field", field, w.Code)
		}
	}
	invalid := next
	invalid.Memory = 999999999
	input["password_config"] = invalid
	if w := call(input); w.Code != 400 {
		t.Fatal("invalid KDF", w.Code)
	}
	input["password_config"] = next
	input["cursor"] = 1
	if w := call(input); w.Code != 409 {
		t.Fatal("stale cursor", w.Code)
	}
	input["cursor"] = 0
	if w := call(input); w.Code != 200 {
		t.Fatal("rotation", w.Code, w.Body)
	}
	if w := call(input); w.Code != 409 {
		t.Fatal("stale retry", w.Code, w.Body)
	}
	state := request(t, h, "GET", "/api/v1/state", token, nil)
	var got struct {
		Protocol int
		Envelope domain.PasswordConfig `json:"password_config"`
	}
	if err := json.Unmarshal(state.Body.Bytes(), &got); err != nil || got.Protocol != 6 || got.Envelope != next {
		t.Fatal("state password envelope", state.Body, err)
	}
}
