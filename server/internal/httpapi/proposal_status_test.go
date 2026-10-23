package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func TestProposalReservationIsAtomicAcrossLinks(t *testing.T) {
	f := newShareFixture(t)
	_, a := f.share(t)
	_, b := f.share(t)
	var wg sync.WaitGroup
	codes := make(chan int, 12)
	for i := range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			token := a
			if i%2 == 1 {
				token = b
			}
			codes <- f.call("POST", "/public/proposals", token, f.propose(fmt.Sprintf("race-%d", i))).Code
		}()
	}
	wg.Wait()
	close(codes)
	accepted, conflicts := 0, 0
	for code := range codes {
		if code == 201 {
			accepted++
		} else if code == 409 {
			conflicts++
		} else {
			t.Fatal(code)
		}
	}
	if accepted != 1 || conflicts != 11 {
		t.Fatal(accepted, conflicts)
	}
	for _, token := range []string{a, b} {
		w := f.call("GET", "/public/calendar", token, nil)
		var body struct {
			Busy      []store.BusyInterval
			Proposals []store.PublicProposal
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || len(body.Busy) != 1 {
			t.Fatal(w.Code, w.Body)
		}
		if len(body.Proposals) > 1 {
			t.Fatal("foreign proposals exposed")
		}
	}
}

func TestProposalStatusesArePrivateToLinkAndRejectStaleUpdates(t *testing.T) {
	f := newShareFixture(t)
	id, token := f.share(t)
	otherID, other := f.share(t)
	p := f.propose("receipt-one")
	for range 2 {
		if w := f.call("POST", "/public/proposals", token, p); w.Code != 201 {
			t.Fatal(w.Code, w.Body)
		}
	}
	inbox, err := f.api.Store.GuestProposals(context.Background())
	if err != nil || len(inbox) != 1 {
		t.Fatal(err, len(inbox))
	}
	taskID := inbox[0].ID
	read := func(auth string) []store.PublicProposal {
		t.Helper()
		w := f.call("GET", "/public/calendar", auth, nil)
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
		for _, secret := range []string{taskID, id, otherID, "Guest description", "Meeting", "title", "task_id", "version", "proposal_ids"} {
			if strings.Contains(w.Body.String(), secret) {
				t.Fatal("private field leaked", secret, w.Body)
			}
		}
		var body struct{ Proposals []store.PublicProposal }
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body.Proposals
	}
	if own := read(token); len(own) != 1 || own[0].Status != "pending" || own[0].Nonce != p.Nonce {
		t.Fatal(own)
	}
	if len(read(other)) != 0 {
		t.Fatal("another link sees proposal metadata")
	}
	adopted := encryptedRecord(taskID, "task", "private edited description")
	if w := push(t, f.api.Handler(), f.owner, domain.Mutation{OperationID: "adopt-status", Record: adopted}); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	var cursor int64
	f.api.Store.DB.QueryRow("SELECT MAX(seq) FROM records").Scan(&cursor)
	updates := store.Availability{Timezone: "UTC", Busy: []store.BusyInterval{{Start: p.Start, End: p.End}}, Cursor: &cursor, Proposals: []store.ProposalUpdate{{TaskID: taskID, Version: 1, Start: p.Start, End: p.End, Status: "accepted"}}}
	path := "/api/v1/calendar-shares/" + id + "/availability"
	// A share token never authorizes owner operations, even with known identifiers.
	if w := f.call("PUT", path, token, updates); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	if w := f.call("PUT", "/api/v1/calendar-shares/"+otherID+"/availability", f.owner, updates); w.Code != 400 {
		t.Fatal("cross-link update accepted", w.Code, w.Body)
	}
	if w := f.call("PUT", path, f.owner, updates); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if own := read(token); own[0].Status != "accepted" {
		t.Fatal(own)
	}
	stale := cursor - 1
	updates.Cursor = &stale
	updates.Proposals[0].Status = "pending"
	w := f.call("PUT", path, f.owner, updates)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"updated":false`) {
		t.Fatal(w.Code, w.Body)
	}
	if own := read(token); own[0].Status != "accepted" {
		t.Fatal("stale client reverted decision", own)
	}
	updates.Cursor = &cursor
	updates.Proposals[0].Status = "rescheduled"
	updates.Busy = []store.BusyInterval{{Start: p.End.Add(time.Hour), End: p.End.Add(2 * time.Hour)}}
	if w = f.call("PUT", path, f.owner, updates); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if own := read(token); own[0].Status != "rescheduled" || !own[0].Start.Equal(p.Start) || !own[0].End.Equal(p.End) {
		t.Fatal("replacement time linked to guest", own)
	}
	// Altering a receipt's interval or introducing an unknown status is rejected atomically.
	updates.Proposals[0].Start = p.Start.Add(time.Minute)
	if w = f.call("PUT", path, f.owner, updates); w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
	updates.Proposals[0].Start = p.Start
	updates.Proposals[0].Status = "<script>alert(1)</script>"
	if w = f.call("PUT", path, f.owner, updates); w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
	updates.Proposals[0].Status = "declined"
	if w = f.call("PUT", path, f.owner, updates); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if own := read(token); own[0].Status != "declined" {
		t.Fatal(own)
	}
	p.Nonce = "now-free"
	if w = f.call("POST", "/public/proposals", other, p); w.Code != 201 {
		t.Fatal("released interval still blocked", w.Code, w.Body)
	}
	if len(read(token)) != 1 || len(read(other)) != 1 {
		t.Fatal("cross-link receipts exposed")
	}
	f.now = f.now.Add(time.Hour)
	if w = f.call("GET", "/public/calendar", token, nil); w.Code != 404 {
		t.Fatal("expired receipt remains public", w.Code)
	}
}

func TestSharePageCopyAndStatusMarkup(t *testing.T) {
	f := newShareFixture(t)
	w := f.call("GET", "/share", "", nil)
	for _, removed := range []string{"ВРЕМЯ ДЛЯ ВАЖНОГО", "Найдём время", "Детали чужих", "Только занятость. Ничего личного."} {
		if strings.Contains(w.Body.String(), removed) {
			t.Fatal("retired copy remains", removed)
		}
	}
	if !strings.Contains(w.Body.String(), "Согласуем время") || !strings.Contains(w.Body.String(), `id="proposal-list"`) {
		t.Fatal(w.Body)
	}
}
