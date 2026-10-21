package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"yggvion/server/internal/domain"
)

func TestSearchTypoSettingsContract(t *testing.T) {
	for _, tc := range []struct {
		name, field string
		valid       bool
	}{
		{"legacy", "", true},
		{"null", `,"search_typos":null`, true},
		{"exact", `,"search_typos":0`, true},
		{"one", `,"search_typos":1`, true},
		{"two", `,"search_typos":2`, true},
		{"negative", `,"search_typos":-1`, false},
		{"too_many", `,"search_typos":3`, false},
		{"fraction", `,"search_typos":1.5`, false},
		{"string", `,"search_typos":"2"`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, h, token := setup(t)
			data := json.RawMessage(`{"default_minutes":30,"reminders":[0],"timezone":"UTC"` + tc.field + `}`)
			response := push(t, h, token, domain.Mutation{
				OperationID: "search-setting",
				Record:      domain.Record{ID: "settings", Kind: "settings", Data: data},
			})
			if !tc.valid {
				if response.Code != http.StatusBadRequest {
					t.Fatalf("invalid tolerance accepted: %d", response.Code)
				}
				return
			}
			result := decodeResults(t, response)[0].Record
			var input, output domain.Settings
			if err := json.Unmarshal(data, &input); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(result.Data, &output); err != nil {
				t.Fatal(err)
			}
			if input.SearchTypos == nil {
				if output.SearchTypos != nil {
					t.Fatal("legacy tolerance changed")
				}
			} else if output.SearchTypos == nil || *input.SearchTypos != *output.SearchTypos {
				t.Fatal("tolerance did not round-trip")
			}
		})
	}
}
