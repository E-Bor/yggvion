package backup

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"filippo.io/age"
	"yggvion/server/internal/domain"
	"yggvion/server/internal/store"
)

const backupTestKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func passwordFixture() domain.PasswordEnvelope {
	return domain.PasswordEnvelope{Version: 1, KeyID: backupTestKey, Revision: 1,
		KDF: "argon2id", Memory: 19456, Iterations: 2, Parallelism: 1,
		Salt:  base64.StdEncoding.EncodeToString(make([]byte, 16)),
		Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)),
		Box:   base64.StdEncoding.EncodeToString(make([]byte, 48)),
		MAC:   base64.StdEncoding.EncodeToString(make([]byte, 32))}
}
func backupRecord(content string, files []string) json.RawMessage {
	box := sha256.Sum256([]byte(content))
	data, _ := json.Marshal(domain.Envelope{E2EE: 1, KeyID: backupTestKey,
		Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)),
		Box:   base64.StdEncoding.EncodeToString(box[:]), Files: files})
	return data
}

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
	if err = s.EnableEncryption(context.Background(), backupTestKey, passwordFixture()); err != nil {
		t.Fatal(err)
	}
	return m, id, token
}

func TestPasswordBackupRestoresIntoFreshServer(t *testing.T) {
	ctx := context.Background()
	source, device, _ := fixture(t)
	applyNote(t, source, device, "private", 0)
	entry, err := source.Create(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	path, _ := source.Path(entry.ID)
	dir := t.TempDir()
	target, err := store.Open(filepath.Join(dir, "db"))
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	owner, token, err := target.Pair(ctx, "new owner")
	if err != nil {
		t.Fatal(err)
	}
	manager, err := Open(target, filepath.Join(dir, "backups"), filepath.Join(dir, "attachments"), &sync.RWMutex{})
	if err != nil {
		t.Fatal(err)
	}
	if err = manager.Restore(ctx, path, source.RecoveryKey()); err != nil {
		t.Fatal(err)
	}
	snapshot, err := target.Export(ctx)
	if err != nil || snapshot.Format != 2 || snapshot.PasswordEnvelope == nil || snapshot.PasswordEnvelope.KeyID != backupTestKey || len(snapshot.Records) != 1 {
		t.Fatal(snapshot, err)
	}
	if id, err := target.Authorize(ctx, token); err != nil || id != owner {
		t.Fatal("restore replaced device credentials", err)
	}
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
			valid, err := m.Store.Export(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			snapshot, _ := json.Marshal(valid)
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

func TestCreateRejectsArchivesThatExceedRestoreBudget(t *testing.T) {
	m, _, _ := fixture(t)
	tx, err := m.Store.DB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	for i := range 342 {
		if _, err = tx.Exec("INSERT INTO attachments VALUES(?,?,?,?)", fmt.Sprintf("%064x", i), "encrypted", 300<<20, "application/octet-stream"); err != nil {
			t.Fatal(err)
		}
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	// Reject metadata before reading files or producing an archive we cannot restore.
	if _, err = m.Create(context.Background(), "manual"); err == nil || !strings.Contains(err.Error(), "exceed 100 GiB") {
		t.Fatal(err)
	}
	entries, err := m.List()
	if err != nil || len(entries) != 0 {
		t.Fatal(entries, err)
	}
}
func applyNote(t *testing.T, m *Manager, device, content string, version int64, files ...string) {
	t.Helper()
	_, err := m.Store.Apply(context.Background(), device, []domain.Mutation{{
		OperationID: store.RandomSecret(), Record: domain.Record{ID: "note1", Kind: "note", Version: version, Data: backupRecord(content, files)}}})
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
	if _, err := m.Store.DB.Exec("INSERT INTO attachments VALUES(?,?,?,?)", id, "encrypted", len(content), "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.DB.Exec("INSERT INTO encrypted_uploads VALUES(?,?)", id, backupTestKey); err != nil {
		t.Fatal(err)
	}
	applyNote(t, m, device, "secret", 0, id)
	generation, _ := m.Store.Generation(ctx)
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
	next, err := m.Store.Generation(ctx)
	if err != nil || next == generation {
		t.Fatal("generation not rotated")
	}
	snapshot, err := m.Store.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(snapshot.Records[0].Data, backupRecord("secret", []string{id})) {
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
	applyNote(t, m, device, "safe", 0)
	if _, err := m.Store.DB.Exec("UPDATE records SET data=? WHERE id='note1'", string(backupRecord("missing", []string{strings.Repeat("a", 64)}))); err != nil {
		t.Fatal(err)
	}
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
	valid, err := m.Store.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, _ := json.Marshal(valid)
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
