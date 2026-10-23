package store

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"yggvion/server/internal/domain"
)

func sealedRecord(id, kind, key string) domain.Record {
	data, _ := json.Marshal(domain.Envelope{E2EE: 1, KeyID: key, Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)), Box: base64.StdEncoding.EncodeToString(make([]byte, 32)), Files: []string{}})
	return domain.Record{ID: id, Kind: kind, Data: data}
}

func TestEncryptedWorkspaceAndRestore(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	device, _, err := s.Pair(ctx, "test")
	if err != nil {
		t.Fatal(err)
	}
	key := strings.Repeat("a", 64)
	if err = s.EnableEncryption(ctx, key, passwordFixture(key, 1)); err != nil {
		t.Fatal(err)
	}
	if err = s.EnableEncryption(ctx, key, passwordFixture(key, 1)); err != nil {
		t.Fatal("retry", err)
	}
	if err = s.EnableEncryption(ctx, strings.Repeat("b", 64), passwordFixture(strings.Repeat("b", 64), 1)); err != ErrConflict {
		t.Fatal("key replacement", err)
	}
	plain := domain.Record{ID: "note1", Kind: "note", Data: json.RawMessage(`{"title":"secret","content":"private"}`)}
	if _, err = s.Apply(ctx, device, []domain.Mutation{{OperationID: "plaintext", Record: plain}}); err == nil {
		t.Fatal("plaintext accepted")
	}
	wrong := sealedRecord("note1", "note", strings.Repeat("b", 64))
	if _, err = s.Apply(ctx, device, []domain.Mutation{{OperationID: "wrongkey", Record: wrong}}); err == nil {
		t.Fatal("wrong key accepted")
	}
	record := sealedRecord("note1", "note", key)
	result, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "op1", Record: record}})
	if err != nil {
		t.Fatal(err)
	}
	retry, err := s.Apply(ctx, device, []domain.Mutation{{OperationID: "op1", Record: record}})
	if err != nil || result[0].Record.Version != retry[0].Record.Version {
		t.Fatal("retry", err)
	}
	snapshot, err := s.Export(ctx)
	if err != nil || snapshot.EncryptionKeyID != key {
		t.Fatal(snapshot, err)
	}
	if err = s.Restore(ctx, snapshot); err != nil {
		t.Fatal(err)
	}
	current, _ := s.EncryptionKey(ctx)
	if current != key {
		t.Fatal("lost key fingerprint")
	}
	if err = s.Restore(ctx, Snapshot{Format: 1, Created: time.Now(), Records: []domain.Record{plain}}); err == nil {
		t.Fatal("plaintext downgrade")
	}
}

func TestEncryptedCalendarUsesOnlyPublishedAvailability(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	device, _, _ := s.Pair(ctx, "owner")
	key := strings.Repeat("c", 64)
	if err = s.EnableEncryption(ctx, key, passwordFixture(key, 1)); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 22, 8, 0, 0, 0, time.UTC)
	start := now.Add(time.Hour)
	end := start.Add(time.Hour)
	_, token, err := s.CreateCalendarShare(ctx, device, 7, now, Availability{Timezone: "UTC", Busy: []BusyInterval{{start, end}}})
	if err != nil {
		t.Fatal(err)
	}
	_, busy, _, err := s.PublicCalendar(ctx, token, now)
	if err != nil || len(busy) != 1 {
		t.Fatal(busy, err)
	}
	input := GuestProposal{Nonce: "guest1", Title: "External proposal", Start: end.Add(time.Hour), End: end.Add(2 * time.Hour)}
	if err = s.ProposeEvent(ctx, token, input, now); err != nil {
		t.Fatal(err)
	}
	inbox, err := s.GuestProposals(ctx)
	if err != nil || len(inbox) != 1 {
		t.Fatal(inbox, err)
	}
	snapshot, _ := s.Export(ctx)
	if len(snapshot.Records) != 0 {
		t.Fatal("guest plaintext leaked to personal records")
	}
	adopted := sealedRecord(inbox[0].ID, "task", key)
	if _, err = s.Apply(ctx, device, []domain.Mutation{{OperationID: "adopt", Record: adopted}}); err != nil {
		t.Fatal(err)
	}
	inbox, _ = s.GuestProposals(ctx)
	if len(inbox) != 0 {
		t.Fatal("guest plaintext not removed after receipt")
	}
	if _, _, _, err = s.PublicCalendar(ctx, token, now.Add(time.Hour)); err != ErrShareUnavailable {
		t.Fatal("expired link", err)
	}
}
