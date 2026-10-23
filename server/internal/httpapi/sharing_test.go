package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

type shareFixture struct {
	api           *API
	owner, device string
	now           time.Time
	availability  store.Availability
}

func newShareFixture(t *testing.T) *shareFixture {
	t.Helper()
	s, _, owner := setup(t)
	var device string
	err := s.DB.QueryRow("SELECT id FROM devices").Scan(&device)
	if err != nil {
		t.Fatal(err)
	}
	f := &shareFixture{owner: owner, device: device, now: time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)}
	f.availability = store.Availability{Timezone: "UTC", Busy: []store.BusyInterval{}}
	f.api = New(s, "", t.TempDir())
	f.api.PublicURL = "https://calendar.example.test:8443"
	f.api.ShareClock = func() time.Time { return f.now }
	return f
}

func (f *shareFixture) call(method, path, token string, body any) *httptest.ResponseRecorder {
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+token)
	if token == f.owner {
		generation, err := f.api.Store.Generation(context.Background())
		if err != nil {
			panic(err)
		}
		r.Header.Set("X-Yggvion-Generation", generation)
	}
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func (f *shareFixture) share(t *testing.T) (string, string) {
	t.Helper()
	w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]any{"days": 7, "snapshot": f.availability})
	if w.Code != 201 {
		t.Fatalf("create share: %d %s", w.Code, w.Body)
	}
	var value struct {
		ID, URL string
		Expires time.Time
	}
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	address, err := url.Parse(value.URL)
	if err != nil || address.Scheme != "https" || address.Path != "/share" || address.RawQuery != "" || len(address.Fragment) != 64 {
		t.Fatalf("invalid invitation: %+v %v", address, err)
	}
	if value.Expires.Sub(f.now) != time.Hour {
		t.Fatal("unexpected lifetime", value.Expires)
	}
	return value.ID, address.Fragment
}

func (f *shareFixture) propose(nonce string) store.GuestProposal {
	return store.GuestProposal{Nonce: nonce, Title: "Meeting", Description: "Guest description", Start: f.now.Add(24 * time.Hour), End: f.now.Add(25 * time.Hour)}
}

func TestPublicCalendarPrivacyAndProposalLifecycle(t *testing.T) {
	f := newShareFixture(t)
	// Availability is a client-supplied anonymous snapshot, never inferred from ciphertext.
	f.availability.Busy = []store.BusyInterval{{Start: f.now.Add(time.Hour), End: f.now.Add(150 * time.Minute)}}
	for i := range 2 {
		w := push(t, f.api.Handler(), f.owner, domain.Mutation{OperationID: fmt.Sprintf("private-op-%d", i), Record: task(fmt.Sprintf("private-task-%d", i), "SECRET TITLE")})
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
	}
	id, token := f.share(t)
	var stored string
	if err := f.api.Store.DB.QueryRow("SELECT token_hash FROM calendar_shares WHERE id=?", id).Scan(&stored); err != nil || stored == token {
		t.Fatal("token stored in plaintext", err)
	}
	w := f.call("GET", "/public/calendar", token, nil)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	var response map[string]json.RawMessage
	json.Unmarshal(w.Body.Bytes(), &response)
	if len(response) != 7 {
		t.Fatal("unexpected public fields", response)
	}
	var busy []map[string]time.Time
	json.Unmarshal(response["busy"], &busy)
	if len(busy) != 1 || len(busy[0]) != 2 || !busy[0]["start"].Equal(f.now.Add(time.Hour)) || !busy[0]["end"].Equal(f.now.Add(150*time.Minute)) {
		t.Fatal(busy)
	}
	for _, secret := range []string{"SECRET", "private-task", "private-block", id, token, "description", "project"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("private data exposed", secret)
		}
	}
	proposal := f.propose("unique-submission")
	proposal.Title = "<script>alert(1)</script> '; DROP TABLE records;--"
	proposal.Description = "[untrusted link](javascript:alert(1))"
	for range 2 { // Retrying the same request must not duplicate a task.
		w = f.call("POST", "/public/proposals", token, proposal)
		if w.Code != 201 {
			t.Fatal(w.Code, w.Body)
		}
	}
	inbox, err := f.api.Store.GuestProposals(context.Background())
	if err != nil || len(inbox) != 1 {
		t.Fatal("duplicate or lost proposal", len(inbox), err)
	}
	var guest domain.Task
	if err = json.Unmarshal(inbox[0].Data, &guest); err != nil || guest.Title != proposal.Title || guest.Proposal == nil || !guest.Proposal.Pending || !guest.Proposal.Start.Equal(proposal.Start) {
		t.Fatal(guest, err)
	}
	snapshot, err := f.api.Store.Export(context.Background())
	if err != nil || len(snapshot.Records) != 2 {
		t.Fatal("guest input entered private snapshot", err)
	}
	adopted := encryptedRecord(inbox[0].ID, "task", "encrypted guest")
	if w = push(t, f.api.Handler(), f.owner, domain.Mutation{OperationID: "adopt", Record: adopted}); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	inbox, err = f.api.Store.GuestProposals(context.Background())
	if err != nil || len(inbox) != 0 {
		t.Fatal("guest not acknowledged", err)
	}
	w = f.call("GET", "/public/calendar", token, nil)
	json.Unmarshal(w.Body.Bytes(), &response)
	json.Unmarshal(response["busy"], &busy)
	if len(busy) != 2 {
		t.Fatal("pending proposal did not reserve its interval")
	}
	proposal.Title = "Changed after a retry"
	if w = f.call("POST", "/public/proposals", token, proposal); w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
}

func TestCalendarShareExpiryRevocationAndAuthentication(t *testing.T) {
	for _, reason := range []string{"expired", "revoked", "device revoked", "restored"} {
		t.Run(reason, func(t *testing.T) {
			f := newShareFixture(t)
			id, token := f.share(t)
			if w := f.call("POST", "/api/v1/calendar-shares", token, map[string]any{"days": 7, "snapshot": f.availability}); w.Code != 401 {
				t.Fatal("guest gained owner access", w.Code)
			}
			if w := f.call("GET", "/public/calendar", strings.Repeat("0", 64), nil); w.Code != 404 {
				t.Fatal(w.Code)
			}
			switch reason {
			case "expired":
				f.now = f.now.Add(time.Hour)
			case "revoked":
				if w := f.call("DELETE", "/api/v1/calendar-shares/"+id, f.owner, nil); w.Code != 200 {
					t.Fatal(w.Code)
				}
			case "device revoked":
				if _, err := f.api.Store.DB.Exec("UPDATE devices SET revoked=1 WHERE id=?", f.device); err != nil {
					t.Fatal(err)
				}
			case "restored":
				snapshot, err := f.api.Store.Export(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				if err = f.api.Store.Restore(context.Background(), snapshot); err != nil {
					t.Fatal(err)
				}
			}
			for _, method := range []string{"GET", "POST"} {
				path := "/public/calendar"
				var body any
				if method == "POST" {
					path = "/public/proposals"
					body = f.propose("late")
				}
				if w := f.call(method, path, token, body); w.Code != 404 || !strings.Contains(w.Body.String(), "share_unavailable") {
					t.Fatal(w.Code, w.Body)
				}
			}
		})
	}
}

func TestPublicProposalValidationAndQuota(t *testing.T) {
	f := newShareFixture(t)
	_, token := f.share(t)
	for _, kind := range []string{"past", "outside", "long", "empty", "multiline", "huge", "invalid nonce"} {
		p := f.propose("invalid")
		switch kind {
		case "past":
			p.Start = f.now.Add(-time.Minute)
		case "outside":
			p.Start = f.now.Add(9 * 24 * time.Hour)
			p.End = p.Start.Add(time.Hour)
		case "long":
			p.End = p.Start.Add(25 * time.Hour)
		case "empty":
			p.Title = "   "
		case "multiline":
			p.Title = "one\ntwo"
		case "huge":
			p.Description = strings.Repeat("a", 17000)
		case "invalid nonce":
			p.Nonce = "'; DELETE FROM records;--"
		}
		if w := f.call("POST", "/public/proposals", token, p); w.Code != 400 {
			t.Fatal(kind, w.Code, w.Body)
		}
	}
	// Competing requests cannot bypass the per-invitation quota.
	var wg sync.WaitGroup
	codes := make(chan int, 15)
	for i := range 15 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p := f.propose(fmt.Sprintf("proposal-%d", i))
			p.Start = p.Start.Add(time.Duration(i) * 2 * time.Hour)
			p.End = p.Start.Add(time.Hour)
			codes <- f.call("POST", "/public/proposals", token, p).Code
		}()
	}
	wg.Wait()
	close(codes)
	accepted, limited := 0, 0
	for code := range codes {
		switch code {
		case 201:
			accepted++
		case 429:
			limited++
		default:
			t.Fatal(code)
		}
	}
	if accepted != 10 || limited != 5 {
		t.Fatal(accepted, limited)
	}
}

func TestPublicSurfaceHeadersOriginLimitsAndPrivateRoutes(t *testing.T) {
	f := newShareFixture(t)
	_, token := f.share(t)
	public := f.api.PublicHandler()
	for _, path := range []string{"/share", "/share/calendar.css", "/share/calendar.js", "/public/calendar"} {
		w := request(t, public, "GET", path, token, nil)
		if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
			t.Fatal(path, w.Code, w.Header())
		}
	}
	for _, path := range []string{"/api/v1/sync", "/api/v1/pair", "/api/v1/backups", "/api/v1/devices", "/api/v1/calendar-shares"} {
		if w := request(t, public, "POST", path, f.owner, nil); w.Code != 404 {
			t.Fatal("private route exposed", path, w.Code)
		}
	}
	r := httptest.NewRequest("GET", "/public/calendar", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	public.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
	for range 60 {
		f.call("GET", "/public/calendar", token, nil)
	}
	w = f.call("GET", "/public/calendar", token, nil)
	if w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatal("missing rate limit", w.Code)
	}
	f.now = f.now.Add(time.Minute)
	if w = f.call("GET", "/public/calendar", token, nil); w.Code != 200 {
		t.Fatal("rate limit did not recover", w.Code)
	}
}

func TestPublicProposalsRejectOccupiedAndUnexpectedInput(t *testing.T) {
	f := newShareFixture(t)
	id, token := f.share(t)
	proposal := f.propose("occupied")
	f.availability.Busy = []store.BusyInterval{{Start: proposal.Start, End: proposal.End}}
	w := f.call("PUT", "/api/v1/calendar-shares/"+id+"/availability", f.owner, f.availability)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w = f.call("POST", "/public/proposals", token, proposal); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	encoded, _ := json.Marshal(f.propose("extra-field"))
	var input map[string]any
	json.Unmarshal(encoded, &input)
	input["project_id"] = "private-project"
	if w = f.call("POST", "/public/proposals", token, input); w.Code != 400 {
		t.Fatal("unexpected field accepted", w.Code)
	}
	if w = request(t, f.api.PublicHandler(), "POST", "/public/proposals", token, proposal); w.Code != 400 {
		t.Fatal("missing JSON content type accepted", w.Code)
	}
}

func TestShareWindowFollowsOwnerTimezoneAcrossDaylightSaving(t *testing.T) {
	f := newShareFixture(t)
	f.now = time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)
	f.availability.Timezone = "Europe/Berlin"
	w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]any{"days": 2, "snapshot": f.availability})
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	var share store.CalendarShare
	if err := json.Unmarshal(w.Body.Bytes(), &share); err != nil {
		t.Fatal(err)
	}
	if share.Timezone != "Europe/Berlin" || share.End.Sub(share.Start) != 49*time.Hour {
		t.Fatal(share)
	}
}

func TestSharingRequiresHTTPSAndBoundedRange(t *testing.T) {
	f := newShareFixture(t)
	for _, base := range []string{"", "http://example.test", "https://user:secret@example.test", "https://example.test/path", "https://example.test?token=x"} {
		f.api.PublicURL = base
		if w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]any{"days": 7, "snapshot": f.availability}); w.Code != 503 {
			t.Fatal(base, w.Code)
		}
	}
	for _, days := range []int{0, -1, 31} {
		if w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]int{"days": days}); w.Code != 400 {
			t.Fatal(days, w.Code)
		}
	}
}
