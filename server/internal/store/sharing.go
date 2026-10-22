package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"yggvion/server/internal/domain"
)

var ErrShareUnavailable = errors.New("share unavailable")
var ErrShareLimit = errors.New("share limit reached")
var ErrTimeBusy = errors.New("time is busy")

type CalendarShare struct {
	ID       string    `json:"id"`
	Expires  time.Time `json:"expires"`
	Start    time.Time `json:"start"`
	End      time.Time `json:"end"`
	Timezone string    `json:"timezone"`
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

func (s *Store) CreateCalendarShare(ctx context.Context, issuer string, days int, now time.Time) (CalendarShare, string, error) {
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
	zone := "UTC"
	settings, err := read(ctx, tx, "settings")
	if err == nil {
		var value domain.Settings
		if err = json.Unmarshal(settings.Data, &value); err != nil {
			return CalendarShare{}, "", err
		}
		zone = value.Timezone
	} else if !errors.Is(err, sql.ErrNoRows) {
		return CalendarShare{}, "", err
	}
	location, err := time.LoadLocation(zone)
	if err != nil {
		return CalendarShare{}, "", err
	}
	local := now.In(location)
	start := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, location)
	share := CalendarShare{ID: RandomSecret(), Expires: now.UTC().Add(time.Hour), Start: start.UTC(), End: start.AddDate(0, 0, days).UTC(), Timezone: zone}
	token := RandomSecret()
	_, err = tx.ExecContext(ctx, "INSERT INTO calendar_shares VALUES(?,?,?,?,?,?,?)", share.ID, hash(token), issuer, share.Expires.Unix(), share.Start.Format(time.RFC3339), share.End.Format(time.RFC3339), zone)
	if err != nil {
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
	// Select only timestamps: identifiers, titles, descriptions and projects never
	// enter the public response. Merge overlaps to hide the number of meetings.
	rows, err := tx.QueryContext(ctx, `SELECT json_extract(b.data,'$.start'),json_extract(b.data,'$.end')
 FROM records b JOIN records t ON t.id=json_extract(b.data,'$.task_id')
 WHERE b.kind='block' AND b.deleted=0 AND t.kind='task' AND t.deleted=0
 AND COALESCE(json_extract(b.data,'$.historical'),0)=0
 AND COALESCE(json_extract(t.data,'$.birthday_date'),'')=''
 AND julianday(json_extract(b.data,'$.end'))>julianday(?)
 AND julianday(json_extract(b.data,'$.start'))<julianday(?) LIMIT 10001`, share.Start.Format(time.RFC3339), share.End.Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	intervals := make([]BusyInterval, 0)
	for rows.Next() {
		var start, end string
		if err = rows.Scan(&start, &end); err != nil {
			return nil, err
		}
		a, err := time.Parse(time.RFC3339Nano, start)
		if err != nil {
			return nil, err
		}
		b, err := time.Parse(time.RFC3339Nano, end)
		if err != nil {
			return nil, err
		}
		if a.Before(share.Start) {
			a = share.Start
		}
		if b.After(share.End) {
			b = share.End
		}
		intervals = append(intervals, BusyInterval{a, b})
		if len(intervals) > 10000 {
			return nil, ErrShareLimit
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(intervals, func(i, j int) bool { return intervals[i].Start.Before(intervals[j].Start) })
	merged := make([]BusyInterval, 0, len(intervals))
	for _, interval := range intervals {
		if len(merged) == 0 || interval.Start.After(merged[len(merged)-1].End) {
			merged = append(merged, interval)
		} else if interval.End.After(merged[len(merged)-1].End) {
			merged[len(merged)-1].End = interval.End
		}
	}
	return merged, nil
}

func (s *Store) PublicCalendar(ctx context.Context, token string, now time.Time) (CalendarShare, []BusyInterval, error) {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return CalendarShare{}, nil, err
	}
	defer tx.Rollback()
	share, err := readCalendarShare(ctx, tx, token, now)
	if err != nil {
		return share, nil, err
	}
	busy, err := calendarBusy(ctx, tx, share)
	return share, busy, err
}

func (s *Store) RevokeCalendarShare(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.DB.ExecContext(ctx, "DELETE FROM calendar_shares WHERE id=?", id)
	return err
}

func (s *Store) ProposeEvent(ctx context.Context, token string, input GuestProposal, now time.Time) error {
	input.Title = strings.TrimSpace(input.Title)
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
	for _, interval := range busy {
		if input.Start.Before(interval.End) && input.End.After(interval.Start) {
			return ErrTimeBusy
		}
	}
	// Proposals are ordinary synchronized tasks with metadata, without a block.
	// Only an authenticated owner can schedule them through the normal sync API.
	id := RandomSecret()
	data, err := json.Marshal(domain.Task{Title: input.Title, Description: input.Description, Status: "todo", Proposal: &domain.Proposal{Pending: true, Start: input.Start.UTC(), End: input.End.UTC(), Timezone: share.Timezone}})
	if err != nil {
		return err
	}
	record := domain.Record{ID: id, Kind: "task", Data: data}
	if err = domain.Validate(record); err != nil {
		return err
	}
	if _, err = save(ctx, tx, record); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO calendar_proposals VALUES(?,?,?,?)", share.ID, input.Nonce, fingerprint, id); err != nil {
		return err
	}
	return tx.Commit()
}
