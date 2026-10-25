package httpapi

import (
	"context"
	"errors"
	"net/http"

	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

var (
	errAttachmentCleanupBusy = errors.New("server_busy")
	errAttachmentGeneration  = errors.New("generation_changed")
)

// Read the small request before locking, and release the lock before writing
// the response. A slow client must not hold the exclusive workspace lock.
func (a *API) removeAttachment(ctx context.Context, generation, id string, record domain.Record) (domain.Record, error) {
	if !a.DataMu.TryLock() {
		return domain.Record{}, errAttachmentCleanupBusy
	}
	defer a.DataMu.Unlock()
	current, err := a.Store.Generation(ctx)
	if err != nil {
		return domain.Record{}, err
	}
	if generation != current {
		return domain.Record{}, errAttachmentGeneration
	}
	return a.Store.DeleteAttachment(ctx, a.Files, id, record)
}

func (a *API) deleteAttachment(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Record domain.Record `json:"record"`
	}
	if !attachmentID(r.PathValue("id")) || decode(w, r, &body) != nil {
		fail(w, 400, "invalid_attachment")
		return
	}
	record, err := a.removeAttachment(r.Context(), r.Header.Get("X-Yggvion-Generation"), r.PathValue("id"), body.Record)
	if errors.Is(err, errAttachmentCleanupBusy) || errors.Is(err, errAttachmentGeneration) {
		fail(w, 409, err.Error())
		return
	}
	if errors.Is(err, store.ErrAttachmentUsed) {
		fail(w, 409, "attachment_in_use")
		return
	}
	if errors.Is(err, store.ErrConflict) {
		fail(w, 409, "attachment_changed")
		return
	}
	if errors.Is(err, store.ErrInvalid) {
		fail(w, 400, "invalid_attachment")
		return
	}
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	a.broadcast()
	write(w, 200, map[string]any{"record": record})
}

func (a *API) presentAttachments(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if decode(w, r, &body) != nil {
		fail(w, 400, "invalid_attachments")
		return
	}
	ids, err := a.Store.PresentAttachments(r.Context(), body.IDs)
	if errors.Is(err, store.ErrInvalid) {
		fail(w, 400, "invalid_attachments")
		return
	}
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"ids": ids})
}
