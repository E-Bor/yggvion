package domain

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	_ "time/tzdata"
)

type Record struct {
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`
	Version int64           `json:"version"`
	Deleted bool            `json:"deleted"`
	Data    json.RawMessage `json:"data"`
	Seq     int64           `json:"seq"`
}

type Mutation struct {
	OperationID string `json:"operation_id"`
	Record      Record `json:"record"`
}

type Result struct {
	OperationID string `json:"operation_id"`
	Status      string `json:"status"`
	Record      Record `json:"record"`
}

type Task struct {
	BirthdayDate string `json:"birthday_date,omitempty"`
	BirthdayYear int    `json:"birthday_year,omitempty"`
	Title        string `json:"title"`
	Description  string `json:"description"`
	ProjectID    string `json:"project_id"`
	Status       string `json:"status"`
	ParentID     string `json:"parent_id"`
	SeriesID     string `json:"series_id"`
	Occurrence   string `json:"occurrence"`
}

type Block struct {
	ReminderAt []time.Time `json:"reminder_at,omitempty"`
	TaskID     string      `json:"task_id"`
	Start      time.Time   `json:"start"`
	End        time.Time   `json:"end"`
	Timezone   string      `json:"timezone"`
	AllDay     bool        `json:"all_day"`
	Historical bool        `json:"historical"`
	Reminders  []int       `json:"reminders"`
}

type Session struct {
	TaskID    string     `json:"task_id"`
	DeviceID  string     `json:"device_id"`
	Start     time.Time  `json:"start"`
	End       *time.Time `json:"end"`
	Discarded bool       `json:"discarded"`
}

type Note struct {
	Title   string `json:"title"`
	Content string `json:"content"`
	Pinned  string `json:"pinned"`
}

type Project struct {
	Title string `json:"title"`
	Color int64  `json:"color"`
}
type Settings struct {
	DefaultMinutes int    `json:"default_minutes"`
	Reminders      []int  `json:"reminders"`
	Timezone       string `json:"timezone"`
	// Keep the legacy JSON key for compatibility with existing clients.
	AccentColor *int64 `json:"task_color,omitempty"`
}
type Series struct {
	BirthdayDate   string    `json:"birthday_date,omitempty"`
	CancelledFrom  string    `json:"cancelled_from,omitempty"`
	Title          string    `json:"title"`
	Description    string    `json:"description"`
	ProjectID      string    `json:"project_id"`
	Start          time.Time `json:"start"`
	Minutes        int       `json:"minutes"`
	Timezone       string    `json:"timezone"`
	AnchorTimezone string    `json:"anchor_timezone,omitempty"`
	OffsetMinutes  int       `json:"offset_minutes,omitempty"`
	DaySpan        int       `json:"day_span,omitempty"`
	Rule           string    `json:"rule"`
	Reminders      []int     `json:"reminders"`
	AllDay         bool      `json:"all_day"`
	Exceptions     []string  `json:"exceptions"`
}
type Snooze struct {
	TaskID string    `json:"task_id"`
	At     time.Time `json:"at"`
}

var identifier = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,160}$`)

func ValidID(id string) bool { return identifier.MatchString(id) }
func title(s string) bool    { return strings.TrimSpace(s) != "" && len(s) <= 1000 }
func zone(s string) bool     { _, e := time.LoadLocation(s); return e == nil && s != "" }
func optionalInstant(value string) bool {
	if value == "" {
		return true
	}
	_, err := time.Parse(time.RFC3339Nano, value)
	return err == nil
}

func reminders(values []int) bool {
	if len(values) > 12 {
		return false
	}
	for _, v := range values {
		if v < 0 || v > 525600 {
			return false
		}
	}
	return true
}

func birthdayDate(value string) bool {
	if value == "" {
		return true
	}
	date, err := time.Parse(time.DateOnly, value)
	return err == nil && date.Year() >= 1800
}

func reminderTimes(values []time.Time) bool {
	if len(values) > 12 {
		return false
	}
	for _, at := range values {
		if at.IsZero() {
			return false
		}
	}
	return true
}

func Validate(r Record) error {
	if !ValidID(r.ID) || r.Version < 0 || len(r.Data) > 2*1024*1024 {
		return errors.New("invalid record")
	}
	var valid bool
	switch r.Kind {
	case "task":
		var t Task
		if err := json.Unmarshal(r.Data, &t); err != nil {
			return errors.New("invalid task")
		}
		valid = title(t.Title) && (t.Status == "todo" || t.Status == "in_progress" || t.Status == "waiting" || t.Status == "done") && (t.ProjectID == "" || ValidID(t.ProjectID)) && (t.ParentID == "" || ValidID(t.ParentID)) && (t.SeriesID == "" || ValidID(t.SeriesID))
		valid = valid && birthdayDate(t.BirthdayDate)
		if t.BirthdayDate != "" {
			birth, _ := time.Parse(time.DateOnly, t.BirthdayDate)
			valid = valid && t.SeriesID != "" && t.ProjectID == "" && t.BirthdayYear >= birth.Year() && t.BirthdayYear <= 9999 && t.Occurrence != "" && optionalInstant(t.Occurrence)
		}
	case "block":
		var b Block
		if err := json.Unmarshal(r.Data, &b); err != nil {
			return errors.New("invalid block")
		}
		valid = ValidID(b.TaskID) && !b.Start.IsZero() && b.End.After(b.Start) && b.End.Sub(b.Start) <= 366*24*time.Hour && zone(b.Timezone) && reminders(b.Reminders)
		valid = valid && reminderTimes(b.ReminderAt)
	case "session":
		var s Session
		if err := json.Unmarshal(r.Data, &s); err != nil {
			return errors.New("invalid session")
		}
		valid = ValidID(s.TaskID) && ValidID(s.DeviceID) && !s.Start.IsZero() && (s.End == nil || s.End.After(s.Start))
	case "note":
		var n Note
		if err := json.Unmarshal(r.Data, &n); err != nil {
			return errors.New("invalid note")
		}
		valid = title(n.Title) && (n.Pinned == "" || n.Pinned == "scratchpad" || n.Pinned == "reference")
		if n.Pinned != "" {
			valid = valid && r.ID == n.Pinned && !r.Deleted
		}
	case "project":
		var p Project
		if err := json.Unmarshal(r.Data, &p); err != nil {
			return errors.New("invalid project")
		}
		valid = title(p.Title) && p.Color >= 0 && p.Color <= 0xffffffff
	case "settings":
		var s Settings
		if err := json.Unmarshal(r.Data, &s); err != nil {
			return errors.New("invalid settings")
		}
		valid = r.ID == "settings" && s.DefaultMinutes >= 5 && s.DefaultMinutes <= 1440 && zone(s.Timezone) && reminders(s.Reminders) && !r.Deleted
		valid = valid && (s.AccentColor == nil || *s.AccentColor >= 0xff000000 && *s.AccentColor <= 0xffffffff)
	case "series":
		var s Series
		if err := json.Unmarshal(r.Data, &s); err != nil {
			return errors.New("invalid series")
		}
		valid = optionalInstant(s.CancelledFrom) && title(s.Title) && !s.Start.IsZero() && s.Minutes >= 1 && s.Minutes <= 527040 && zone(s.Timezone) && (s.AnchorTimezone == "" || zone(s.AnchorTimezone)) && s.DaySpan >= 0 && s.DaySpan <= 366 && strings.Contains(s.Rule, "FREQ=") && len(s.Rule) <= 2000 && reminders(s.Reminders)
		valid = valid && birthdayDate(s.BirthdayDate)
		if s.BirthdayDate != "" {
			valid = valid && s.AllDay && s.ProjectID == "" && strings.Contains(s.Rule, "FREQ=YEARLY")
		}
	case "snooze":
		var s Snooze
		if err := json.Unmarshal(r.Data, &s); err != nil {
			return errors.New("invalid snooze")
		}
		valid = ValidID(s.TaskID) && !s.At.IsZero()
	default:
		return errors.New("unknown record kind")
	}
	if !valid {
		return fmt.Errorf("invalid %s fields", r.Kind)
	}
	return nil
}
