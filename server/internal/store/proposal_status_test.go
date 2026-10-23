package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"yggvion/server/internal/domain"
)

func TestSchemaEightPreservesLinksAndBackfillsProposalIntervals(t *testing.T) {
	path := filepath.Join(t.TempDir(), "existing.db")
	s, device, key := historyFixture(t, path)
	ctx := context.Background()
	now := time.Date(2026, 10, 23, 8, 0, 0, 0, time.UTC)
	share, token, err := s.CreateCalendarShare(ctx, device, 7, now, Availability{Timezone: "UTC", Busy: []BusyInterval{}})
	if err != nil {
		t.Fatal(err)
	}
	p := GuestProposal{Nonce: "waiting", Title: "Guest text", Start: now.Add(time.Hour), End: now.Add(2 * time.Hour)}
	if err = s.ProposeEvent(ctx, token, p, now); err != nil {
		t.Fatal(err)
	}
	p.Nonce = "already-received"
	p.Start = p.Start.Add(3 * time.Hour)
	p.End = p.End.Add(3 * time.Hour)
	if err = s.ProposeEvent(ctx, token, p, now); err != nil {
		t.Fatal(err)
	}
	var id string
	if err = s.DB.QueryRow("SELECT task_id FROM calendar_proposals WHERE nonce=?", p.Nonce).Scan(&id); err != nil {
		t.Fatal(err)
	}
	results, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "receive-before-upgrade", Record: sealedRecord(id, "task", key)}})
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{"ALTER TABLE calendar_proposals DROP COLUMN start", "ALTER TABLE calendar_proposals DROP COLUMN end", "ALTER TABLE calendar_proposals DROP COLUMN status", "PRAGMA user_version=8"} {
		if _, err = s.DB.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	_, busy, proposals, err := s.PublicCalendar(ctx, token, now)
	if err != nil || len(busy) != 1 || len(proposals) != 1 || proposals[0].Nonce != "waiting" {
		t.Fatal(busy, proposals, err)
	}
	// An already encrypted proposal is backfilled by the owner without decrypting on the VPS.
	cursor := results[0].Record.Seq
	updated, err := s.UpdateAvailability(ctx, share.ID, Availability{Timezone: "UTC", Busy: []BusyInterval{}, Cursor: &cursor,
		Proposals: []ProposalUpdate{{TaskID: id, Version: 1, Start: p.Start, End: p.End, Status: "pending"}}}, now)
	if err != nil || !updated {
		t.Fatal(updated, err)
	}
	_, busy, proposals, err = s.PublicCalendar(ctx, token, now)
	if err != nil || len(busy) != 2 || len(proposals) != 2 {
		t.Fatal(busy, proposals, err)
	}
}
