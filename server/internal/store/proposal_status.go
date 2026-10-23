package store

import (
	"context"
	"database/sql"
	"sort"
	"time"
)

// Only the original guest interval and its disposition are public. In particular,
// an owner's replacement time, task identifier and edited text never leave here.
type PublicProposal struct {
	Nonce  string    `json:"nonce"`
	Start  time.Time `json:"start"`
	End    time.Time `json:"end"`
	Status string    `json:"status"`
}

type ProposalUpdate struct {
	TaskID  string    `json:"task_id"`
	Version int64     `json:"version"`
	Start   time.Time `json:"start"`
	End     time.Time `json:"end"`
	Status  string    `json:"status"`
}

func proposalSlots(ctx context.Context, tx *sql.Tx, share CalendarShare, now time.Time) ([]PublicProposal, []BusyInterval, error) {
	rows, err := tx.QueryContext(ctx, `SELECT p.share_id,p.nonce,p.start,p.end,p.status
 FROM calendar_proposals p JOIN calendar_shares s ON s.id=p.share_id
 JOIN devices d ON d.id=s.issuer AND d.revoked=0
 WHERE s.expires>? AND p.start<>'' ORDER BY p.start,p.nonce`, now.Unix())
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	own, held := []PublicProposal{}, []BusyInterval{}
	for rows.Next() {
		var id, start, end string
		var p PublicProposal
		if err = rows.Scan(&id, &p.Nonce, &start, &end, &p.Status); err != nil {
			return nil, nil, err
		}
		p.Start, err = time.Parse(time.RFC3339, start)
		if err != nil {
			return nil, nil, err
		}
		p.End, err = time.Parse(time.RFC3339, end)
		if err != nil {
			return nil, nil, err
		}
		if id == share.ID {
			own = append(own, p)
		}
		if (p.Status == "pending" || p.Status == "accepted") && p.Start.Before(share.End) && p.End.After(share.Start) {
			a, b := p.Start, p.End
			if a.Before(share.Start) {
				a = share.Start
			}
			if b.After(share.End) {
				b = share.End
			}
			held = append(held, BusyInterval{Start: a, End: b})
		}
	}
	return own, held, rows.Err()
}

func mergeBusy(ranges []BusyInterval) []BusyInterval {
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].Start.Before(ranges[j].Start) })
	out := []BusyInterval{}
	for _, r := range ranges {
		if len(out) == 0 || r.Start.After(out[len(out)-1].End) {
			out = append(out, r)
			continue
		}
		if r.End.After(out[len(out)-1].End) {
			out[len(out)-1].End = r.End
		}
	}
	return out
}

func updateProposalStatuses(ctx context.Context, tx *sql.Tx, share CalendarShare, updates []ProposalUpdate) error {
	seen := make(map[string]bool)
	for _, p := range updates {
		if seen[p.TaskID] || p.Version < 1 || p.Start.Before(share.Start) || p.End.After(share.End) || !p.End.After(p.Start) || p.End.Sub(p.Start) > 24*time.Hour {
			return ErrInvalid
		}
		seen[p.TaskID] = true
		switch p.Status {
		case "pending", "accepted", "declined", "rescheduled":
		default:
			return ErrInvalid
		}
		var start, end string
		var version int64
		err := tx.QueryRowContext(ctx, `SELECT p.start,p.end,r.version FROM calendar_proposals p
 JOIN records r ON r.id=p.task_id AND r.kind='task' WHERE p.share_id=? AND p.task_id=?`, share.ID, p.TaskID).Scan(&start, &end, &version)
		if err == sql.ErrNoRows {
			return ErrInvalid
		}
		if err != nil {
			return err
		}
		if version != p.Version {
			return ErrInvalid
		}
		// Existing intervals are immutable; dates only backfill pre-feature proposals.
		if start != "" {
			a, e := time.Parse(time.RFC3339, start)
			if e != nil {
				return e
			}
			b, e := time.Parse(time.RFC3339, end)
			if e != nil {
				return e
			}
			if !a.Equal(p.Start) || !b.Equal(p.End) {
				return ErrInvalid
			}
		}
		if _, err = tx.ExecContext(ctx, `UPDATE calendar_proposals SET start=?,end=?,status=? WHERE share_id=? AND task_id=?`,
			p.Start.UTC().Format(time.RFC3339), p.End.UTC().Format(time.RFC3339), p.Status, share.ID, p.TaskID); err != nil {
			return err
		}
	}
	return nil
}
