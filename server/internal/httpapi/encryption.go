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
	mux.Handle("PUT /api/v1/encryption/password", a.auth(a.current(http.HandlerFunc(a.updatePassword))))
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
		write(w, 200, map[string]any{"shares": shares})
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
		if err := a.Store.UpdateAvailability(r.Context(), r.PathValue("id"), input, a.shareNow()); err != nil {
			shareError(w, err)
			return
		}
		write(w, 200, map[string]bool{"updated": true})
	}))))
}

func (a *API) enableEncryption(w http.ResponseWriter, r *http.Request) {
	var input struct {
		KeyID    string                   `json:"key_id"`
		Envelope *domain.PasswordEnvelope `json:"password_envelope"`
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
		KeyID    string                  `json:"key_id"`
		Expected int64                   `json:"expected_revision"`
		Envelope domain.PasswordEnvelope `json:"password_envelope"`
	}
	if decode(w, r, &input) != nil || input.Envelope.Validate() != nil || input.Envelope.KeyID != input.KeyID {
		fail(w, 400, "invalid_password_envelope")
		return
	}
	if err := a.Store.SetPasswordEnvelope(r.Context(), input.KeyID, input.Expected, input.Envelope); err != nil {
		if err == store.ErrConflict {
			fail(w, 409, "password_changed")
			return
		}
		if err == store.ErrInvalid {
			fail(w, 400, "invalid_password_envelope")
			return
		}
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"revision": input.Envelope.Revision})
}
