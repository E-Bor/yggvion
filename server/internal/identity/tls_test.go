package identity

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRenewalRetainsTrustAndEnforcesIdentity(t *testing.T) {
	now := time.Now()
	dir := t.TempDir()
	m, err := Open(dir, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}
	root := x509.NewCertPool()
	if !root.AppendCertsFromPEM(m.CAPEM) {
		t.Fatal("invalid CA")
	}
	old := m.cert.Leaf.SerialNumber.String()
	if err = m.Renew(now.Add(65 * 24 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	if old == m.cert.Leaf.SerialNumber.String() {
		t.Fatal("leaf not renewed")
	}
	if _, err = m.cert.Leaf.Verify(x509.VerifyOptions{Roots: root, DNSName: "127.0.0.1", CurrentTime: now.Add(66 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, err = m.cert.Leaf.Verify(x509.VerifyOptions{Roots: root, DNSName: "192.0.2.1", CurrentTime: now.Add(66 * 24 * time.Hour)}); err == nil {
		t.Fatal("wrong IP accepted")
	}
	reopened, err := Open(dir, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}
	if string(m.CAPEM) != string(reopened.CAPEM) {
		t.Fatal("CA replaced on restart")
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) }))
	server.TLS = reopened.Config()
	server.TLS.Certificates = []tls.Certificate{*reopened.cert}
	server.StartTLS()
	defer server.Close()
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: root, MinVersion: tls.VersionTLS13}}}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if string(body) != "ok" {
		t.Fatal("bad response")
	}
	untrusted := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: x509.NewCertPool(), MinVersion: tls.VersionTLS13}}}
	if response, err = untrusted.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("untrusted CA accepted")
	}
}
