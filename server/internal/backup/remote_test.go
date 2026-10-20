package backup

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

func TestSFTPCopyAndRecoveryRequireVerifiedHost(t *testing.T) {
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{PasswordCallback: func(meta ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
		if meta.User() == "backup" && string(password) == "synthetic-password" {
			return nil, nil
		}
		return nil, errors.New("denied")
	}}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				transport, channels, requests, err := ssh.NewServerConn(conn, config)
				if err != nil {
					conn.Close()
					return
				}
				defer transport.Close()
				go ssh.DiscardRequests(requests)
				for channel := range channels {
					if channel.ChannelType() != "session" {
						channel.Reject(ssh.UnknownChannelType, "session only")
						continue
					}
					stream, reqs, err := channel.Accept()
					if err != nil {
						return
					}
					go func() {
						for req := range reqs {
							if req.Type == "subsystem" {
								req.Reply(true, nil)
								server, err := sftp.NewServer(stream)
								if err == nil {
									_ = server.Serve()
									server.Close()
								}
								return
							}
							req.Reply(false, nil)
						}
					}()
				}
			}()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	m, device, _ := fixture(t)
	applyNote(t, m, device, "external backup", 0)
	c := RemoteConfig{Kind: "sftp", Endpoint: listener.Addr().String(), Username: "backup", Secret: "synthetic-password", Prefix: t.TempDir() + "/copies", Fingerprint: ssh.FingerprintSHA256(signer.PublicKey())}
	bad := c
	bad.Fingerprint = "SHA256:" + strings.Repeat("A", 43)
	if err = m.ConfigureRemote(ctx, bad); err == nil {
		t.Fatal("untrusted host accepted")
	}
	if err = m.ConfigureRemote(ctx, c); err != nil {
		t.Fatal(err)
	}
	entry, err := m.Create(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	if err = m.Replicate(ctx, entry); err != nil {
		t.Fatal(err)
	}
	remote, err := m.RemoteList(ctx)
	if err != nil || len(remote) != 1 {
		t.Fatal("remote list", err, remote)
	}
	if err = m.Delete(entry.ID); err != nil {
		t.Fatal(err)
	}
	if err = m.FetchRemote(ctx, entry.ID, ""); err != nil {
		t.Fatal(err)
	}
	local, err := m.List()
	if err != nil || len(local) != 1 {
		t.Fatal("not recovered", err)
	}
	path, _ := m.Path(local[0].ID)
	if err = m.Restore(ctx, path, ""); err != nil {
		t.Fatal(err)
	}
}

func TestRemoteRejectsPlaintextAndUnsafeConfiguration(t *testing.T) {
	for _, c := range []RemoteConfig{
		{Kind: "s3", Endpoint: "http://storage.example", Bucket: "backups", Prefix: "app", Username: "key", Secret: "secret"},
		{Kind: "s3", Endpoint: "https://user:password@storage.example", Bucket: "backups", Prefix: "app", Username: "key", Secret: "secret"},
		{Kind: "sftp", Endpoint: "localhost:22", Prefix: "../escape", Username: "backup", Secret: "secret", Fingerprint: "SHA256:abc"},
		{Kind: "sftp", Endpoint: "localhost:22", Prefix: "/backups", Username: "backup", Secret: "secret"},
	} {
		if validateRemote(c) == nil {
			t.Fatalf("accepted unsafe config: %s", c.Kind)
		}
	}
}
