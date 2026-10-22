package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

type Availability struct {
	Timezone string         `json:"timezone"`
	Busy     []BusyInterval `json:"busy"`
}

func validateAvailability(v Availability, share CalendarShare) error {
	if v.Timezone != share.Timezone || v.Busy == nil || len(v.Busy) > 10000 {
		return ErrInvalid
	}
	var previous time.Time
	for _, b := range v.Busy {
		if b.Start.Before(share.Start) || b.End.After(share.End) || !b.End.After(b.Start) || (!previous.IsZero() && !b.Start.After(previous)) {
			return ErrInvalid
		}
		previous = b.End
	}
	return nil
}

func (s *Store) ActiveCalendarShares(ctx context.Context, now time.Time) ([]CalendarShare, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT c.id,c.expires,c.start,c.end,c.timezone FROM calendar_shares c JOIN devices d ON d.id=c.issuer AND d.revoked=0 WHERE c.expires>?", now.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []CalendarShare{}
	for rows.Next() {
		var v CalendarShare
		var expires int64
		var start, end string
		if err = rows.Scan(&v.ID, &expires, &start, &end, &v.Timezone); err != nil {
			return nil, err
		}
		v.Expires = time.Unix(expires, 0).UTC()
		v.Start, err = time.Parse(time.RFC3339, start)
		if err != nil {
			return nil, err
		}
		v.End, err = time.Parse(time.RFC3339, end)
		if err != nil {
			return nil, err
		}
		result = append(result, v)
	}
	return result, rows.Err()
}

func (s *Store) UpdateAvailability(ctx context.Context, id string, v Availability, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var start, end, zone string
	err = tx.QueryRowContext(ctx, "SELECT start,end,timezone FROM calendar_shares c JOIN devices d ON d.id=c.issuer AND d.revoked=0 WHERE c.id=? AND c.expires>?", id, now.Unix()).Scan(&start, &end, &zone)
	if err == sql.ErrNoRows {
		return ErrShareUnavailable
	}
	if err != nil {
		return err
	}
	a, err := time.Parse(time.RFC3339, start)
	if err != nil {
		return err
	}
	b, err := time.Parse(time.RFC3339, end)
	if err != nil {
		return err
	}
	if err = validateAvailability(v, CalendarShare{Start: a, End: b, Timezone: zone}); err != nil {
		return err
	}
	data, err := json.Marshal(v.Busy)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO calendar_availability VALUES(?,?)", id, string(data))
	if err != nil {
		return err
	}
	return tx.Commit()
}
