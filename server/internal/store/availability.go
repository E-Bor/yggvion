package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

type Availability struct {
	Timezone  string           `json:"timezone"`
	Busy      []BusyInterval   `json:"busy"`
	Cursor    *int64           `json:"cursor,omitempty"`
	Proposals []ProposalUpdate `json:"proposals,omitempty"`
}

func validateAvailability(v Availability, share CalendarShare) error {
	if v.Timezone != share.Timezone || v.Busy == nil || len(v.Busy) > 10000 || len(v.Proposals) > 10 || (len(v.Proposals) > 0 && v.Cursor == nil) || (v.Cursor != nil && *v.Cursor < 0) {
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
	rows, err := s.DB.QueryContext(ctx, "SELECT c.id,c.expires,c.start,c.end,c.timezone,(SELECT json_group_array(task_id) FROM calendar_proposals WHERE share_id=c.id) FROM calendar_shares c JOIN devices d ON d.id=c.issuer AND d.revoked=0 WHERE c.expires>?", now.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []CalendarShare{}
	for rows.Next() {
		var v CalendarShare
		var expires int64
		var start, end, proposals string
		if err = rows.Scan(&v.ID, &expires, &start, &end, &v.Timezone, &proposals); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(proposals), &v.ProposalIDs); err != nil {
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

func (s *Store) UpdateAvailability(ctx context.Context, id string, v Availability, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var start, end, zone string
	err = tx.QueryRowContext(ctx, "SELECT start,end,timezone FROM calendar_shares c JOIN devices d ON d.id=c.issuer AND d.revoked=0 WHERE c.id=? AND c.expires>?", id, now.Unix()).Scan(&start, &end, &zone)
	if err == sql.ErrNoRows {
		return false, ErrShareUnavailable
	}
	if err != nil {
		return false, err
	}
	a, err := time.Parse(time.RFC3339, start)
	if err != nil {
		return false, err
	}
	b, err := time.Parse(time.RFC3339, end)
	if err != nil {
		return false, err
	}
	share := CalendarShare{ID: id, Start: a, End: b, Timezone: zone}
	if err = validateAvailability(v, share); err != nil {
		return false, err
	}
	if v.Cursor != nil {
		var current int64
		if err = tx.QueryRowContext(ctx, "SELECT COALESCE(MAX(seq),0) FROM records").Scan(&current); err != nil {
			return false, err
		}
		// A stale/offline device must not revert a newer confirmation or availability.
		if *v.Cursor != current {
			return false, nil
		}
	}
	if err = updateProposalStatuses(ctx, tx, share, v.Proposals); err != nil {
		return false, err
	}
	data, err := json.Marshal(v.Busy)
	if err != nil {
		return false, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO calendar_availability VALUES(?,?)", id, string(data)); err != nil {
		return false, err
	}
	return true, tx.Commit()
}
