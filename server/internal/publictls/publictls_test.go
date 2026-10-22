package publictls

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testCertificate(t *testing.T) ([]byte, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	root := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(7 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	root, err = x509.ParseCertificate(rootDER)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: now.Add(-time.Hour), NotAfter: now.Add(4 * 24 * time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, root, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	data = append(data, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private})...)
	roots := x509.NewCertPool()
	roots.AddCert(root)
	return data, roots
}

func TestCertificateRequiresTrustedChainCorrectIPAndValidity(t *testing.T) {
	data, roots := testCertificate(t)
	if _, err := certificatePair(data, "127.0.0.1", time.Now(), roots); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct {
		host  string
		now   time.Time
		roots *x509.CertPool
	}{
		{"127.0.0.2", time.Now(), roots},
		{"127.0.0.1", time.Now().Add(5 * 24 * time.Hour), roots},
		{"127.0.0.1", time.Now(), x509.NewCertPool()},
	} {
		if _, err := certificatePair(data, check.host, check.now, check.roots); err == nil {
			t.Fatal("invalid certificate accepted", check.host, check.now)
		}
	}
}

func TestPublicIdentityPersistsPrivatelyAndRejectsInvalidHosts(t *testing.T) {
	dir := t.TempDir()
	m := &Manager{dir: dir}
	first, err := m.accountKey()
	if err != nil {
		t.Fatal(err)
	}
	second, err := m.accountKey()
	if err != nil || !first.Equal(second) {
		t.Fatal("account changed", err)
	}
	stat, err := os.Stat(filepath.Join(dir, "account.pem"))
	if err != nil || stat.Mode().Perm() != 0600 {
		t.Fatal("account permissions", stat, err)
	}
	for _, host := range []string{"localhost", "127.0.0.1", "10.0.0.1", "192.168.1.1", "::1", "fe80::1", "0.0.0.0"} {
		if _, err = New(context.Background(), dir, host, 8443, http.NotFoundHandler()); err == nil {
			t.Fatal("nonpublic host accepted", host)
		}
	}
	if _, err = New(context.Background(), dir, "203.0.113.10", 8443, http.NotFoundHandler()); err != nil {
		t.Fatal(err)
	}
}

func TestPublicListenerUsesSeparateHandlerAndStopsWithLifetime(t *testing.T) {
	data, roots := testCertificate(t)
	pair, err := certificatePair(data, "127.0.0.1", time.Now(), roots)
	if err != nil {
		t.Fatal(err)
	}
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	reserved.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := &Manager{dir: t.TempDir(), host: "127.0.0.1", address: address, handler: http.NotFoundHandler(), lifetime: ctx}
	m.certificate.Store(pair) // No external CA: this test exercises only the listener.
	base, err := m.Ensure(ctx)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}}, Timeout: 3 * time.Second}
	defer client.CloseIdleConnections()
	response, err := client.Get(base + "/api/v1/sync")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatal("unexpected public handler", response.StatusCode)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(6 * time.Second):
		t.Fatal("listener did not shut down")
	}
}

func TestOccupiedPortFailsBeforeIssuingCertificate(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	m := &Manager{dir: t.TempDir(), host: "127.0.0.1", address: listener.Addr().String(), handler: http.NotFoundHandler(), lifetime: context.Background()}
	if _, err = m.Ensure(context.Background()); err == nil {
		t.Fatal("occupied port accepted")
	}
	if _, err = os.Stat(filepath.Join(m.dir, "account.pem")); !os.IsNotExist(err) {
		t.Fatal("CA account should not be created")
	}
}
