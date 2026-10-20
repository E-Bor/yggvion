package backup

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"filippo.io/age"
	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

func fixture(t *testing.T) (*Manager, string, string) {
	t.Helper()
	dir := t.TempDir()
	s, err := store.Open(filepath.Join(dir, "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	files := filepath.Join(dir, "attachments")
	if err = os.MkdirAll(files, 0700); err != nil {
		t.Fatal(err)
	}
	m, err := Open(s, filepath.Join(dir, "backups"), files, &sync.RWMutex{})
	if err != nil {
		t.Fatal(err)
	}
	id, token, err := s.Pair(context.Background(), "test device")
	if err != nil {
		t.Fatal(err)
	}
	return m, id, token
}

func TestRejectsCompressedPaddingAndAdditionalGzipMembers(t *testing.T) {
	m, _, _ := fixture(t)
	for _, extraMember := range []bool{false, true} {
		t.Run(fmt.Sprint(extraMember), func(t *testing.T) {
			var out bytes.Buffer
			encrypted, err := age.Encrypt(&out, m.identity.Recipient())
			if err != nil {
				t.Fatal(err)
			}
			gz := gzip.NewWriter(encrypted)
			tarWriter := tar.NewWriter(gz)
			snapshot, _ := json.Marshal(store.Snapshot{Format: 1, Created: time.Now().UTC()})
			if err = add(context.Background(), tarWriter, "snapshot.json", int64(len(snapshot)), bytes.NewReader(snapshot)); err != nil {
				t.Fatal(err)
			}
			if err = tarWriter.Close(); err != nil {
				t.Fatal(err)
			}
			if extraMember {
				if err = gz.Close(); err != nil {
					t.Fatal(err)
				}
				gz = gzip.NewWriter(encrypted)
			}
			if _, err = gz.Write(bytes.Repeat([]byte{0}, 1<<20)); err != nil {
				t.Fatal(err)
			}
			if err = gz.Close(); err != nil {
				t.Fatal(err)
			}
			if err = encrypted.Close(); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "padding.yggbackup")
			if err = os.WriteFile(path, out.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			if err = m.Restore(context.Background(), path, ""); err == nil {
				t.Fatal("unexpected compressed content accepted")
			}
		})
	}
}

func TestAttachmentBudgetLimitsUncompressedSize(t *testing.T) {
	entries := []store.Attachment{}
	for i := range 342 {
		entries = append(entries, store.Attachment{ID: fmt.Sprintf("%064x", i), Size: 300 << 20})
	}
	if _, err := attachmentIndex(entries[:341]); err != nil {
		t.Fatal(err)
	}
	if _, err := attachmentIndex(entries); err == nil {
		t.Fatal("unbounded expansion accepted")
	}
}
func applyNote(t *testing.T, m *Manager, device, content string, version int64) {
	t.Helper()
	data, _ := json.Marshal(domain.Note{Title: "Note", Content: content})
	_, err := m.Store.Apply(context.Background(), device, []domain.Mutation{{OperationID: store.RandomSecret(), Record: domain.Record{ID: "note1", Kind: "note", Version: version, Data: data}}})
	if err != nil {
		t.Fatal(err)
	}
}
func TestEncryptedRoundTripKeepsAuthRotatesGenerationAndPreservesFiles(t *testing.T) {
	ctx := context.Background()
	m, device, token := fixture(t)
	content := []byte("an attachment\x00\xff")
	sum := sha256.Sum256(content)
	id := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(m.Files, id), content, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.DB.Exec("INSERT INTO attachments VALUES(?,?,?,?)", id, "hello.bin", len(content), "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	applyNote(t, m, device, "secret [file](attachment:"+id+")", 0)
	generation, _, _ := m.Store.Generation(ctx)
	entry, err := m.Create(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	path, _ := m.Path(entry.ID)
	encrypted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encrypted, []byte("secret")) {
		t.Fatal("plaintext in backup")
	}
	applyNote(t, m, device, "changed", 1)
	if err = m.Restore(ctx, path, ""); err != nil {
		t.Fatal(err)
	}
	if got, err := m.Store.Authorize(ctx, token); err != nil || got != device {
		t.Fatal("authentication lost", err)
	}
	next, required, err := m.Store.Generation(ctx)
	if err != nil || next == generation || !required {
		t.Fatal("generation not rotated")
	}
	snapshot, err := m.Store.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(snapshot.Records[0].Data, []byte("secret")) {
		t.Fatal("note not restored")
	}
	if b, err := os.ReadFile(filepath.Join(m.Files, id)); err != nil || !bytes.Equal(b, content) {
		t.Fatal("attachment mismatch")
	}
	list, err := m.List()
	if err != nil || len(list) != 2 {
		t.Fatal("safety backup missing", err)
	}
	second, _, _ := fixture(t)
	imported, err := second.Import(ctx, path, m.RecoveryKey())
	if err != nil {
		t.Fatal(err)
	}
	importPath, _ := second.Path(imported.ID)
	if err = second.Restore(ctx, importPath, ""); err != nil {
		t.Fatal(err)
	}
	if _, err = second.Store.Authorize(ctx, token); err == nil {
		t.Fatal("old server credentials resurrected")
	}
}
func TestRejectsIncompleteCorruptAndHostileArchives(t *testing.T) {
	ctx := context.Background()
	m, device, _ := fixture(t)
	applyNote(t, m, device, "[missing](attachment:"+string(bytes.Repeat([]byte("a"), 64))+")", 0)
	if _, err := m.Create(ctx, "manual"); err == nil {
		t.Fatal("missing attachment silently accepted")
	}
	applyNote(t, m, device, "safe", 1)
	entry, err := m.Create(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	path, _ := m.Path(entry.ID)
	wrong, _ := age.GenerateX25519Identity()
	if _, _, err = m.stage(ctx, path, wrong.String()); err == nil {
		t.Fatal("wrong key accepted")
	}
	bytesOnDisk, _ := os.ReadFile(path)
	bytesOnDisk[len(bytesOnDisk)-1] ^= 1
	bad := filepath.Join(m.Dir, "corrupt")
	os.WriteFile(bad, bytesOnDisk, 0600)
	if err = m.Restore(ctx, bad, ""); err == nil {
		t.Fatal("tampered archive accepted")
	}
	var encrypted bytes.Buffer
	w, _ := age.Encrypt(&encrypted, m.identity.Recipient())
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	snapshot, _ := json.Marshal(store.Snapshot{Format: 1, Created: time.Now().UTC(), Records: []domain.Record{}, Attachments: []store.Attachment{}})
	if err = add(ctx, tw, "snapshot.json", int64(len(snapshot)), bytes.NewReader(snapshot)); err != nil {
		t.Fatal(err)
	}
	if err = add(ctx, tw, "../../escape", 4, bytes.NewBufferString("evil")); err != nil {
		t.Fatal(err)
	}
	tw.Close()
	gz.Close()
	w.Close()
	os.WriteFile(bad, encrypted.Bytes(), 0600)
	if err = m.Restore(ctx, bad, ""); err == nil {
		t.Fatal("path traversal accepted")
	}
	if _, err = os.Stat(filepath.Join(m.Dir, "..", "escape")); !os.IsNotExist(err) {
		t.Fatal("archive escaped")
	}
}
