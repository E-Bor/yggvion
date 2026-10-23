package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type dropboxTransport func(*http.Request) (*http.Response, error)

func (f dropboxTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func dropboxResponse(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestDropboxOAuthStoresOnlyRefreshAndPreservesDestinationOnFailure(t *testing.T) {
	m := &Manager{Dir: t.TempDir()}
	denied := false
	client := &http.Client{Transport: dropboxTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme != "https" || r.URL.Host != "api.dropboxapi.com" {
			t.Fatal("unexpected OAuth host")
		}
		switch r.URL.Path {
		case "/oauth2/token":
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.Form.Get("code_verifier") != strings.Repeat("v", 43) || r.Form.Get("client_id") != "test-app-key" || r.Form.Get("redirect_uri") != DropboxRedirect || r.Form.Get("client_secret") != "" {
				t.Fatal("wrong PKCE contract")
			}
			if denied {
				return dropboxResponse(400, `{"error":"secret-error-not-for-client"}`), nil
			}
			return dropboxResponse(200, `{"access_token":"synthetic-access","refresh_token":"synthetic-refresh"}`), nil
		case "/2/files/list_folder":
			if r.Header.Get("Authorization") != "Bearer synthetic-access" {
				t.Fatal("missing access token")
			}
			return dropboxResponse(200, `{"entries":[],"has_more":false}`), nil
		default:
			t.Fatal("unexpected OAuth request")
		}
		return nil, nil
	})}
	if err := m.configureDropbox(context.Background(), client, "test-app-key", "one-time-code", strings.Repeat("v", 43), DropboxRedirect); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(m.Dir, "remote.json")
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("synthetic-access")) || bytes.Contains(data, []byte("one-time-code")) || !bytes.Contains(data, []byte("synthetic-refresh")) {
		t.Fatal("unexpected persisted credentials")
	}
	info, _ := os.Stat(file)
	if info.Mode().Perm() != 0600 {
		t.Fatal("credentials readable by other users")
	}
	denied = true
	err = m.configureDropbox(context.Background(), client, "test-app-key", "bad-code", strings.Repeat("v", 43), DropboxRedirect)
	if err == nil || strings.Contains(err.Error(), "secret-error") {
		t.Fatal("failed OAuth leaked response or succeeded")
	}
	after, _ := os.ReadFile(file)
	if !bytes.Equal(after, data) {
		t.Fatal("failed OAuth replaced working destination")
	}
	for _, invalid := range []struct{ key, verifier string }{{"https://attacker.invalid", strings.Repeat("v", 43)}, {"test-app-key", "short"}} {
		if err = m.configureDropbox(context.Background(), client, invalid.key, "code", invalid.verifier, DropboxRedirect); err == nil {
			t.Fatal("invalid OAuth parameters accepted")
		}
	}
	if err = m.ConfigureRemote(context.Background(), RemoteConfig{Kind: "disabled"}); err != nil {
		t.Fatal(err)
	}
	after, _ = os.ReadFile(file)
	if bytes.Contains(after, []byte("synthetic-refresh")) {
		t.Fatal("disconnect retained refresh token")
	}
}

func TestDropboxChunkedUploadDownloadAndPagination(t *testing.T) {
	payload := bytes.Repeat([]byte("12345678"), (dropboxChunk/8)+7)
	var uploaded bytes.Buffer
	parts, lists := 0, 0
	finished := false
	d := &dropboxRemote{c: RemoteConfig{Prefix: "/"}, token: "access"}
	d.client = &http.Client{Transport: dropboxTransport(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "Bearer access" || r.URL.Scheme != "https" {
			t.Fatal("missing authorization/TLS")
		}
		var args map[string]any
		if value := r.Header.Get("Dropbox-API-Arg"); value != "" {
			if r.URL.Host != "content.dropboxapi.com" {
				t.Fatal("wrong content host")
			}
			if err := json.Unmarshal([]byte(value), &args); err != nil {
				t.Fatal(err)
			}
		}
		switch r.URL.Path {
		case "/2/files/upload_session/start":
			return dropboxResponse(200, `{"session_id":"test-session"}`), nil
		case "/2/files/upload_session/append_v2":
			cursor := args["cursor"].(map[string]any)
			if int(cursor["offset"].(float64)) != uploaded.Len() || cursor["session_id"] != "test-session" {
				t.Fatal("incorrect chunk offset")
			}
			data, _ := io.ReadAll(r.Body)
			if len(data) > dropboxChunk {
				t.Fatal("unbounded upload")
			}
			uploaded.Write(data)
			parts++
			return dropboxResponse(200, "null"), nil
		case "/2/files/upload_session/finish":
			if args["commit"].(map[string]any)["path"] != "/cccccccccccccccccccccccccccccccc.yggbackup" || int(args["cursor"].(map[string]any)["offset"].(float64)) != len(payload) {
				t.Fatal("wrong final commit")
			}
			finished = true
			return dropboxResponse(200, `{}`), nil
		case "/2/files/download":
			if args["path"] != "/cccccccccccccccccccccccccccccccc.yggbackup" {
				t.Fatal("wrong download path")
			}
			return dropboxResponse(200, uploaded.String()), nil
		case "/2/files/list_folder":
			lists++
			return dropboxResponse(200, `{"entries":[{".tag":"file","name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"},{".tag":"folder","name":"folder.json"},{".tag":"file","name":"../escape.json"}],"has_more":true,"cursor":"next"}`), nil
		case "/2/files/list_folder/continue":
			lists++
			return dropboxResponse(200, `{"entries":[{".tag":"file","name":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"}],"has_more":false}`), nil
		default:
			t.Fatal("unexpected Dropbox request")
		}
		return nil, nil
	})}
	ctx := context.Background()
	if err := d.put(ctx, "cccccccccccccccccccccccccccccccc.yggbackup", bytes.NewReader(payload), int64(len(payload))); err != nil {
		t.Fatal(err)
	}
	if !finished || parts != 2 || !bytes.Equal(uploaded.Bytes(), payload) {
		t.Fatal("archive not uploaded intact")
	}
	body, err := d.get(ctx, "cccccccccccccccccccccccccccccccc.yggbackup")
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(body)
	body.Close()
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("archive not downloaded intact")
	}
	names, err := d.list(ctx)
	if err != nil || lists != 2 || strings.Join(names, ",") != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json" {
		t.Fatal(names, err)
	}
	if err = d.put(ctx, "../escape.yggbackup", bytes.NewReader(nil), 0); err == nil {
		t.Fatal("traversal accepted")
	}
}

func TestDropboxFailureAndShortSourceNeverCommitArchive(t *testing.T) {
	committed := false
	d := &dropboxRemote{c: RemoteConfig{Prefix: "/"}, token: "access", client: &http.Client{Transport: dropboxTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/2/files/upload_session/finish" {
			committed = true
		}
		return dropboxResponse(200, `{"session_id":"test"}`), nil
	})}}
	if err := d.put(context.Background(), "dddddddddddddddddddddddddddddddd.yggbackup", strings.NewReader("short"), 10); err == nil || committed {
		t.Fatal("partial archive committed")
	}
	d.client.Transport = dropboxTransport(func(r *http.Request) (*http.Response, error) { return dropboxResponse(401, "sensitive body"), nil })
	if _, err := d.list(context.Background()); err == nil || strings.Contains(err.Error(), "sensitive") {
		t.Fatal("Dropbox failure not handled safely")
	}
}
