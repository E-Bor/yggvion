// Package identity manages an app-scoped CA and automatically renewed server
// certificates. The CA is transferred only over verified SSH or an invitation.
package identity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"log/slog"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Manager struct {
	mu        sync.RWMutex
	dir, host string
	ca        *x509.Certificate
	key       *ecdsa.PrivateKey
	cert      *tls.Certificate
	CAPEM     []byte
}

func atomicFile(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".identity-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func Open(dir, host string, now time.Time) (*Manager, error) {
	if net.ParseIP(host) == nil {
		return nil, errors.New("TLS host must be a literal IPv4 or IPv6 address")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	m := &Manager{dir: dir, host: host}
	caPath, keyPath := filepath.Join(dir, "ca.crt"), filepath.Join(dir, "ca.key")
	caPEM, err := os.ReadFile(caPath)
	if errors.Is(err, os.ErrNotExist) {
		if _, e := os.Stat(keyPath); e == nil {
			return nil, errors.New("CA certificate missing; refusing to replace existing identity")
		}
		key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if e != nil {
			return nil, e
		}
		serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if e != nil {
			return nil, e
		}
		template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Yggvion private CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(20, 0, 0), IsCA: true, BasicConstraintsValid: true, MaxPathLenZero: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
		der, e := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
		if e != nil {
			return nil, e
		}
		keyDER, e := x509.MarshalECPrivateKey(key)
		if e != nil {
			return nil, e
		}
		if e = atomicFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})); e != nil {
			return nil, e
		}
		caPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		if e = atomicFile(caPath, caPEM); e != nil {
			return nil, e
		}
	} else if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(caPEM)
	if block == nil {
		return nil, errors.New("invalid CA")
	}
	m.ca, err = x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}
	block, _ = pem.Decode(keyPEM)
	if block == nil {
		return nil, errors.New("invalid CA key")
	}
	m.key, err = x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	if !m.key.PublicKey.Equal(m.ca.PublicKey) || !m.ca.IsCA || now.After(m.ca.NotAfter.AddDate(-1, 0, 0)) {
		return nil, errors.New("CA invalid or near expiry; re-pairing required")
	}
	m.CAPEM = caPEM
	// The leaf key is short-lived and kept in memory; restart safely renews it.
	if err = m.Renew(now); err != nil {
		return nil, err
	}
	return m, nil
}

func (m *Manager) Renew(now time.Time) error {
	m.mu.RLock()
	current := m.cert
	m.mu.RUnlock()
	if current != nil && now.Before(current.Leaf.NotAfter.Add(-30*24*time.Hour)) {
		return nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Yggvion"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(90 * 24 * time.Hour), IPAddresses: []net.IP{net.ParseIP(m.host)}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, m.ca, &key.PublicKey, m.key)
	if err != nil {
		return err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return err
	}
	cert := &tls.Certificate{Certificate: [][]byte{der, m.ca.Raw}, PrivateKey: key, Leaf: leaf}
	m.mu.Lock()
	m.cert = cert
	m.mu.Unlock()
	return nil
}

func (m *Manager) Config() *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		m.mu.RLock()
		defer m.mu.RUnlock()
		return m.cert, nil
	}}
}

func (m *Manager) Run(ctx context.Context) {
	ticker := time.NewTicker(12 * time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if err := m.Renew(now); err != nil {
				slog.Error("certificate renewal failed", "error", err)
			}
		}
	}
}
