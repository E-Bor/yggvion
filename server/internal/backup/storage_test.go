package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/iotest"
	"time"
)

func TestFailedRemoteReplicationStillRotatesScheduledCopies(t *testing.T) {
	m, _, _ := fixture(t)
	if err := m.Configure(Config{EveryHours: 24, KeepDaily: 1, KeepWeekly: 0}); err != nil {
		t.Fatal(err)
	}
	old, err := m.Create(context.Background(), "scheduled")
	if err != nil {
		t.Fatal(err)
	}
	old.Created = old.Created.Add(-48 * time.Hour)
	encoded, _ := json.Marshal(old)
	if err = os.WriteFile(filepath.Join(m.Dir, old.ID+".json"), encoded, 0600); err != nil {
		t.Fatal(err)
	}
	manual, err := m.Create(context.Background(), "manual")
	if err != nil {
		t.Fatal(err)
	}
	// Invalid destination simulates an unavailable remote without network traffic.
	if err = m.saveRemote(RemoteConfig{Kind: "unavailable"}); err != nil {
		t.Fatal(err)
	}
	if err = m.createScheduled(context.Background()); err == nil {
		t.Fatal("replication error was hidden")
	}
	entries, err := m.List()
	if err != nil {
		t.Fatal(err)
	}
	var scheduled int
	for _, entry := range entries {
		if entry.ID == old.ID {
			t.Fatal("obsolete archive retained after remote failure")
		}
		if entry.Reason == "scheduled" {
			scheduled++
		}
	}
	if len(entries) != 2 || scheduled != 1 {
		t.Fatal(entries)
	}
	path, _ := m.Path(manual.ID)
	if _, err = os.Stat(path); err != nil {
		t.Fatal("manual archive was pruned", err)
	}
}

func TestDiskReserveStopsUnknownLengthStreamsBeforeExhaustion(t *testing.T) {
	m, _, _ := fixture(t)
	var target bytes.Buffer
	m.availableSpace = func(string) (uint64, error) { return diskReserve + 10 - uint64(target.Len()), nil }
	if err := m.CheckSpace(11); !errors.Is(err, ErrNoSpace) {
		t.Fatal(err)
	}
	n, err := m.CopyWithReserve(context.Background(), &target, iotest.OneByteReader(strings.NewReader("1234567890overflow")))
	if !errors.Is(err, ErrNoSpace) || n != 10 || target.String() != "1234567890" {
		t.Fatal(n, target.String(), err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = m.CopyWithReserve(ctx, &target, strings.NewReader("x")); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation ignored", err)
	}
}

func TestOpeningBackupsCleansOnlyIncompleteFiles(t *testing.T) {
	m, _, _ := fixture(t)
	entry, err := m.Create(context.Background(), "manual")
	if err != nil {
		t.Fatal(err)
	}
	for _, prefix := range []string{".upload-", ".restore-", ".import-", ".remote-", ".backup-", ".write-"} {
		path := filepath.Join(m.Dir, prefix+"interrupted")
		if err = os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(path, "partial"), []byte("partial"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err = os.WriteFile(filepath.Join(m.Files, "upload-interrupted"), []byte("partial"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(m.Dir, "keep-me"), []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(m.Store, m.Dir, m.Files, m.DataMu)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := reopened.List()
	if err != nil || len(entries) != 1 || entries[0].ID != entry.ID {
		t.Fatal(entries, err)
	}
	partials, _ := filepath.Glob(filepath.Join(m.Dir, ".*-interrupted"))
	if len(partials) != 0 {
		t.Fatal(partials)
	}
	if _, err = os.Stat(filepath.Join(m.Files, "upload-interrupted")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("attachment partial retained")
	}
	if _, err = os.Stat(filepath.Join(m.Dir, "keep-me")); err != nil {
		t.Fatal("unrelated file removed")
	}
}
