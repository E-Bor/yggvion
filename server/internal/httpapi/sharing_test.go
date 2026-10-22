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
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func (f *shareFixture) share(t *testing.T) (string, string) {
	t.Helper()
	w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]int{"days": 7})
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
	// Two overlapping private blocks must appear as one anonymous interval.
	for i, minutes := range []int{60, 90} {
		taskID := fmt.Sprintf("private-task-%d", i)
		block := domain.Block{TaskID: taskID, Start: f.now.Add(time.Duration(minutes) * time.Minute), End: f.now.Add(time.Duration(minutes+60) * time.Minute), Timezone: "UTC", Reminders: []int{0}}
		payload, _ := json.Marshal(block)
		w := push(t, f.api.Handler(), f.owner, domain.Mutation{OperationID: fmt.Sprintf("task-op-%d", i), Record: task(taskID, "SECRET TITLE")}, domain.Mutation{OperationID: fmt.Sprintf("block-op-%d", i), Record: domain.Record{ID: fmt.Sprintf("private-block-%d", i), Kind: "block", Data: payload}})
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
	if len(response) != 6 {
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
	snapshot, err := f.api.Store.Export(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, record := range snapshot.Records {
		if record.Kind != "task" {
			continue
		}
		var task domain.Task
		json.Unmarshal(record.Data, &task)
		if task.Proposal == nil {
			continue
		}
		count++
		if task.Title != proposal.Title || task.Status != "todo" || !task.Proposal.Pending || !task.Proposal.Start.Equal(proposal.Start) {
			t.Fatal(task)
		}
		if err = domain.Validate(record); err != nil {
			t.Fatal("invalid synchronized proposal", err)
		}
		// Once accepted, the owner may turn the event into a recurring task.
		task.SeriesID = "owner-created-series"
		record.Data, _ = json.Marshal(task)
		if domain.Validate(record) == nil {
			t.Fatal("pending recurring proposal accepted")
		}
		task.Proposal.Pending = false
		record.Data, _ = json.Marshal(task)
		if err = domain.Validate(record); err != nil {
			t.Fatal("accepted task cannot be edited", err)
		}
	}
	if count != 1 {
		t.Fatal("duplicate or lost proposal", count)
	}
	w = f.call("GET", "/public/calendar", token, nil)
	json.Unmarshal(w.Body.Bytes(), &response)
	json.Unmarshal(response["busy"], &busy)
	if len(busy) != 1 {
		t.Fatal("pending proposal occupies the calendar")
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
			if w := f.call("POST", "/api/v1/calendar-shares", token, map[string]int{"days": 7}); w.Code != 401 {
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
			codes <- f.call("POST", "/public/proposals", token, f.propose(fmt.Sprintf("proposal-%d", i))).Code
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
	_, token := f.share(t)
	proposal := f.propose("occupied")
	block := domain.Block{TaskID: "occupied-task", Start: proposal.Start, End: proposal.End, Timezone: "UTC", Reminders: []int{}}
	data, _ := json.Marshal(block)
	w := push(t, f.api.Handler(), f.owner,
		domain.Mutation{OperationID: "busy-task", Record: task("occupied-task", "Private")},
		domain.Mutation{OperationID: "busy-block", Record: domain.Record{ID: "busy", Kind: "block", Data: data}})
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
	settings := domain.Record{ID: "settings", Kind: "settings", Data: json.RawMessage(`{"timezone":"Europe/Berlin","default_minutes":30,"reminders":[]}`)}
	if w := push(t, f.api.Handler(), f.owner, domain.Mutation{OperationID: "settings-zone", Record: settings}); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]int{"days": 2})
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
		if w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]int{"days": 7}); w.Code != 503 {
			t.Fatal(base, w.Code)
		}
	}
	for _, days := range []int{0, -1, 31} {
		if w := f.call("POST", "/api/v1/calendar-shares", f.owner, map[string]int{"days": days}); w.Code != 400 {
			t.Fatal(days, w.Code)
		}
	}
}
