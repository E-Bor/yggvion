package httpapi

import (
	"encoding/json"
	"testing"
	"time"
	"yggvion/server/internal/domain"
)

func birthdayRecords(t *testing.T) []domain.Record {
	t.Helper()
	start := time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC)
	values := []struct {
		id, kind string
		data     any
	}{
		{"birthday", "series", domain.Series{Title: "Анна", BirthdayDate: "1990-03-31", Start: start, Minutes: 1440, Timezone: "UTC", Rule: "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=31", AllDay: true, DaySpan: 1}},
		{"birthday_2026", "task", domain.Task{Title: "Анна — день рождения · 36 лет", Status: "todo", BirthdayDate: "1990-03-31", BirthdayYear: 2026, SeriesID: "birthday", Occurrence: start.Format(time.RFC3339)}},
		{"birthday_block", "block", domain.Block{TaskID: "birthday_2026", Start: start, End: start.Add(24 * time.Hour), Timezone: "UTC", AllDay: true, ReminderAt: []time.Time{
			start.Add(9 * time.Hour),
		}}},
	}
	records := make([]domain.Record, 0, len(values))
	for _, value := range values {
		raw, err := json.Marshal(value.data)
		if err != nil {
			t.Fatal(err)
		}
		records = append(records, domain.Record{ID: value.id, Kind: value.kind, Data: raw})
	}
	return records
}

func TestBirthdayContractRoundTripAndDeletion(t *testing.T) {
	_, handler, token := setup(t)
	records := birthdayRecords(t)
	results := decodeResults(t, push(t, handler, token,
		domain.Mutation{OperationID: "create-person", Record: records[0]},
		domain.Mutation{OperationID: "create-year", Record: records[1]},
		domain.Mutation{OperationID: "create-plan", Record: records[2]}))
	if len(results) != 3 {
		t.Fatal(results)
	}
	response := request(t, handler, "GET", "/api/v1/changes?after=0", token, nil)
	if response.Code != 200 {
		t.Fatal(response.Body.String())
	}
	var changes struct {
		Records []domain.Record `json:"records"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &changes); err != nil {
		t.Fatal(err)
	}
	if len(changes.Records) != 3 {
		t.Fatal(changes)
	}
	var task domain.Task
	if err := json.Unmarshal(changes.Records[1].Data, &task); err != nil {
		t.Fatal(err)
	}
	if task.BirthdayDate != "1990-03-31" || task.BirthdayYear != 2026 {
		t.Fatal(task)
	}
	var block domain.Block
	if err := json.Unmarshal(changes.Records[2].Data, &block); err != nil {
		t.Fatal(err)
	}
	if len(block.ReminderAt) != 1 || !block.ReminderAt[0].Equal(block.Start.Add(9*time.Hour)) {
		t.Fatal(block)
	}
	deleted := results[0].Record
	deleted.Deleted = true
	decodeResults(t, push(t, handler, token, domain.Mutation{OperationID: "delete-person", Record: deleted}))
	response = request(t, handler, "GET", "/api/v1/changes?after=3", token, nil)
	if err := json.Unmarshal(response.Body.Bytes(), &changes); err != nil {
		t.Fatal(err)
	}
	if len(changes.Records) != 3 {
		t.Fatal(response.Body.String())
	}
	for _, record := range changes.Records {
		if !record.Deleted {
			t.Fatal("birthday descendants survived deletion", record.ID)
		}
	}
}

func TestBirthdayContractRejectsInvalidFields(t *testing.T) {
	cases := []struct {
		name  string
		index int
		field string
		value any
	}{
		{"invalid birth date", 0, "birthday_date", "1990-02-30"},
		{"birthday must be all day", 0, "all_day", false},
		{"invalid task birth date", 1, "birthday_date", "yesterday"},
		{"year before birth", 1, "birthday_year", 1980},
		{"missing year", 1, "birthday_year", 0},
		{"invalid reminder time", 2, "reminder_at", []string{"not-a-date"}},
		{"zero reminder time", 2, "reminder_at", []string{"0001-01-01T00:00:00Z"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, handler, token := setup(t)
			record := birthdayRecords(t)[tc.index]
			var data map[string]any
			if err := json.Unmarshal(record.Data, &data); err != nil {
				t.Fatal(err)
			}
			data[tc.field] = tc.value
			record.Data, _ = json.Marshal(data)
			response := push(t, handler, token, domain.Mutation{OperationID: "invalid", Record: record})
			if response.Code != 400 {
				t.Fatal(response.Code, response.Body.String())
			}
		})
	}
}
