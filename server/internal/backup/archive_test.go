package backup

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPortableArchiveValidationDoesNotChangeWorkspace(t *testing.T) {
	ctx := context.Background()
	m, device, _ := fixture(t)
	applyNote(t, m, device, "keep this note", 0)
	snapshot, err := m.Store.Export(ctx)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []string{"checksum", "missing checksum", "duplicate entry", "plaintext", "truncated", "trailing bytes", "legacy envelope"} {
		t.Run(scenario, func(t *testing.T) {
			var out bytes.Buffer
			gz := gzip.NewWriter(&out)
			tw := tar.NewWriter(gz)
			switch scenario {
			case "checksum", "missing checksum":
				if err = add(ctx, tw, "snapshot.json", int64(len(data)), bytes.NewReader(data)); err != nil {
					t.Fatal(err)
				}
				if scenario == "checksum" {
					if err = add(ctx, tw, "snapshot.sha256", 64, strings.NewReader(strings.Repeat("0", 64))); err != nil {
						t.Fatal(err)
					}
				}
			case "plaintext":
				invalid, err := m.Store.Export(ctx)
				if err != nil {
					t.Fatal(err)
				}
				invalid.Records[0].Data = json.RawMessage(`{"title":"unencrypted note"}`)
				plain, err := json.Marshal(invalid)
				if err != nil {
					t.Fatal(err)
				}
				writeTestSnapshot(t, tw, plain)
			default:
				writeTestSnapshot(t, tw, data)
				if scenario == "duplicate entry" {
					writeTestSnapshot(t, tw, data)
				}
			}
			if err = tw.Close(); err != nil {
				t.Fatal(err)
			}
			if err = gz.Close(); err != nil {
				t.Fatal(err)
			}
			contents := out.Bytes()
			switch scenario {
			case "truncated":
				contents = contents[:len(contents)-1]
			case "trailing bytes":
				contents = append(contents, []byte("unexpected tail")...)
			case "legacy envelope":
				contents = append([]byte("age-encryption.org/v1\n"), contents...)
			}
			path := filepath.Join(t.TempDir(), "invalid.yggbackup")
			if err = os.WriteFile(path, contents, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err = m.Import(ctx, path); err == nil {
				t.Fatal("invalid archive imported")
			}
			if err = m.Restore(ctx, path); err == nil {
				t.Fatal("invalid archive restored")
			}
			after, err := m.Store.Export(ctx)
			if err != nil || len(after.Records) != 1 || !bytes.Equal(after.Records[0].Data, snapshot.Records[0].Data) {
				t.Fatal("failed validation modified the workspace", err)
			}
			files, err := os.ReadDir(m.Dir)
			if err != nil || len(files) != 0 {
				t.Fatal("failed validation left partial files or a published backup", files, err)
			}
		})
	}
}
