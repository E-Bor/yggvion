package httpapi

import (
	"context"
	"errors"
	"net/http"
	"os"
	"time"

	"yggvion/server/internal/backup"
	"yggvion/server/internal/store"
)

// Check and execute under the same lock: restore cannot race a stale upload.
func (a *API) current(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.DataMu.RLock()
		defer a.DataMu.RUnlock()
		generation, err := a.Store.Generation(r.Context())
		if err != nil {
			fail(w, 500, "storage_error")
			return
		}
		given := r.Header.Get("X-Yggvion-Generation")
		if given != generation {
			fail(w, 409, "generation_changed")
			return
		}
		w.Header().Set("X-Yggvion-Generation", generation)
		next.ServeHTTP(w, r)
	})
}
func (a *API) state(w http.ResponseWriter, r *http.Request) {
	a.DataMu.RLock()
	defer a.DataMu.RUnlock()
	generation, err := a.Store.Generation(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	keyID, err := a.Store.EncryptionKey(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	var created, reason string
	var snapshotCursor int64
	if err = a.Store.DB.QueryRowContext(r.Context(), `SELECT
  COALESCE((SELECT value FROM server_meta WHERE key='snapshot_created'), ''),
  COALESCE((SELECT value FROM server_meta WHERE key='generation_reason'), ''),
  COALESCE((SELECT value FROM server_meta WHERE key='snapshot_cursor'), '0')`).Scan(&created, &reason, &snapshotCursor); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	password, err := a.Store.PasswordConfig(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"password_config": password, "e2ee": true, "encryption_key_id": keyID, "generation_reason": reason, "snapshot_created": created, "snapshot_cursor": snapshotCursor, "generation": generation, "protocol": 6, "server_schema": store.SchemaVersion, "private_ca": a.CAPEM, "backups": a.Backups != nil})
}
func (a *API) invite(w http.ResponseWriter, r *http.Request) {
	var input struct{}
	if r.ContentLength != 0 && decode(w, r, &input) != nil {
		fail(w, 400, "invalid_invitation")
		return
	}
	code, err := a.Store.Invite(r.Context(), r.Context().Value(deviceKey{}).(string))
	if err != nil {
		fail(w, 409, "invitation_unavailable")
		return
	}
	write(w, 201, map[string]any{"code": code, "expires_at": time.Now().Add(10 * time.Minute).UTC(), "private_ca": a.CAPEM})
}

func (a *API) backupRoutes(mux *http.ServeMux) {
	register := func(pattern string, handler http.HandlerFunc) {
		mux.Handle(pattern, a.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if a.Backups == nil {
				fail(w, 503, "backups_unavailable")
				return
			}
			handler(w, r)
		})))
	}
	register("GET /api/v1/backups", func(w http.ResponseWriter, r *http.Request) {
		entries, err := a.Backups.List()
		if err != nil {
			fail(w, 500, "backup_error")
			return
		}
		remote, err := a.Backups.RemoteConfig()
		if err != nil {
			fail(w, 500, "backup_error")
			return
		}
		remote.Secret = ""
		remote.PrivateKey = ""
		write(w, 200, map[string]any{"backups": entries, "config": a.Backups.Config(), "status": a.Backups.Status(), "remote": remote})
	})
	register("PUT /api/v1/backups/config", func(w http.ResponseWriter, r *http.Request) {
		var c backup.Config
		if decode(w, r, &c) != nil {
			fail(w, 400, "invalid_config")
			return
		}
		if err := a.Backups.Configure(c); err != nil {
			fail(w, 400, "invalid_config")
			return
		}
		write(w, 200, c)
	})
	register("PUT /api/v1/backups/remote", func(w http.ResponseWriter, r *http.Request) {
		var c backup.RemoteConfig
		if decode(w, r, &c) != nil {
			fail(w, 400, "invalid_remote")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		if err := a.Backups.ConfigureRemote(ctx, c); err != nil {
			fail(w, 400, "remote_connection_failed")
			return
		}
		write(w, 200, map[string]string{"status": "configured"})
	})
	register("POST /api/v1/backups/dropbox/connect", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			AppKey   string `json:"app_key"`
			Code     string `json:"code"`
			Verifier string `json:"code_verifier"`
			Redirect string `json:"redirect_uri"`
		}
		if decode(w, r, &input) != nil {
			fail(w, 400, "invalid_dropbox_authorization")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
		defer cancel()
		if err := a.Backups.ConfigureDropbox(ctx, input.AppKey, input.Code, input.Verifier, input.Redirect); err != nil {
			fail(w, 400, "dropbox_connection_failed")
			return
		}
		write(w, 200, map[string]string{"status": "configured"})
	})
	register("GET /api/v1/backups/remote", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		entries, err := a.Backups.RemoteList(ctx)
		if err != nil {
			fail(w, 502, "remote_connection_failed")
			return
		}
		write(w, 200, map[string]any{"backups": entries})
	})
	register("POST /api/v1/backups/remote/{id}/fetch", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		err := a.Backups.Start(a.Lifetime, "fetch_remote", func(ctx context.Context) error { return a.Backups.FetchRemote(ctx, id) })
		a.acceptJob(w, err)
	})
	register("POST /api/v1/backups", func(w http.ResponseWriter, r *http.Request) {
		err := a.Backups.Start(a.Lifetime, "create", func(ctx context.Context) error {
			entry, err := a.Backups.Create(ctx, "manual")
			if err != nil {
				return err
			}
			return a.Backups.Replicate(ctx, entry)
		})
		a.acceptJob(w, err)
	})
	register("GET /api/v1/backups/{id}/download", func(w http.ResponseWriter, r *http.Request) {
		path, err := a.Backups.Path(r.PathValue("id"))
		if err != nil {
			fail(w, 400, "invalid_id")
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="`+r.PathValue("id")+`.yggbackup"`)
		http.ServeFile(w, r, path)
	})
	register("DELETE /api/v1/backups/{id}", func(w http.ResponseWriter, r *http.Request) {
		err := a.Backups.Start(a.Lifetime, "delete", func(ctx context.Context) error { return a.Backups.Delete(r.PathValue("id")) })
		a.acceptJob(w, err)
	})
	register("POST /api/v1/backups/{id}/restore", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			Confirm string `json:"confirm"`
		}
		if decode(w, r, &input) != nil || input.Confirm != "restore" {
			fail(w, 400, "confirmation_required")
			return
		}
		path, err := a.Backups.Path(r.PathValue("id"))
		if err != nil {
			fail(w, 400, "invalid_id")
			return
		}
		err = a.Backups.Start(a.Lifetime, "restore", func(ctx context.Context) error {
			err := a.Backups.Restore(ctx, path)
			if err == nil {
				a.broadcast()
			}
			return err
		})
		a.acceptJob(w, err)
	})
	register("POST /api/v1/backups/import", func(w http.ResponseWriter, r *http.Request) {
		var name string
		keep := false
		defer func() {
			if name != "" && !keep {
				os.Remove(name)
			}
		}()
		err := a.Backups.StartPrepared(a.Lifetime, "import", func() error {
			if r.ContentLength > backup.MaxImportBytes {
				return &http.MaxBytesError{Limit: backup.MaxImportBytes}
			}
			if err := a.Backups.CheckSpace(r.ContentLength); err != nil {
				return err
			}
			if err := http.NewResponseController(w).SetReadDeadline(time.Now().Add(2 * time.Hour)); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return err
			}
			r.Body = http.MaxBytesReader(w, r.Body, backup.MaxImportBytes)
			file, err := os.CreateTemp(a.Backups.Dir, ".upload-*")
			if err != nil {
				return err
			}
			name = file.Name()
			defer file.Close()
			if _, err = a.Backups.CopyWithReserve(r.Context(), file, r.Body); err != nil {
				return err
			}
			return file.Close()
		}, func(ctx context.Context) error {
			defer os.Remove(name)
			_, err := a.Backups.Import(ctx, name)
			return err
		})
		keep = err == nil
		var tooLarge *http.MaxBytesError
		switch {
		case errors.As(err, &tooLarge):
			fail(w, 413, "backup_too_large")
		case errors.Is(err, backup.ErrNoSpace):
			fail(w, 507, "insufficient_storage")
		case err != nil && !errors.Is(err, backup.ErrBusy):
			fail(w, 400, "backup_upload_failed")
		default:
			a.acceptJob(w, err)
		}
	})
}
func (a *API) acceptJob(w http.ResponseWriter, err error) {
	if err != nil {
		fail(w, 409, "backup_busy")
		return
	}
	write(w, 202, map[string]string{"status": "accepted"})
}
