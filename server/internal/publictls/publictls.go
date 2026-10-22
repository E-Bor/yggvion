// Package publictls provides browser-trusted HTTPS for calendar invitations.
// Its identity and HTTP handler are separate from the private synchronization API.
package publictls

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/acme"
)

type Manager struct {
	dir, host, address string
	handler            http.Handler
	mu                 sync.Mutex
	certificate        atomic.Pointer[tls.Certificate]
	server             *http.Server
	retryAfter         time.Time
	lifetime           context.Context
}

func New(ctx context.Context, dir, host string, port int, handler http.Handler) (*Manager, error) {
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || port < 1 || port > 65535 || port == 80 {
		return nil, errors.New("public HTTPS requires a public IP and a separate TCP port")
	}
	return &Manager{dir: dir, host: ip.String(), address: net.JoinHostPort("", strconv.Itoa(port)), handler: handler, lifetime: ctx}, nil
}

func atomicWrite(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".certificate-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

func certificatePair(data []byte, host string, now time.Time, roots *x509.CertPool) (*tls.Certificate, error) {
	pair, err := tls.X509KeyPair(data, data)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	intermediates := x509.NewCertPool()
	for _, der := range pair.Certificate[1:] {
		certificate, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, err
		}
		intermediates.AddCert(certificate)
	}
	if _, err = leaf.Verify(x509.VerifyOptions{DNSName: host, Roots: roots, Intermediates: intermediates, CurrentTime: now}); err != nil {
		return nil, err
	}
	pair.Leaf = leaf
	return &pair, nil
}

func (m *Manager) Ensure(ctx context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := m.lifetime.Err(); err != nil {
		return "", err
	}
	if err := os.MkdirAll(m.dir, 0700); err != nil {
		return "", err
	}
	now := time.Now()
	if m.certificate.Load() == nil {
		data, err := os.ReadFile(filepath.Join(m.dir, "public.pem"))
		if err == nil {
			pair, parseErr := certificatePair(data, m.host, now, nil)
			if parseErr == nil {
				m.certificate.Store(pair)
			}
		} else if !os.IsNotExist(err) {
			return "", err
		}
	}
	var listener net.Listener
	if m.server == nil {
		var err error
		listener, err = net.Listen("tcp", m.address)
		if err != nil {
			return "", fmt.Errorf("public HTTPS port unavailable: %w", err)
		}
		defer func() {
			if listener != nil {
				listener.Close()
			}
		}()
	}
	pair := m.certificate.Load()
	if pair == nil || pair.Leaf.NotAfter.Sub(now) < 48*time.Hour {
		if now.Before(m.retryAfter) && (pair == nil || pair.Leaf.NotAfter.Sub(now) < 2*time.Hour) {
			return "", errors.New("certificate issuance is cooling down; retry later")
		}
		if !now.Before(m.retryAfter) {
			issueContext, cancel := context.WithTimeout(ctx, 2*time.Minute)
			stop := context.AfterFunc(m.lifetime, cancel)
			data, err := m.issue(issueContext)
			stop()
			cancel()
			if err == nil {
				pair, err = certificatePair(data, m.host, time.Now(), nil)
				if err == nil {
					err = atomicWrite(filepath.Join(m.dir, "public.pem"), data)
				}
				if err == nil {
					m.certificate.Store(pair)
				}
			}
			if err != nil {
				m.retryAfter = now.Add(time.Hour)
				slog.Error("public certificate renewal failed", "error", err)
				pair = m.certificate.Load()
				if pair == nil || pair.Leaf.NotAfter.Sub(now) < 2*time.Hour {
					return "", err
				}
			}
		}
	}
	if m.server == nil {
		server := &http.Server{Handler: m.handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8 << 10, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			current := m.certificate.Load()
			if current == nil {
				return nil, errors.New("public certificate unavailable")
			}
			return current, nil
		}}}
		if err := atomicWrite(filepath.Join(m.dir, "enabled"), []byte("1\n")); err != nil {
			return "", err
		}
		m.server = server
		owned := listener
		listener = nil
		go func() {
			err := server.ServeTLS(owned, "", "")
			if err != nil && !errors.Is(err, http.ErrServerClosed) {
				slog.Error("public calendar listener stopped", "error", err)
			}
			m.mu.Lock()
			if m.server == server {
				m.server = nil
			}
			m.mu.Unlock()
		}()
	}
	_, port, _ := net.SplitHostPort(m.address)
	return "https://" + net.JoinHostPort(m.host, port), nil
}

func (m *Manager) Run(ctx context.Context) {
	check := func() {
		if _, err := os.Stat(filepath.Join(m.dir, "enabled")); err == nil {
			if _, err = m.Ensure(ctx); err != nil && ctx.Err() == nil {
				slog.Error("public calendar HTTPS unavailable", "error", err)
			}
		}
	}
	check()
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			m.mu.Lock()
			server := m.server
			m.mu.Unlock()
			if server != nil {
				shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if err := server.Shutdown(shutdown); err != nil {
					server.Close()
				}
			}
			return
		case <-ticker.C:
			check()
		}
	}
}

func (m *Manager) accountKey() (*ecdsa.PrivateKey, error) {
	path := filepath.Join(m.dir, "account.pem")
	data, err := os.ReadFile(path)
	if err == nil {
		block, _ := pem.Decode(data)
		if block == nil {
			return nil, errors.New("invalid ACME account key")
		}
		return x509.ParseECPrivateKey(block.Bytes)
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	err = atomicWrite(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}))
	return key, err
}

func (m *Manager) issue(ctx context.Context) ([]byte, error) {
	// Never stop another service to take the HTTP-01 port.
	listener, err := net.Listen("tcp", ":80")
	if err != nil {
		return nil, fmt.Errorf("ACME HTTP-01 requires free inbound TCP port 80: %w", err)
	}
	defer listener.Close()
	key, err := m.accountKey()
	if err != nil {
		return nil, err
	}
	client := &acme.Client{Key: key, DirectoryURL: acme.LetsEncryptURL, HTTPClient: &http.Client{Timeout: 30 * time.Second}, UserAgent: "Yggvion calendar sharing"}
	if _, err = client.Register(ctx, &acme.Account{}, acme.AcceptTOS); err != nil && !errors.Is(err, acme.ErrAccountAlreadyExists) {
		return nil, err
	}
	order, err := client.AuthorizeOrder(ctx, []acme.AuthzID{{Type: "ip", Value: m.host}}, acme.WithOrderIssuanceProfile("shortlived"))
	if err != nil {
		return nil, err
	}
	var challengeMu sync.RWMutex
	path, response := "", ""
	challengeServer := &http.Server{ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, MaxHeaderBytes: 8 << 10, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		challengeMu.RLock()
		defer challengeMu.RUnlock()
		if r.Method != "GET" || path == "" || r.URL.Path != path {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Cache-Control", "no-store")
		w.Write([]byte(response))
	})}
	defer challengeServer.Close()
	go func() {
		if err := challengeServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			slog.Error("ACME challenge listener stopped", "error", err)
		}
	}()
	for _, uri := range order.AuthzURLs {
		authorization, err := client.GetAuthorization(ctx, uri)
		if err != nil {
			return nil, err
		}
		if authorization.Status == acme.StatusValid {
			continue
		}
		var challenge *acme.Challenge
		for _, candidate := range authorization.Challenges {
			if candidate.Type == "http-01" {
				challenge = candidate
				break
			}
		}
		if challenge == nil {
			return nil, errors.New("CA did not offer HTTP-01 validation")
		}
		answer, err := client.HTTP01ChallengeResponse(challenge.Token)
		if err != nil {
			return nil, err
		}
		challengeMu.Lock()
		path = client.HTTP01ChallengePath(challenge.Token)
		response = answer
		challengeMu.Unlock()
		if _, err = client.Accept(ctx, challenge); err != nil {
			return nil, err
		}
		if _, err = client.WaitAuthorization(ctx, uri); err != nil {
			return nil, err
		}
	}
	order, err = client.WaitOrder(ctx, order.URI)
	if err != nil {
		return nil, err
	}
	tlsKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{IPAddresses: []net.IP{net.ParseIP(m.host)}}, tlsKey)
	if err != nil {
		return nil, err
	}
	chain, _, err := client.CreateOrderCert(ctx, order.FinalizeURL, csr, true)
	if err != nil {
		return nil, err
	}
	var data []byte
	for _, certificate := range chain {
		data = append(data, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate})...)
	}
	der, err := x509.MarshalECPrivateKey(tlsKey)
	if err != nil {
		return nil, err
	}
	data = append(data, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})...)
	return data, nil
}
