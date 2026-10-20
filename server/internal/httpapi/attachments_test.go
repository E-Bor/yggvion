package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// Generate large request bodies without allocating an entire attachment in memory.
type attachmentZeros struct{}

func (attachmentZeros) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

func TestAttachmentSizeLimit(t *testing.T) {
	const limit int64 = 300 << 20
	for _, tc := range []struct {
		name          string
		size          int64
		contentLength int64
		status        int
	}{
		{"exactly 300 MiB", limit, limit, http.StatusCreated},
		{"known length exceeds limit by one byte", limit + 1, limit + 1, http.StatusRequestEntityTooLarge},
		{"stream exceeds limit by one byte", limit + 1, -1, http.StatusRequestEntityTooLarge},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, _, token := setup(t)
			files := t.TempDir()
			server := httptest.NewServer(New(s, strings.Repeat("test", 8), files).Handler())
			defer server.Close()
			client := server.Client()
			transport := client.Transport.(*http.Transport).Clone()
			transport.ExpectContinueTimeout = time.Second
			client.Transport = transport
			defer transport.CloseIdleConnections()
			id := strings.Repeat("0", 64)
			if tc.status == http.StatusCreated {
				hash := sha256.New()
				if _, err := io.Copy(hash, io.LimitReader(attachmentZeros{}, tc.size)); err != nil {
					t.Fatal(err)
				}
				id = hex.EncodeToString(hash.Sum(nil))
			}
			url := server.URL + "/api/v1/attachments/" + id
			req, err := http.NewRequest(http.MethodPut, url, io.LimitReader(attachmentZeros{}, tc.size))
			if err != nil {
				t.Fatal(err)
			}
			req.ContentLength = tc.contentLength
			req.Header.Set("Authorization", "Bearer "+token)
			req.Header.Set("Content-Type", "application/octet-stream")
			// A known oversized body must be rejected before transmission starts.
			req.Header.Set("Expect", "100-continue")
			response, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			if err != nil || response.StatusCode != tc.status {
				t.Fatalf("upload: status=%d body=%s error=%v", response.StatusCode, body, err)
			}
			if tc.status != http.StatusCreated {
				var result map[string]string
				if err = json.Unmarshal(body, &result); err != nil || result["error"] != "file_too_large_or_incomplete" {
					t.Fatalf("unexpected rejection: %s, %v", body, err)
				}
				entries, err := os.ReadDir(files)
				if err != nil || len(entries) != 0 {
					t.Fatalf("rejected upload left files: %v, %v", entries, err)
				}
				var count int
				if err = s.DB.QueryRow("SELECT count(*) FROM attachments").Scan(&count); err != nil || count != 0 {
					t.Fatalf("rejected upload left metadata: %d, %v", count, err)
				}
				return
			}
			var size int64
			if err = s.DB.QueryRow("SELECT size FROM attachments WHERE id=?", id).Scan(&size); err != nil || size != tc.size {
				t.Fatalf("stored size=%d, error=%v", size, err)
			}
			req, err = http.NewRequest(http.MethodGet, url, nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Authorization", "Bearer "+token)
			response, err = client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			hash := sha256.New()
			n, err := io.Copy(hash, response.Body)
			if err != nil || response.StatusCode != http.StatusOK || n != tc.size || hex.EncodeToString(hash.Sum(nil)) != id {
				t.Fatalf("download: status=%d bytes=%d error=%v", response.StatusCode, n, err)
			}
		})
	}
}
