package httpapi

import (
	"encoding/json"
	"io"
	"net/http"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func (a *API) encryptionRoutes(mux *http.ServeMux) {
	mux.Handle("POST /api/v1/encryption", a.auth(http.HandlerFunc(a.enableEncryption)))
	mux.Handle("GET /api/v1/snapshot", a.auth(a.current(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		snapshot, err := a.Store.Export(r.Context())
		if err != nil {
			fail(w, 500, "storage_error")
			return
		}
		write(w, 200, snapshot)
	}))))
	mux.Handle("PUT /api/v1/encryption/password", a.auth(http.HandlerFunc(a.updatePassword)))
	mux.Handle("GET /api/v1/guest-proposals", a.auth(a.current(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		records, err := a.Store.GuestProposals(r.Context())
		if err != nil {
			fail(w, 500, "storage_error")
			return
		}
		write(w, 200, map[string]any{"records": records})
	}))))
	mux.Handle("GET /api/v1/calendar-shares", a.auth(a.current(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		shares, err := a.Store.ActiveCalendarShares(r.Context(), a.shareNow())
		if err != nil {
			fail(w, 500, "storage_error")
			return
		}
		write(w, 200, map[string]any{"shares": shares, "proposal_statuses": true})
	}))))
	mux.Handle("PUT /api/v1/calendar-shares/{id}/availability", a.auth(a.current(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var input store.Availability
		r.Body = http.MaxBytesReader(w, r.Body, 1024*1024)
		d := json.NewDecoder(r.Body)
		d.DisallowUnknownFields()
		if d.Decode(&input) != nil || d.Decode(new(any)) != io.EOF {
			fail(w, 400, "invalid_snapshot")
			return
		}
		updated, err := a.Store.UpdateAvailability(r.Context(), r.PathValue("id"), input, a.shareNow())
		if err != nil {
			shareError(w, err)
			return
		}
		write(w, 200, map[string]bool{"updated": updated})
	}))))
}

func (a *API) enableEncryption(w http.ResponseWriter, r *http.Request) {
	var input struct {
		KeyID    string                 `json:"key_id"`
		Envelope *domain.PasswordConfig `json:"password_config"`
	}
	if decode(w, r, &input) != nil || input.Envelope == nil || input.Envelope.Validate() != nil {
		fail(w, 400, "invalid_encryption_key_id")
		return
	}
	a.DataMu.Lock()
	defer a.DataMu.Unlock()
	generation, err := a.Store.Generation(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if r.Header.Get("X-Yggvion-Generation") != generation {
		fail(w, 409, "generation_changed")
		return
	}
	if err = a.Store.EnableEncryption(r.Context(), input.KeyID, *input.Envelope); err != nil {
		fail(w, 409, "encryption_initialization_conflict")
		return
	}
	write(w, 200, map[string]string{"key_id": input.KeyID})
}

func (a *API) updatePassword(w http.ResponseWriter, r *http.Request) {
	var input struct {
		KeyID   string                `json:"key_id"`
		Cursor  *int64                `json:"cursor"`
		Config  domain.PasswordConfig `json:"password_config"`
		Records []domain.Record       `json:"records"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || input.Config.Validate() != nil || input.Cursor == nil || input.Records == nil {
		fail(w, 400, "invalid_password_configuration")
		return
	}
	a.DataMu.Lock()
	defer a.DataMu.Unlock()
	if err := a.Store.RotatePassword(r.Context(), r.Header.Get("X-Yggvion-Generation"), input.KeyID, *input.Cursor, input.Config, input.Records); err != nil {
		if err == store.ErrConflict {
			fail(w, 409, "workspace_changed")
			return
		}
		if err == store.ErrInvalid {
			fail(w, 400, "invalid_password_configuration")
			return
		}
		fail(w, 500, "storage_error")
		return
	}
	a.broadcast()
	write(w, 200, map[string]string{"key_id": input.Config.KeyID})
}
