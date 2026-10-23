package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"yggvion/server/internal/domain"
)

var ErrShareUnavailable = errors.New("share unavailable")
var ErrShareLimit = errors.New("share limit reached")
var ErrTimeBusy = errors.New("time is busy")

type CalendarShare struct {
	ID          string    `json:"id"`
	Expires     time.Time `json:"expires"`
	Start       time.Time `json:"start"`
	End         time.Time `json:"end"`
	Timezone    string    `json:"timezone"`
	ProposalIDs []string  `json:"proposal_ids,omitempty"`
}

type BusyInterval struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
}

type GuestProposal struct {
	Nonce       string    `json:"nonce"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	Start       time.Time `json:"start"`
	End         time.Time `json:"end"`
}

func (s *Store) CreateCalendarShare(ctx context.Context, issuer string, days int, now time.Time, supplied Availability) (CalendarShare, string, error) {
	if days < 1 || days > 30 {
		return CalendarShare{}, "", ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return CalendarShare{}, "", err
	}
	defer tx.Rollback()
	keyID, err := encryptionKey(ctx, tx)
	if err != nil {
		return CalendarShare{}, "", err
	}
	if keyID == "" {
		return CalendarShare{}, "", ErrInvalid
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM calendar_shares WHERE expires<=?", now.Unix()); err != nil {
		return CalendarShare{}, "", err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM calendar_shares").Scan(&count); err != nil {
		return CalendarShare{}, "", err
	}
	if count >= 20 {
		return CalendarShare{}, "", ErrShareLimit
	}
	location, err := time.LoadLocation(supplied.Timezone)
	if err != nil {
		return CalendarShare{}, "", ErrInvalid
	}
	local := now.In(location)
	start := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, location)
	share := CalendarShare{ID: RandomSecret(), Expires: now.UTC().Add(time.Hour), Start: start.UTC(), End: start.AddDate(0, 0, days).UTC(), Timezone: supplied.Timezone}
	if err = validateAvailability(supplied, share); err != nil {
		return CalendarShare{}, "", err
	}
	token := RandomSecret()
	_, err = tx.ExecContext(ctx, "INSERT INTO calendar_shares VALUES(?,?,?,?,?,?,?)", share.ID, hash(token), issuer, share.Expires.Unix(), share.Start.Format(time.RFC3339), share.End.Format(time.RFC3339), share.Timezone)
	if err != nil {
		return CalendarShare{}, "", err
	}
	data, err := json.Marshal(supplied.Busy)
	if err != nil {
		return CalendarShare{}, "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO calendar_availability VALUES(?,?)", share.ID, string(data)); err != nil {
		return CalendarShare{}, "", err
	}
	return share, token, tx.Commit()
}

func readCalendarShare(ctx context.Context, tx *sql.Tx, token string, now time.Time) (CalendarShare, error) {
	var share CalendarShare
	if len(token) != 64 || strings.Trim(token, "0123456789abcdef") != "" {
		return share, ErrShareUnavailable
	}
	var expires int64
	var start, end string
	err := tx.QueryRowContext(ctx, `SELECT s.id,s.expires,s.start,s.end,s.timezone FROM calendar_shares s
 JOIN devices d ON d.id=s.issuer AND d.revoked=0 WHERE s.token_hash=? AND s.expires>?`, hash(token), now.Unix()).Scan(&share.ID, &expires, &start, &end, &share.Timezone)
	if errors.Is(err, sql.ErrNoRows) {
		return share, ErrShareUnavailable
	}
	if err != nil {
		return share, err
	}
	share.Expires = time.Unix(expires, 0).UTC()
	share.Start, err = time.Parse(time.RFC3339, start)
	if err != nil {
		return share, err
	}
	share.End, err = time.Parse(time.RFC3339, end)
	return share, err
}

func calendarBusy(ctx context.Context, tx *sql.Tx, share CalendarShare) ([]BusyInterval, error) {
	var snapshot string
	if err := tx.QueryRowContext(ctx, "SELECT busy FROM calendar_availability WHERE share_id=?", share.ID).Scan(&snapshot); err != nil {
		return nil, err
	}
	var busy []BusyInterval
	if err := json.Unmarshal([]byte(snapshot), &busy); err != nil {
		return nil, err
	}
	return busy, nil
}

func (s *Store) PublicCalendar(ctx context.Context, token string, now time.Time) (CalendarShare, []BusyInterval, []PublicProposal, error) {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return CalendarShare{}, nil, nil, err
	}
	defer tx.Rollback()
	share, err := readCalendarShare(ctx, tx, token, now)
	if err != nil {
		return share, nil, nil, err
	}
	busy, err := calendarBusy(ctx, tx, share)
	if err != nil {
		return share, nil, nil, err
	}
	proposals, held, err := proposalSlots(ctx, tx, share, now)
	return share, mergeBusy(append(busy, held...)), proposals, err
}

func (s *Store) RevokeCalendarShare(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.DB.ExecContext(ctx, "DELETE FROM calendar_shares WHERE id=?", id)
	return err
}

func (s *Store) ProposeEvent(ctx context.Context, token string, input GuestProposal, now time.Time) error {
	input.Title = strings.TrimSpace(input.Title)
	// Guest links cannot refer to private files, including inside titles or code.
	if strings.Contains(strings.ToLower(input.Title+"\n"+input.Description), "attachment:") {
		return ErrInvalid
	}
	if !domain.ValidID(input.Nonce) || input.Title == "" || utf8.RuneCountInString(input.Title) > 200 || len(input.Description) > 8000 || strings.ContainsAny(input.Title, "\r\n") || input.Start.Before(now) || !input.End.After(input.Start) || input.End.Sub(input.Start) > 24*time.Hour || input.Start.Second() != 0 || input.End.Second() != 0 || input.Start.Nanosecond() != 0 || input.End.Nanosecond() != 0 {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	share, err := readCalendarShare(ctx, tx, token, now)
	if err != nil {
		return err
	}
	if input.Start.Before(share.Start) || input.End.After(share.End) {
		return ErrInvalid
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		return err
	}
	fingerprint := hash(string(encoded))
	var previous string
	err = tx.QueryRowContext(ctx, "SELECT fingerprint FROM calendar_proposals WHERE share_id=? AND nonce=?", share.ID, input.Nonce).Scan(&previous)
	if err == nil {
		if previous != fingerprint {
			return ErrInvalid
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM calendar_proposals WHERE share_id=?", share.ID).Scan(&count); err != nil {
		return err
	}
	if count >= 10 {
		return ErrShareLimit
	}
	busy, err := calendarBusy(ctx, tx, share)
	if err != nil {
		return err
	}
	_, held, err := proposalSlots(ctx, tx, share, now)
	if err != nil {
		return err
	}
	for _, interval := range append(busy, held...) {
		if input.Start.Before(interval.End) && input.End.After(interval.Start) {
			return ErrTimeBusy
		}
	}
	// Guest input stays separate until a client validates and encrypts it.
	id := "guest_" + RandomSecret()
	data, err := json.Marshal(domain.Task{Title: input.Title, Description: input.Description, Status: "todo", Proposal: &domain.Proposal{Pending: true, Start: input.Start.UTC(), End: input.End.UTC(), Timezone: share.Timezone}})
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO guest_inbox VALUES(?,?,?)", id, string(data), now.Unix()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO calendar_proposals(share_id,nonce,fingerprint,task_id,start,end,status) VALUES(?,?,?,?,?,?,?)", share.ID, input.Nonce, fingerprint, id, input.Start.UTC().Format(time.RFC3339), input.End.UTC().Format(time.RFC3339), "pending"); err != nil {
		return err
	}
	return tx.Commit()
}
