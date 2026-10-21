package metrics

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCPUAndMemoryParsing(t *testing.T) {
	total, idle, err := cpu([]byte("cpu 10 2 3 50 5 4 6 1 100 100\n"))
	if err != nil || total != 81 || idle != 55 {
		t.Fatal(total, idle, err)
	}
	for _, text := range []string{"", "cpu 1 2", "cpu x 0 0 0"} {
		if _, _, err := cpu([]byte(text)); err == nil {
			t.Fatal("invalid CPU accepted")
		}
	}
	m := memory([]byte("MemTotal: 1000 kB\nMemAvailable: 400 kB\n"))
	if m["MemTotal"] != 1024000 || m["MemAvailable"] != 409600 {
		t.Fatal(m)
	}
}
func TestOnDemandCacheAndCancellation(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "self"), 0700)
	os.WriteFile(filepath.Join(dir, "stat"), []byte("cpu 10 0 0 50 0 0 0 0\n"), 0600)
	os.WriteFile(filepath.Join(dir, "meminfo"), []byte("MemTotal: 1000 kB\nMemAvailable: 400 kB\n"), 0600)
	os.WriteFile(filepath.Join(dir, "self/status"), []byte("VmRSS: 10 kB\n"), 0600)
	c := New(dir)
	c.ProcDir = dir
	s, err := c.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if s.MemoryUsed != 600*1024 || s.ProcessMemory != 10*1024 || s.DiskTotal == 0 {
		t.Fatal(s)
	}
	os.Remove(filepath.Join(dir, "stat"))
	cached, err := c.Read(context.Background())
	if err != nil || cached.SampledAt != s.SampledAt {
		t.Fatal("cache not used", err)
	}
	c.cached.SampledAt = time.Now().Add(-time.Minute)
	if _, err = c.Read(context.Background()); err == nil {
		t.Fatal("stale metrics silently returned")
	}
	os.WriteFile(filepath.Join(dir, "stat"), []byte("cpu 10 0 0 50 0 0 0 0\n"), 0600)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = c.Read(ctx); err == nil {
		t.Fatal("cancellation ignored")
	}
}
