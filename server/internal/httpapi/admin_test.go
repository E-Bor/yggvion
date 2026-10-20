package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"yggvion/server/internal/backup"
	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func TestInvitationSingleUseExpiryAndRevocation(t *testing.T) {
	s, h, token := setup(t)
	ctx := context.Background()
	issuer, err := s.Authorize(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	if w := request(t, h, "POST", "/api/v1/invitations", "", nil); w.Code != 401 {
		t.Fatal("unprotected invitations")
	}
	w := request(t, h, "POST", "/api/v1/invitations", token, nil)
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body.String())
	}
	var invite map[string]string
	if err = json.Unmarshal(w.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for range 2 {
		wg.Go(func() {
			body, _ := json.Marshal(map[string]string{"name": "phone", "key": invite["code"]})
			r := httptest.NewRequest("POST", "/api/v1/pair", bytes.NewReader(body))
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			codes <- w.Code
		})
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[201] != 1 || counts[401] != 1 {
		t.Fatal("invitation reused", counts)
	}
	code, err := s.Invite(ctx, issuer)
	if err != nil {
		t.Fatal(err)
	}
	s.DB.Exec("UPDATE invitations SET expires=?", time.Now().Add(-time.Minute).Unix())
	if w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "phone", "key": code}); w.Code != 401 {
		t.Fatal("expired code accepted")
	}
	code, err = s.Invite(ctx, issuer)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Revoke(ctx, issuer); err != nil {
		t.Fatal(err)
	}
	if w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "phone", "key": code}); w.Code != 401 {
		t.Fatal("revoked issuer accepted")
	}
}
func TestRestoreRejectsStaleClientsAndPreservesRevocations(t *testing.T) {
	s, _, token := setup(t)
	a := New(s, strings.Repeat("test", 8), t.TempDir())
	m, err := backup.Open(s, filepath.Join(t.TempDir(), "backups"), a.Files, &a.DataMu)
	if err != nil {
		t.Fatal(err)
	}
	a.Backups = m
	h := a.Handler()
	ctx := context.Background()
	device, _ := s.Authorize(ctx, token)
	revoked, revokedToken, _ := s.Pair(ctx, "revoked")
	results := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "initial", Record: task("one", "before")}))
	oldGeneration, _, _ := s.Generation(ctx)
	entry, err := m.Create(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Revoke(ctx, revoked); err != nil {
		t.Fatal(err)
	}
	changed := results[0].Record
	changed.Data = task("one", "after").Data
	decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "changed", Record: changed}))
	path, _ := m.Path(entry.ID)
	if err = m.Restore(ctx, path, ""); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Authorize(ctx, revokedToken); err == nil {
		t.Fatal("revoked token restored")
	}
	if got, err := s.Authorize(ctx, token); err != nil || got != device {
		t.Fatal("active device lost")
	}
	for _, generation := range []string{"", oldGeneration} {
		body, _ := json.Marshal(map[string]any{"mutations": []domain.Mutation{{OperationID: store.RandomSecret(), Record: task("late", "must not appear")}}})
		r := httptest.NewRequest("POST", "/api/v1/sync", bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Yggvion-Generation", generation)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 409 || !strings.Contains(w.Body.String(), "generation_changed") {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if w := request(t, h, "GET", "/api/v1/state", token, nil); w.Code != 200 {
		t.Fatal(w.Code)
	}
	for _, path := range []string{"/api/v1/state", "/api/v1/backups", "/api/v1/backups/recovery-key", "/api/v1/backups/remote"} {
		if w := request(t, h, "GET", path, "", nil); w.Code != http.StatusUnauthorized {
			t.Fatal("unprotected", path)
		}
	}
}
