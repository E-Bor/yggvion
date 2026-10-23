package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"
)

const DropboxRedirect = "yggvion://oauth/dropbox"
const DropboxDesktopRedirect = "http://127.0.0.1:43827/dropbox"
const dropboxChunk = 8 << 20

var dropboxAppKey = regexp.MustCompile(`^[a-zA-Z0-9_-]{5,128}$`)
var dropboxVerifier = regexp.MustCompile(`^[a-zA-Z0-9._~-]{43,128}$`)

// The HTTP transport is private and fixed to Dropbox hosts. OAuth credentials
// never appear in an API response, a redirect, or an error message.
func dropboxHTTP() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = 30 * time.Second
	return &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

type dropboxToken struct {
	Access  string `json:"access_token"`
	Refresh string `json:"refresh_token"`
}

func requestDropboxToken(ctx context.Context, client *http.Client, form url.Values) (dropboxToken, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var token dropboxToken
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.dropboxapi.com/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return token, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := client.Do(req)
	if err != nil {
		return token, errors.New("Dropbox authorization unavailable")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return token, errors.New("Dropbox authorization rejected")
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&token); err != nil || token.Access == "" || len(token.Access) > 16384 || strings.ContainsAny(token.Access, "\r\n") {
		return dropboxToken{}, errors.New("invalid Dropbox token response")
	}
	return token, nil
}

// ConfigureDropbox exchanges a one-time code, then validates access before
// replacing the existing destination. Only the refresh token is persisted (0600).
func (m *Manager) ConfigureDropbox(ctx context.Context, appKey, code, verifier, redirect string) error {
	return m.configureDropbox(ctx, dropboxHTTP(), appKey, code, verifier, redirect)
}

func (m *Manager) configureDropbox(ctx context.Context, client *http.Client, appKey, code, verifier, redirect string) error {
	if (redirect != DropboxRedirect && redirect != DropboxDesktopRedirect) || !dropboxAppKey.MatchString(appKey) || len(code) == 0 || len(code) > 4096 || !dropboxVerifier.MatchString(verifier) {
		return errors.New("invalid Dropbox authorization")
	}
	token, err := requestDropboxToken(ctx, client, url.Values{
		"grant_type": {"authorization_code"}, "client_id": {appKey},
		"code": {code}, "code_verifier": {verifier}, "redirect_uri": {redirect},
	})
	if err != nil {
		return err
	}
	if token.Refresh == "" || len(token.Refresh) > 16384 {
		return errors.New("Dropbox offline access required")
	}
	c := RemoteConfig{Kind: "dropbox", Prefix: "/", DropboxAppKey: appKey, Secret: token.Refresh}
	remote := &dropboxRemote{client: client, c: c, token: token.Access}
	defer remote.close()
	if _, err = remote.list(ctx); err != nil {
		return err
	}
	m.remoteMu.Lock()
	defer m.remoteMu.Unlock()
	return m.saveRemote(c)
}

type dropboxBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *dropboxBody) Close() error {
	defer b.cancel()
	return b.ReadCloser.Close()
}

type dropboxRemote struct {
	client *http.Client
	c      RemoteConfig
	token  string
}

func openDropbox(ctx context.Context, c RemoteConfig) (*dropboxRemote, error) {
	client := dropboxHTTP()
	token, err := requestDropboxToken(ctx, client, url.Values{
		"grant_type": {"refresh_token"}, "refresh_token": {c.Secret}, "client_id": {c.DropboxAppKey},
	})
	if err != nil {
		return nil, err
	}
	return &dropboxRemote{client: client, c: c, token: token.Access}, nil
}

func (d *dropboxRemote) close() { d.client.CloseIdleConnections() }

func (d *dropboxRemote) call(ctx context.Context, endpoint string, args any, content io.Reader) (io.ReadCloser, error) {
	timeout := 2 * time.Minute
	if endpoint == "files/download" {
		timeout = 2 * time.Hour
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	keep := false
	defer func() {
		if !keep {
			cancel()
		}
	}()
	data, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	host := "https://api.dropboxapi.com/2/"
	body := io.Reader(bytes.NewReader(data))
	if content != nil {
		host = "https://content.dropboxapi.com/2/"
		body = content
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+endpoint, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+d.token)
	if content == nil {
		req.Header.Set("Content-Type", "application/json")
	} else {
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("Dropbox-API-Arg", string(data))
	}
	res, err := d.client.Do(req)
	if err != nil {
		return nil, errors.New("Dropbox request failed")
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, fmt.Errorf("Dropbox request rejected (%d)", res.StatusCode)
	}
	keep = true
	return &dropboxBody{ReadCloser: res.Body, cancel: cancel}, nil
}

func (d *dropboxRemote) json(ctx context.Context, endpoint string, args any, content io.Reader, out any) error {
	body, err := d.call(ctx, endpoint, args, content)
	if err != nil {
		return err
	}
	defer body.Close()
	if out == nil {
		_, err = io.Copy(io.Discard, io.LimitReader(body, 64<<10))
		return err
	}
	return json.NewDecoder(io.LimitReader(body, 8<<20)).Decode(out)
}

func dropboxFileName(name string) bool {
	return (strings.HasSuffix(name, ".json") && validID.MatchString(strings.TrimSuffix(name, ".json"))) ||
		(strings.HasSuffix(name, ".yggbackup") && validID.MatchString(strings.TrimSuffix(name, ".yggbackup")))
}

func (d *dropboxRemote) put(ctx context.Context, name string, source io.Reader, size int64) error {
	if !dropboxFileName(name) || size < 0 || size > 100<<30 {
		return errors.New("invalid Dropbox backup")
	}
	commit := map[string]any{"path": path.Join(d.c.Prefix, name), "mode": "overwrite", "autorename": false, "mute": true}
	// Keep memory bounded to one chunk, including for archives larger than 150 MiB.
	var session struct {
		ID string `json:"session_id"`
	}
	if err := d.json(ctx, "files/upload_session/start", map[string]bool{"close": false}, bytes.NewReader(nil), &session); err != nil {
		return err
	}
	if session.ID == "" {
		return errors.New("invalid Dropbox upload session")
	}
	buf := make([]byte, dropboxChunk)
	var offset int64
	for offset < size {
		length := min(int64(len(buf)), size-offset)
		n, err := io.ReadFull(source, buf[:length])
		if err != nil {
			return errors.New("incomplete backup source")
		}
		args := map[string]any{"cursor": map[string]any{"session_id": session.ID, "offset": offset}, "close": false}
		if err = d.json(ctx, "files/upload_session/append_v2", args, bytes.NewReader(buf[:n]), nil); err != nil {
			return err
		}
		offset += int64(n)
	}
	var tail [1]byte
	if n, err := source.Read(tail[:]); n != 0 || err != io.EOF {
		return errors.New("backup size changed")
	}
	return d.json(ctx, "files/upload_session/finish", map[string]any{
		"cursor": map[string]any{"session_id": session.ID, "offset": offset}, "commit": commit,
	}, bytes.NewReader(nil), nil)
}

func (d *dropboxRemote) get(ctx context.Context, name string) (io.ReadCloser, error) {
	if !dropboxFileName(name) {
		return nil, errors.New("invalid Dropbox backup name")
	}
	return d.call(ctx, "files/download", map[string]string{"path": path.Join(d.c.Prefix, name)}, bytes.NewReader(nil))
}

func (d *dropboxRemote) list(ctx context.Context) ([]string, error) {
	out := []string{}
	endpoint := "files/list_folder"
	args := map[string]any{"path": strings.TrimSuffix(d.c.Prefix, "/"), "recursive": false, "limit": 2000}
	seen := make(map[string]bool)
	for page := 0; page < 100; page++ {
		var result struct {
			Entries []struct {
				Tag  string `json:".tag"`
				Name string `json:"name"`
			} `json:"entries"`
			Cursor string `json:"cursor"`
			More   bool   `json:"has_more"`
		}
		if err := d.json(ctx, endpoint, args, nil, &result); err != nil {
			return nil, err
		}
		for _, entry := range result.Entries {
			if entry.Tag == "file" && strings.HasSuffix(entry.Name, ".json") && dropboxFileName(entry.Name) {
				out = append(out, entry.Name)
			}
		}
		if len(out) > 10000 {
			return nil, errors.New("too many Dropbox backup entries")
		}
		if !result.More {
			return out, nil
		}
		if result.Cursor == "" || seen[result.Cursor] {
			return nil, errors.New("invalid Dropbox pagination")
		}
		seen[result.Cursor] = true
		endpoint = "files/list_folder/continue"
		args = map[string]any{"cursor": result.Cursor}
	}
	return nil, errors.New("too many Dropbox backup entries")
}
