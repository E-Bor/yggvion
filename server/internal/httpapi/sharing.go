package httpapi

import (
	"embed"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"yggvion/server/internal/store"
)

//go:embed public/*
var calendarPage embed.FS

type shareRateWindow struct {
	start time.Time
	count int
}
type shareLimiter struct {
	mu      sync.Mutex
	clients map[string]shareRateWindow
	global  shareRateWindow
}

func (l *shareLimiter) allow(address string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.global.start) >= time.Minute {
		l.global = shareRateWindow{start: now}
	}
	if l.global.count >= 300 {
		return false
	}
	l.global.count++
	if l.clients == nil {
		l.clients = make(map[string]shareRateWindow)
	}
	for key, value := range l.clients {
		if now.Sub(value.start) >= time.Minute {
			delete(l.clients, key)
		}
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		host = address
	}
	window, found := l.clients[host]
	if !found {
		if len(l.clients) >= 1024 {
			return false
		}
		window = shareRateWindow{start: now}
	}
	if window.count >= 60 {
		return false
	}
	window.count++
	l.clients[host] = window
	return true
}

func shareHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow, noarchive")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
}

func (a *API) shareNow() time.Time {
	if a.ShareClock != nil {
		return a.ShareClock()
	}
	return time.Now().UTC()
}

func (a *API) calendarShareRoutes(mux *http.ServeMux) {
	mux.Handle("POST /api/v1/calendar-shares", a.auth(a.current(http.HandlerFunc(a.createCalendarShare))))
	mux.Handle("DELETE /api/v1/calendar-shares/{id}", a.auth(http.HandlerFunc(a.revokeCalendarShare)))
	a.publicCalendarRoutes(mux)
}

// PublicHandler deliberately contains no pairing, synchronization or admin routes.
func (a *API) PublicHandler() http.Handler {
	mux := http.NewServeMux()
	a.publicCalendarRoutes(mux)
	return mux
}

func (a *API) publicCalendarRoutes(mux *http.ServeMux) {
	for path, asset := range map[string]string{"/share": "index.html", "/share/calendar.css": "calendar.css", "/share/calendar.js": "calendar.js", "/share/logo.svg": "logo.svg"} {
		mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			shareHeaders(w)
			data, err := calendarPage.ReadFile("public/" + asset)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			mime := "text/html; charset=utf-8"
			if strings.HasSuffix(asset, ".css") {
				mime = "text/css; charset=utf-8"
			}
			if strings.HasSuffix(asset, ".js") {
				mime = "text/javascript; charset=utf-8"
			}
			if strings.HasSuffix(asset, ".svg") {
				mime = "image/svg+xml"
			}
			w.Header().Set("Content-Type", mime)
			w.Write(data)
		})
	}
	mux.HandleFunc("GET /public/calendar", a.publicCalendar)
	mux.HandleFunc("POST /public/proposals", a.publicProposal)
}

func (a *API) createCalendarShare(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var input struct {
		Days int `json:"days"`
	}
	if smallJSON(w, r, &input) != nil || input.Days < 1 || input.Days > 30 {
		fail(w, 400, "invalid_range")
		return
	}
	base := a.PublicURL
	if a.EnsurePublic != nil {
		var err error
		base, err = a.EnsurePublic(r.Context())
		if err != nil {
			fail(w, 503, "public_https_unavailable")
			return
		}
	}
	address, err := url.Parse(base)
	if err != nil || address.Scheme != "https" || address.Host == "" || address.User != nil || address.RawQuery != "" || address.Fragment != "" || (address.Path != "" && address.Path != "/") {
		fail(w, 503, "public_https_unavailable")
		return
	}
	share, token, err := a.Store.CreateCalendarShare(r.Context(), r.Context().Value(deviceKey{}).(string), input.Days, a.shareNow())
	if err != nil {
		shareError(w, err)
		return
	}
	address.Path = "/share"
	address.Fragment = token // Secret stays out of HTTP URLs, referrers and access logs.
	write(w, 201, map[string]any{"id": share.ID, "url": address.String(), "expires": share.Expires, "start": share.Start, "end": share.End, "timezone": share.Timezone})
}

func (a *API) revokeCalendarShare(w http.ResponseWriter, r *http.Request) {
	if err := a.Store.RevokeCalendarShare(r.Context(), r.PathValue("id")); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, map[string]bool{"revoked": true})
}

func (a *API) authorizePublic(w http.ResponseWriter, r *http.Request) (string, bool) {
	shareHeaders(w)
	if !a.shareLimit.allow(r.RemoteAddr, a.shareNow()) {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "too_many_requests")
		return "", false
	}
	// Never use forwarded headers to establish trust or rate-limit identity.
	if origin := r.Header.Get("Origin"); origin != "" {
		parsed, err := url.Parse(origin)
		if err != nil || parsed.Host != r.Host || (parsed.Scheme != "https" && parsed.Scheme != "http") {
			fail(w, 403, "cross_origin_forbidden")
			return "", false
		}
	}
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		fail(w, 404, "share_unavailable")
		return "", false
	}
	return strings.TrimPrefix(value, "Bearer "), true
}

func (a *API) publicCalendar(w http.ResponseWriter, r *http.Request) {
	token, ok := a.authorizePublic(w, r)
	if !ok {
		return
	}
	a.DataMu.RLock()
	defer a.DataMu.RUnlock()
	share, busy, err := a.Store.PublicCalendar(r.Context(), token, a.shareNow())
	if err != nil {
		shareError(w, err)
		return
	}
	// Do not serialize CalendarShare: its identifier is for the owner only.
	write(w, 200, map[string]any{"expires": share.Expires, "start": share.Start, "end": share.End, "timezone": share.Timezone, "busy": busy, "now": a.shareNow()})
}

func (a *API) publicProposal(w http.ResponseWriter, r *http.Request) {
	token, ok := a.authorizePublic(w, r)
	if !ok {
		return
	}
	var input store.GuestProposal
	if smallJSON(w, r, &input) != nil {
		fail(w, 400, "invalid_proposal")
		return
	}
	a.DataMu.RLock()
	defer a.DataMu.RUnlock()
	if err := a.Store.ProposeEvent(r.Context(), token, input, a.shareNow()); err != nil {
		shareError(w, err)
		return
	}
	write(w, 201, map[string]bool{"proposed": true})
	a.broadcast()
}

func smallJSON(w http.ResponseWriter, r *http.Request, target any) error {
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		return store.ErrInvalid
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return store.ErrInvalid
	}
	return nil
}

func shareError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrShareUnavailable):
		fail(w, 404, "share_unavailable")
	case errors.Is(err, store.ErrShareLimit):
		fail(w, 429, "share_limit")
	case errors.Is(err, store.ErrTimeBusy):
		fail(w, 409, "time_busy")
	case errors.Is(err, store.ErrInvalid):
		fail(w, 400, "invalid_proposal")
	default:
		fail(w, 500, "storage_error")
	}
}
