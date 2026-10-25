package httpapi

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

type requestBucket struct {
	updated time.Time
	tokens  float64
}

func (b *requestBucket) take(now time.Time, burst, perSecond float64) bool {
	if b.updated.IsZero() {
		b.tokens = burst
	} else {
		b.tokens = min(burst, b.tokens+now.Sub(b.updated).Seconds()*perSecond)
	}
	b.updated = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

type sourceBudget struct {
	requests      requestBucket
	failureWindow time.Time
	failures      int
}

type deviceActivity struct{ requests, streams int }

// All maps and counters are bounded. Limits run before authentication touches
// SQLite; forwarded headers cannot manufacture a new source identity.
type apiLimits struct {
	mu                                        sync.Mutex
	sources                                   map[string]*sourceBudget
	devices                                   map[string]*deviceActivity
	global                                    requestBucket
	cleaned                                   time.Time
	auth, requests, streams, heavy, transfers int
}

func requestSource(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		ip = ip.Unmap()
		if ip.Is6() {
			return netip.PrefixFrom(ip, 64).Masked().String()
		}
		return ip.String()
	}
	return "unknown"
}

func (l *apiLimits) allow(source string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.sources == nil {
		l.sources = make(map[string]*sourceBudget)
	}
	if now.Sub(l.cleaned) >= time.Minute {
		for key, b := range l.sources {
			if now.Sub(b.requests.updated) > 5*time.Minute {
				delete(l.sources, key)
			}
		}
		l.cleaned = now
	}
	b := l.sources[source]
	if b == nil {
		if len(l.sources) >= 4096 {
			return false
		}
		b = &sourceBudget{}
		l.sources[source] = b
	}
	// An already throttled source cannot consume the shared budget.
	return b.requests.take(now, 120, 30) && l.global.take(now, 480, 120)
}

func (l *apiLimits) beginAuth(source string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if b := l.sources[source]; b != nil {
		if now.Sub(b.failureWindow) >= time.Minute {
			b.failureWindow, b.failures = now, 0
		}
		if b.failures >= 30 {
			return false
		}
	}
	if l.auth >= 8 {
		return false
	}
	l.auth++
	return true
}

func (l *apiLimits) endAuth(source string, failed bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.auth--
	if failed {
		if b := l.sources[source]; b != nil {
			b.failures++
		}
	}
}

func (l *apiLimits) beginDevice(device, path string) (func(), bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.devices == nil {
		l.devices = make(map[string]*deviceActivity)
	}
	d := l.devices[device]
	if d == nil {
		d = &deviceActivity{}
	}
	stream := path == "/api/v1/events"
	heavy := path == "/api/v1/snapshot" || path == "/api/v1/encryption/password"
	transfer := strings.HasPrefix(path, "/api/v1/attachments/") || path == "/api/v1/backups/import" || strings.HasSuffix(path, "/download")
	if stream {
		if l.streams >= 16 || d.streams >= 2 {
			return nil, false
		}
		l.streams++
		d.streams++
	} else {
		if l.requests >= 24 || d.requests >= 4 || (heavy && l.heavy >= 1) || (transfer && l.transfers >= 4) {
			return nil, false
		}
		l.requests++
		d.requests++
		if heavy {
			l.heavy++
		}
		if transfer {
			l.transfers++
		}
	}
	l.devices[device] = d
	return func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if stream {
			l.streams--
			d.streams--
		} else {
			l.requests--
			d.requests--
			if heavy {
				l.heavy--
			}
			if transfer {
				l.transfers--
			}
		}
		if d.requests == 0 && d.streams == 0 {
			delete(l.devices, device)
		}
	}, true
}

func limited(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "5")
	fail(w, http.StatusTooManyRequests, "rate_limited")
}

func (a *API) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/") {
			next.ServeHTTP(w, r)
			return
		}
		if !a.limits.allow(requestSource(r), time.Now()) {
			limited(w)
			return
		}
		duration := 2 * time.Minute
		if strings.HasPrefix(r.URL.Path, "/api/v1/attachments/") && (r.Method == http.MethodGet || r.Method == http.MethodPut) {
			duration = 15 * time.Minute
		}
		if r.URL.Path == "/api/v1/backups/import" || strings.HasSuffix(r.URL.Path, "/download") {
			duration = 2 * time.Hour
		}
		if r.URL.Path == "/api/v1/events" {
			duration = time.Hour
		}
		ctx, cancel := context.WithTimeout(r.Context(), duration)
		defer cancel()
		// SSE renews its own short write deadline for each flush.
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(duration))
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
