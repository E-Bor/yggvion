package domain

import (
	"encoding/json"
	"regexp"
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
	Proposal     *Proposal `json:"proposal,omitempty"`
	BirthdayDate string    `json:"birthday_date,omitempty"`
	BirthdayYear int       `json:"birthday_year,omitempty"`
	Title        string    `json:"title"`
	Description  string    `json:"description"`
	ProjectID    string    `json:"project_id"`
	Status       string    `json:"status"`
	ParentID     string    `json:"parent_id"`
	SeriesID     string    `json:"series_id"`
	Occurrence   string    `json:"occurrence"`
}

// Proposal is a guest suggestion, not a calendar reservation.
type Proposal struct {
	Pending  bool      `json:"pending"`
	Start    time.Time `json:"start"`
	End      time.Time `json:"end"`
	Timezone string    `json:"timezone"`
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

type Snooze struct {
	TaskID string    `json:"task_id"`
	At     time.Time `json:"at"`
}

var identifier = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,160}$`)

func ValidID(id string) bool { return identifier.MatchString(id) }
