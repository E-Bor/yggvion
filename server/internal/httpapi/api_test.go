package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func setup(t *testing.T) (*store.Store, http.Handler, string) {
	t.Helper()
	s, e := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	_, token, e := s.Pair(context.Background(), "Test device")
	if e != nil {
		t.Fatal(e)
	}
	return s, New(s, strings.Repeat("test", 8), t.TempDir()).Handler(), token
}
func request(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var b []byte
	if body != nil {
		var e error
		b, e = json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func task(id, title string) domain.Record {
	return domain.Record{ID: id, Kind: "task", Data: json.RawMessage(`{"title":"` + title + `","description":"","project_id":"","status":"todo"}`)}
}
func push(t *testing.T, h http.Handler, token string, mutations ...domain.Mutation) *httptest.ResponseRecorder {
	return request(t, h, "POST", "/api/v1/sync", token, map[string]any{"mutations": mutations})
}
func decodeResults(t *testing.T, w *httptest.ResponseRecorder) []domain.Result {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var out struct {
		Results []domain.Result `json:"results"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &out); e != nil {
		t.Fatal(e)
	}
	return out.Results
}

func TestAuthAndPairing(t *testing.T) {
	s, h, token := setup(t)
	for _, path := range []string{"/api/v1/changes", "/api/v1/devices", "/api/v1/attachments/abc", "/api/v1/events"} {
		if w := request(t, h, "GET", path, "", nil); w.Code != 401 {
			t.Fatalf("unprotected %s: %d", path, w.Code)
		}
	}
	if w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "Device", "key": "wrong"}); w.Code != 401 {
		t.Fatal(w.Code)
	}
	w := request(t, h, "POST", "/api/v1/pair", "", map[string]string{"name": "Phone", "key": strings.Repeat("test", 8)})
	if w.Code != 201 {
		t.Fatal(w.Body.String())
	}
	id, e := s.Authorize(context.Background(), token)
	if e != nil {
		t.Fatal(e)
	}
	if w = request(t, h, "DELETE", "/api/v1/devices/"+id, token, nil); w.Code != 204 {
		t.Fatal(w.Code)
	}
	if w = request(t, h, "GET", "/api/v1/changes", token, nil); w.Code != 401 {
		t.Fatal("revoked token accepted")
	}
}

func TestVersionConflictAndIdempotency(t *testing.T) {
	_, h, token := setup(t)
	m := domain.Mutation{OperationID: "op-1", Record: task("task-1", "Original")}
	first := decodeResults(t, push(t, h, token, m))[0]
	if first.Record.Version != 1 || first.Record.Seq != 1 {
		t.Fatal(first)
	}
	retry := decodeResults(t, push(t, h, token, m))[0]
	if retry.Record.Version != 1 {
		t.Fatal("duplicate write")
	}
	changed := m
	changed.Record = task("task-1", "Changed")
	if w := push(t, h, token, changed); w.Code != 400 {
		t.Fatal("reused operation id accepted")
	}
	changed.OperationID = "op-2"
	conflict := decodeResults(t, push(t, h, token, changed))[0]
	if conflict.Status != "conflict" || conflict.Record.Version != 1 {
		t.Fatal(conflict)
	}
	changed.OperationID = "op-3"
	changed.Record.Version = 1
	if result := decodeResults(t, push(t, h, token, changed))[0]; result.Record.Version != 2 {
		t.Fatal(result)
	}
	w := request(t, h, "GET", "/api/v1/changes?after=1", token, nil)
	var changes struct {
		Records []domain.Record `json:"records"`
		Cursor  int64           `json:"cursor"`
	}
	json.Unmarshal(w.Body.Bytes(), &changes)
	if len(changes.Records) != 1 || changes.Cursor != 2 {
		t.Fatal(w.Body.String())
	}
}

func TestAtomicInvalidBatch(t *testing.T) {
	s, h, token := setup(t)
	invalid := domain.Record{ID: "block-1", Kind: "block", Data: json.RawMessage(`{"task_id":"missing","start":"2026-10-19T09:00:00Z","end":"2026-10-19T10:00:00Z","timezone":"UTC","reminders":[]}`)}
	w := push(t, h, token, domain.Mutation{OperationID: "one", Record: task("task-1", "Task")}, domain.Mutation{OperationID: "two", Record: invalid})
	if w.Code != 400 {
		t.Fatal(w.Body.String())
	}
	records, _, e := s.Changes(context.Background(), 0, 100)
	if e != nil {
		t.Fatal(e)
	}
	if len(records) != 0 {
		t.Fatal("partial transaction committed")
	}
}

func TestValidation(t *testing.T) {
	_, h, token := setup(t)
	cases := []domain.Record{
		{ID: "bad-cutoff", Kind: "series", Data: json.RawMessage(`{"title":"Series","start":"2026-10-19T09:00:00Z","minutes":30,"timezone":"UTC","rule":"FREQ=DAILY","cancelled_from":"not-a-date"}`)},
		{ID: "../bad", Kind: "task", Data: json.RawMessage(`{"title":"x","status":"todo"}`)},
		{ID: "empty", Kind: "task", Data: json.RawMessage(`{"title":" ","status":"todo"}`)},
		{ID: "status", Kind: "task", Data: json.RawMessage(`{"title":"x","status":"review"}`)},
		{ID: "backwards", Kind: "block", Data: json.RawMessage(`{"task_id":"t","start":"2026-10-19T10:00:00Z","end":"2026-10-19T09:00:00Z","timezone":"UTC"}`)},
		{ID: "zone", Kind: "block", Data: json.RawMessage(`{"task_id":"t","start":"2026-10-19T09:00:00Z","end":"2026-10-19T10:00:00Z","timezone":"Invalid/Zone"}`)},
	}
	for i, r := range cases {
		w := push(t, h, token, domain.Mutation{OperationID: "invalid", Record: r})
		if w.Code != 400 {
			t.Fatalf("case %d accepted", i)
		}
	}
}

func TestConcurrentDevices(t *testing.T) {
	s, h, token := setup(t)
	initial := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "create", Record: task("task", "Original")}))[0].Record
	var group sync.WaitGroup
	results := make(chan string, 2)
	for _, op := range []string{"a", "b"} {
		group.Add(1)
		go func(id string) {
			defer group.Done()
			record := initial
			record.Data = task("task", id).Data
			w := push(t, h, token, domain.Mutation{OperationID: id, Record: record})
			if w.Code != 200 {
				results <- "error"
				return
			}
			var body struct {
				Results []domain.Result `json:"results"`
			}
			json.Unmarshal(w.Body.Bytes(), &body)
			results <- body.Results[0].Status
		}(op)
	}
	group.Wait()
	close(results)
	counts := map[string]int{}
	for r := range results {
		counts[r]++
	}
	if counts["applied"] != 1 || counts["conflict"] != 1 {
		t.Fatal(counts)
	}
	records, _, e := s.Changes(context.Background(), 0, 10)
	if e != nil || len(records) != 2 {
		t.Fatal(records, e)
	}
}

func TestOnlineTimerStopsPrevious(t *testing.T) {
	s, h, token := setup(t)
	deviceID, e := s.Authorize(context.Background(), token)
	if e != nil {
		t.Fatal(e)
	}
	decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "create", Record: task("task", "Timer")}))
	start := time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	for i, id := range []string{"s1", "s2"} {
		data, _ := json.Marshal(domain.Session{TaskID: "task", DeviceID: deviceID, Start: start.Add(time.Duration(i) * time.Hour)})
		decodeResults(t, push(t, h, token, domain.Mutation{OperationID: id, Record: domain.Record{ID: id, Kind: "session", Data: data}}))
	}
	var count int
	if e = s.DB.QueryRow(`SELECT count(*) FROM records WHERE kind='session' AND json_extract(data,'$.end') IS NULL`).Scan(&count); e != nil {
		t.Fatal(e)
	}
	if count != 1 {
		t.Fatal("multiple active timers", count)
	}
}

func TestAttachmentValidation(t *testing.T) {
	_, h, token := setup(t)
	r := httptest.NewRequest("PUT", "/api/v1/attachments/"+strings.Repeat("0", 64), strings.NewReader("not the expected hash"))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w = request(t, h, "GET", "/api/v1/attachments/not-a-hash", token, nil); w.Code != 400 {
		t.Fatal(w.Code)
	}
}

func TestUnknownOfflineTimerKeepsOverlapAndCompletionStopsIt(t *testing.T) {
	s, h, token := setup(t)
	firstDevice, e := s.Authorize(context.Background(), token)
	if e != nil {
		t.Fatal(e)
	}
	secondDevice, secondToken, e := s.Pair(context.Background(), "Second device")
	if e != nil {
		t.Fatal(e)
	}
	current := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "task-create", Record: task("t", "Time")}))[0].Record
	firstStart := time.Now().UTC().Add(-2 * time.Hour)
	secondStart := firstStart.Add(time.Hour)
	for _, v := range []struct {
		id, device, token string
		start             time.Time
	}{{"first", firstDevice, token, firstStart}, {"second", secondDevice, secondToken, secondStart}} {
		data, _ := json.Marshal(domain.Session{TaskID: "t", DeviceID: v.device, Start: v.start})
		decodeResults(t, push(t, h, v.token, domain.Mutation{OperationID: v.id, Record: domain.Record{ID: v.id, Kind: "session", Data: data}}))
	}
	var data string
	if e = s.DB.QueryRow("SELECT data FROM records WHERE id='first'").Scan(&data); e != nil {
		t.Fatal(e)
	}
	var session domain.Session
	json.Unmarshal([]byte(data), &session)
	if session.End == nil || !session.End.After(secondStart) {
		t.Fatal("lost offline overlap", session)
	}
	var completed domain.Task
	json.Unmarshal(current.Data, &completed)
	completed.Status = "done"
	current.Data, _ = json.Marshal(completed)
	decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "done", Record: current}))
	var active int
	if e = s.DB.QueryRow("SELECT count(*) FROM records WHERE kind='session' AND json_extract(data,'$.end') IS NULL").Scan(&active); e != nil {
		t.Fatal(e)
	}
	if active != 0 {
		t.Fatal("completed task timer remained active")
	}
}

func TestUnscheduleAndSeriesDeletionContract(t *testing.T) {
	s, h, token := setup(t)
	record := func(id, kind string, data any) domain.Record {
		t.Helper()
		body, err := json.Marshal(data)
		if err != nil {
			t.Fatal(err)
		}
		return domain.Record{ID: id, Kind: kind, Data: body}
	}
	series := record("repeat-plan", "series", map[string]any{
		"title": "Recurring task", "description": "", "project_id": "", "start": "2026-10-19T09:00:00Z",
		"minutes": 60, "timezone": "UTC", "rule": "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", "reminders": []int{30240},
	})
	item := record("repeat-task", "task", map[string]any{"title": "Recurring task", "status": "todo", "series_id": series.ID, "occurrence": "2026-10-19T09:00:00Z"})
	block := record("repeat-block", "block", map[string]any{"task_id": item.ID, "start": "2026-10-19T09:00:00Z", "end": "2026-10-19T10:00:00Z", "timezone": "UTC", "reminders": []int{30240}})
	session := record("repeat-time", "session", map[string]any{"task_id": item.ID, "device_id": "test-device", "start": "2026-10-18T09:00:00Z", "end": "2026-10-18T09:20:00Z"})
	created := decodeResults(t, push(t, h, token,
		domain.Mutation{OperationID: "new-series", Record: series}, domain.Mutation{OperationID: "new-task", Record: item},
		domain.Mutation{OperationID: "new-block", Record: block}, domain.Mutation{OperationID: "new-session", Record: session}))
	series, item, block, session = created[0].Record, created[1].Record, created[2].Record, created[3].Record
	block.Deleted = true
	removed := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "unschedule", Record: block}))[0]
	if !removed.Record.Deleted || removed.Status != "applied" {
		t.Fatal(removed)
	}
	all, _, err := s.Changes(context.Background(), 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	latest := map[string]domain.Record{}
	for _, r := range all {
		latest[r.ID] = r
	}
	if latest[item.ID].Deleted || latest[session.ID].Deleted || !latest[block.ID].Deleted {
		t.Fatal("unscheduling must preserve the task and tracked time")
	}
	series.Deleted, item.Deleted, session.Deleted = true, true, true
	deleted := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "delete-series", Record: series}, domain.Mutation{OperationID: "delete-task", Record: item}, domain.Mutation{OperationID: "delete-time", Record: session}))
	for _, result := range deleted {
		if result.Status != "applied" || !result.Record.Deleted {
			t.Fatal(result)
		}
	}
	block.ID, block.Version, block.Deleted = "stale-new-block", 0, false
	late := decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "stale-offline-plan", Record: block}))[0]
	if !late.Record.Deleted {
		t.Fatal("late recurring block must be acknowledged as deleted")
	}
}

func TestLateOfflineOccurrencesRespectCancellation(t *testing.T) {
	for _, name := range []string{"deleted", "following", "exception", "active", "split"} {
		t.Run(name, func(t *testing.T) {
			s, h, token := setup(t)
			series := domain.Series{Title: "Series", Start: time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC), Minutes: 30, Timezone: "UTC", Rule: "FREQ=DAILY"}
			if name == "split" {
				series.Rule += ";UNTIL=20261020T235959Z"
			}
			if name == "following" {
				series.Rule += ";UNTIL=20261020T235959Z"
				series.CancelledFrom = "2026-10-21T00:00:00Z"
			}
			if name == "exception" {
				series.Exceptions = []string{"2026-10-21T09:00:00.000Z"}
			}
			data, _ := json.Marshal(series)
			master := domain.Record{ID: "series", Kind: "series", Deleted: name == "deleted", Data: data}
			decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "series-op", Record: master}))
			item := domain.Record{ID: "offline-instance", Kind: "task", Data: json.RawMessage(`{"title":"Late offline occurrence","status":"todo","series_id":"series","occurrence":"2026-10-21T09:00:00Z"}`)}
			decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "task-op", Record: item}))
			block := domain.Record{ID: "offline-block", Kind: "block", Data: json.RawMessage(`{"task_id":"offline-instance","start":"2026-10-21T09:00:00Z","end":"2026-10-21T09:30:00Z","timezone":"UTC","reminders":[0]}`)}
			decodeResults(t, push(t, h, token, domain.Mutation{OperationID: "block-op", Record: block}))
			all, _, err := s.Changes(context.Background(), 0, 100)
			if err != nil {
				t.Fatal(err)
			}
			latest := map[string]domain.Record{}
			for _, r := range all {
				latest[r.ID] = r
			}
			for _, id := range []string{item.ID, block.ID} {
				if latest[id].Deleted != (name != "active" && name != "split") {
					t.Fatalf("%s deleted = %v", id, latest[id].Deleted)
				}
			}
		})
	}
}
