package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

type RemoteConfig struct {
	Kind          string `json:"kind"` // disabled, s3, sftp, dropbox
	DropboxAppKey string `json:"dropbox_app_key,omitempty"`
	Endpoint      string `json:"endpoint"`
	Bucket        string `json:"bucket"`
	Region        string `json:"region"`
	Prefix        string `json:"prefix"`
	Username      string `json:"username"`
	Secret        string `json:"secret,omitempty"`
	PrivateKey    string `json:"private_key,omitempty"`
	Fingerprint   string `json:"fingerprint"`
}

func validateRemote(c RemoteConfig) error {
	if c.Kind == "disabled" {
		return nil
	}
	if c.Prefix == "" || path.Clean(c.Prefix) != c.Prefix || strings.Contains(c.Prefix, "..") || len(c.Prefix) > 500 {
		return errors.New("invalid prefix")
	}
	if c.Kind == "s3" {
		u, err := url.Parse(c.Endpoint)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || c.Bucket == "" || c.Username == "" || c.Secret == "" {
			return errors.New("invalid S3 configuration")
		}
	} else if c.Kind == "dropbox" {
		if !dropboxAppKey.MatchString(c.DropboxAppKey) || c.Secret == "" || len(c.Secret) > 16384 || c.Prefix != "/" {
			return errors.New("invalid Dropbox configuration")
		}
	} else if c.Kind == "sftp" {
		host, port, err := net.SplitHostPort(c.Endpoint)
		if err != nil || host == "" || port == "" || c.Username == "" || (!strings.HasPrefix(c.Fingerprint, "SHA256:")) || (c.Secret == "" && c.PrivateKey == "") || !strings.HasPrefix(c.Prefix, "/") {
			return errors.New("invalid SFTP configuration")
		}
	} else {
		return errors.New("unknown remote kind")
	}
	return nil
}
func (m *Manager) RemoteConfig() (RemoteConfig, error) {
	b, err := os.ReadFile(filepath.Join(m.Dir, "remote.json"))
	if os.IsNotExist(err) {
		return RemoteConfig{Kind: "disabled"}, nil
	}
	if err != nil {
		return RemoteConfig{}, err
	}
	var c RemoteConfig
	err = json.Unmarshal(b, &c)
	return c, err
}
func (m *Manager) ConfigureRemote(ctx context.Context, c RemoteConfig) error {
	m.remoteMu.Lock()
	defer m.remoteMu.Unlock()
	old, err := m.RemoteConfig()
	if err != nil {
		return err
	}
	// Empty fields preserve credentials only for the same destination.
	if old.Kind == c.Kind && old.Endpoint == c.Endpoint && old.Username == c.Username && old.Bucket == c.Bucket && old.DropboxAppKey == c.DropboxAppKey {
		if c.Secret == "" {
			c.Secret = old.Secret
		}
		if c.PrivateKey == "" {
			c.PrivateKey = old.PrivateKey
		}
	}
	if err = validateRemote(c); err != nil {
		return err
	}
	if c.Kind != "disabled" {
		remote, e := openRemote(ctx, c)
		if e != nil {
			return e
		}
		_, err = remote.list(ctx)
		remote.close()
		if err != nil {
			return err
		}
	}
	if c.Kind == "disabled" {
		c = RemoteConfig{Kind: "disabled"}
	}
	return m.saveRemote(c)
}

func (m *Manager) saveRemote(c RemoteConfig) error {
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(m.Dir, "remote.json"), b)
}

type remoteStore interface {
	put(context.Context, string, io.Reader, int64) error
	get(context.Context, string) (io.ReadCloser, error)
	list(context.Context) ([]string, error)
	close()
}
type s3Remote struct {
	client *minio.Client
	c      RemoteConfig
}

func (s *s3Remote) put(ctx context.Context, name string, r io.Reader, size int64) error {
	_, err := s.client.PutObject(ctx, s.c.Bucket, path.Join(s.c.Prefix, name), r, size, minio.PutObjectOptions{ContentType: "application/octet-stream"})
	return err
}
func (s *s3Remote) get(ctx context.Context, name string) (io.ReadCloser, error) {
	return s.client.GetObject(ctx, s.c.Bucket, path.Join(s.c.Prefix, name), minio.GetObjectOptions{})
}
func (s *s3Remote) list(ctx context.Context) ([]string, error) {
	out := []string{}
	for item := range s.client.ListObjects(ctx, s.c.Bucket, minio.ListObjectsOptions{Prefix: s.c.Prefix + "/", Recursive: false}) {
		if item.Err != nil {
			return nil, item.Err
		}
		name := strings.TrimPrefix(item.Key, s.c.Prefix+"/")
		if validID.MatchString(strings.TrimSuffix(name, ".json")) && strings.HasSuffix(name, ".json") {
			out = append(out, name)
		}
		if len(out) > 10000 {
			return nil, errors.New("too many remote backups")
		}
	}
	return out, nil
}
func (s *s3Remote) close() {}

type sftpRemote struct {
	client *sftp.Client
	ssh    *ssh.Client
	c      RemoteConfig
	cancel context.CancelFunc
}

func (s *sftpRemote) close() { s.cancel(); s.client.Close(); s.ssh.Close() }
func (s *sftpRemote) put(ctx context.Context, name string, r io.Reader, size int64) error {
	if err := s.client.MkdirAll(s.c.Prefix); err != nil {
		return err
	}
	target := path.Join(s.c.Prefix, name)
	tmp := target + ".partial"
	f, err := s.client.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC)
	if err != nil {
		return err
	}
	n, err := copyContext(ctx, f, r)
	closeErr := f.Close()
	if err != nil || n != size {
		_ = s.client.Remove(tmp)
		if err != nil {
			return err
		}
		return io.ErrUnexpectedEOF
	}
	if closeErr != nil {
		return closeErr
	}
	return s.client.PosixRename(tmp, target)
}
func (s *sftpRemote) get(_ context.Context, name string) (io.ReadCloser, error) {
	return s.client.Open(path.Join(s.c.Prefix, name))
}
func (s *sftpRemote) list(ctx context.Context) ([]string, error) {
	files, err := s.client.ReadDirContext(ctx, s.c.Prefix)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, f := range files {
		if f.Mode().IsRegular() && strings.HasSuffix(f.Name(), ".json") && validID.MatchString(strings.TrimSuffix(f.Name(), ".json")) {
			out = append(out, f.Name())
		}
	}
	return out, nil
}
func openRemote(ctx context.Context, c RemoteConfig) (remoteStore, error) {
	if err := validateRemote(c); err != nil {
		return nil, err
	}
	if c.Kind == "dropbox" {
		return openDropbox(ctx, c)
	}
	if c.Kind == "s3" {
		u, _ := url.Parse(c.Endpoint)
		client, err := minio.New(u.Host, &minio.Options{Creds: credentials.NewStaticV4(c.Username, c.Secret, ""), Secure: true, Region: c.Region})
		if err != nil {
			return nil, err
		}
		return &s3Remote{client: client, c: c}, nil
	}
	if c.Kind != "sftp" {
		return nil, errors.New("remote disabled")
	}
	auth := []ssh.AuthMethod{}
	if c.PrivateKey != "" {
		signer, err := ssh.ParsePrivateKey([]byte(c.PrivateKey))
		if err != nil && c.Secret != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(c.PrivateKey), []byte(c.Secret))
		}
		if err != nil {
			return nil, err
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if c.Secret != "" {
		auth = append(auth, ssh.Password(c.Secret))
	}
	conn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, "tcp", c.Endpoint)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	transport, channels, requests, err := ssh.NewClientConn(conn, c.Endpoint, &ssh.ClientConfig{User: c.Username, Auth: auth, HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
		if ssh.FingerprintSHA256(key) != c.Fingerprint {
			return errors.New("SFTP host key mismatch")
		}
		return nil
	}})
	if err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	client := ssh.NewClient(transport, channels, requests)
	files, err := sftp.NewClient(client)
	if err != nil {
		client.Close()
		return nil, err
	}
	life, cancel := context.WithCancel(ctx)
	go func() { <-life.Done(); client.Close() }()
	return &sftpRemote{client: files, ssh: client, c: c, cancel: cancel}, nil
}
func (m *Manager) Replicate(ctx context.Context, entry Entry) error {
	c, err := m.RemoteConfig()
	if err != nil || c.Kind == "disabled" {
		return err
	}
	remote, err := openRemote(ctx, c)
	if err != nil {
		return err
	}
	defer remote.close()
	filePath, _ := m.Path(entry.ID)
	f, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = remote.put(ctx, entry.ID+".yggbackup", f, entry.Bytes); err != nil {
		return err
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	return remote.put(ctx, entry.ID+".json", bytes.NewReader(data), int64(len(data)))
}
func (m *Manager) RemoteList(ctx context.Context) ([]Entry, error) {
	c, err := m.RemoteConfig()
	if err != nil {
		return nil, err
	}
	remote, err := openRemote(ctx, c)
	if err != nil {
		return nil, err
	}
	defer remote.close()
	names, err := remote.list(ctx)
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	for _, name := range names {
		f, err := remote.get(ctx, name)
		if err != nil {
			return nil, err
		}
		data, err := io.ReadAll(io.LimitReader(f, 16<<10))
		f.Close()
		if err != nil {
			return nil, err
		}
		var entry Entry
		if err = json.Unmarshal(data, &entry); err != nil {
			return nil, err
		}
		if entry.ID+".json" != name {
			return nil, errors.New("invalid remote metadata")
		}
		out = append(out, entry)
	}
	return out, nil
}
func (m *Manager) FetchRemote(ctx context.Context, id string) error {
	if !validID.MatchString(id) {
		return errors.New("invalid id")
	}
	c, err := m.RemoteConfig()
	if err != nil {
		return err
	}
	remote, err := openRemote(ctx, c)
	if err != nil {
		return err
	}
	defer remote.close()
	source, err := remote.get(ctx, id+".yggbackup")
	if err != nil {
		return err
	}
	defer source.Close()
	tmp, err := os.CreateTemp(m.Dir, ".remote-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	n, err := m.CopyWithReserve(ctx, tmp, io.LimitReader(source, MaxImportBytes+1))
	if err != nil {
		return err
	}
	if n > 100<<30 {
		return errors.New("remote backup too large")
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	_, err = m.Import(ctx, tmp.Name())
	return err
}
