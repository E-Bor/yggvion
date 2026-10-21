package httpapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"time"

	"yggvion/server/internal/backup"
)

// Check and execute under the same lock: restore cannot race a stale upload.
func (a *API) current(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.DataMu.RLock()
		defer a.DataMu.RUnlock()
		generation, required, err := a.Store.Generation(r.Context())
		if err != nil {
			fail(w, 500, "storage_error")
			return
		}
		given := r.Header.Get("X-Yggvion-Generation")
		if (given != "" && given != generation) || (required && given == "") {
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
	generation, required, err := a.Store.Generation(r.Context())
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]any{"generation": generation, "generation_required": required, "protocol": 2, "note_folders": true, "server_schema": 3, "private_ca": a.CAPEM, "backups": a.Backups != nil})
}
func (a *API) invite(w http.ResponseWriter, r *http.Request) {
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
	register("GET /api/v1/backups/recovery-key", func(w http.ResponseWriter, r *http.Request) {
		write(w, 200, map[string]string{"key": a.Backups.RecoveryKey()})
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
		var input struct {
			Key string `json:"key"`
		}
		if decode(w, r, &input) != nil {
			fail(w, 400, "invalid_json")
			return
		}
		id := r.PathValue("id")
		err := a.Backups.Start(a.Lifetime, "fetch_remote", func(ctx context.Context) error { return a.Backups.FetchRemote(ctx, id, input.Key) })
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
			err := a.Backups.Restore(ctx, path, "")
			if err == nil {
				a.broadcast()
			}
			return err
		})
		a.acceptJob(w, err)
	})
	register("POST /api/v1/backups/import", func(w http.ResponseWriter, r *http.Request) {
		if a.Backups.Status().Running {
			fail(w, 409, "backup_busy")
			return
		}
		// Body is an encrypted archive, never multipart paths or executable SQL.
		if err := http.NewResponseController(w).SetReadDeadline(time.Now().Add(2 * time.Hour)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			fail(w, 500, "backup_error")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 100<<30)
		file, err := os.CreateTemp(a.Backups.Dir, ".upload-*")
		if err != nil {
			fail(w, 500, "backup_error")
			return
		}
		name := file.Name()
		keep := false
		defer func() {
			file.Close()
			if !keep {
				os.Remove(name)
			}
		}()
		if _, err = io.Copy(file, r.Body); err != nil {
			fail(w, 413, "backup_upload_failed")
			return
		}
		if err = file.Close(); err != nil {
			fail(w, 500, "backup_error")
			return
		}
		key := r.Header.Get("X-Yggvion-Recovery-Key")
		err = a.Backups.Start(a.Lifetime, "import", func(ctx context.Context) error {
			defer os.Remove(name)
			_, err := a.Backups.Import(ctx, name, key)
			return err
		})
		keep = err == nil
		a.acceptJob(w, err)
	})
}
func (a *API) acceptJob(w http.ResponseWriter, err error) {
	if err != nil {
		fail(w, 409, "backup_busy")
		return
	}
	write(w, 202, map[string]string{"status": "accepted"})
}
