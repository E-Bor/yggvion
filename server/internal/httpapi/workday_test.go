package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestWorkdayUsesAuthenticatedEncryptedSync(t *testing.T) {
	_, h, token := setupEmpty(t)
	key := strings.Repeat("a", 64)
	if w := request(t, h, "POST", "/api/v1/encryption", token, map[string]any{
		"key_id": key, "password_config": testPasswordConfig(key, 1),
	}); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	body := map[string]any{"mutations": []any{map[string]any{
		"operation_id": "workday-op",
		"record": map[string]any{
			"id": "workday-2026-10-19", "kind": "workday",
			"data": map[string]any{
				"e2ee": 1, "key_id": key,
				"nonce": base64.StdEncoding.EncodeToString(make([]byte, 12)),
				"box":   base64.StdEncoding.EncodeToString(make([]byte, 32)),
				"files": []string{},
			},
		},
	}}}
	if w := request(t, h, "POST", "/api/v1/sync", "", body); w.Code != 401 {
		t.Fatal("unauthenticated workday", w.Code)
	}
	if w := request(t, h, "POST", "/api/v1/sync", token, body); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	snapshot := request(t, h, "GET", "/api/v1/snapshot", token, nil)
	var result struct {
		Records []struct {
			Kind string `json:"kind"`
			Data struct {
				Encrypted int `json:"e2ee"`
			} `json:"data"`
		} `json:"records"`
	}
	if snapshot.Code != 200 || json.Unmarshal(snapshot.Body.Bytes(), &result) != nil {
		t.Fatal(snapshot.Code, snapshot.Body)
	}
	found := false
	for _, record := range result.Records {
		if record.Kind == "workday" && record.Data.Encrypted == 1 {
			found = true
		}
	}
	if !found {
		t.Fatal("encrypted workday missing from snapshot", snapshot.Body)
	}
	plaintext := map[string]any{"mutations": []any{map[string]any{
		"operation_id": "plaintext-workday",
		"record":       map[string]any{"id": "workday-2026-10-20", "kind": "workday", "data": map[string]string{"start": "09:00"}},
	}}}
	if w := request(t, h, "POST", "/api/v1/sync", token, plaintext); w.Code != 400 {
		t.Fatal("plaintext workday accepted", w.Code)
	}
}
