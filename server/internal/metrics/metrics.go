// Package metrics samples on demand. No background monitoring loop is started.
package metrics

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Snapshot struct {
	SampledAt     time.Time `json:"sampled_at"`
	CPUPercent    *float64  `json:"cpu_percent"`
	MemoryTotal   uint64    `json:"memory_total_bytes"`
	MemoryUsed    uint64    `json:"memory_used_bytes"`
	ProcessMemory uint64    `json:"process_memory_bytes"`
	DiskTotal     uint64    `json:"disk_total_bytes"`
	DiskAvailable uint64    `json:"disk_available_bytes"`
	UptimeSeconds int64     `json:"uptime_seconds"`
}

type Collector struct {
	mu               sync.Mutex
	cached           *Snapshot
	Started          time.Time
	ProcDir, DataDir string
}

func New(dataDir string) *Collector {
	return &Collector{Started: time.Now(), ProcDir: "/proc", DataDir: dataDir}
}
func cpu(data []byte) (uint64, uint64, error) {
	fields := strings.Fields(strings.SplitN(string(data), "\n", 2)[0])
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, errors.New("CPU metrics unavailable")
	}
	var total, idle uint64
	// guest and guest_nice are already included in user/nice.
	for i := 1; i < len(fields) && i <= 8; i++ {
		n, err := strconv.ParseUint(fields[i], 10, 64)
		if err != nil {
			return 0, 0, err
		}
		total += n
		if i == 4 || i == 5 {
			idle += n
		}
	}
	return total, idle, nil
}
func memory(data []byte) map[string]uint64 {
	result := map[string]uint64{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		n, err := strconv.ParseUint(f[1], 10, 64)
		if err == nil {
			result[strings.TrimSuffix(f[0], ":")] = n * 1024
		}
	}
	return result
}
func (c *Collector) Read(ctx context.Context) (Snapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached != nil && time.Since(c.cached.SampledAt) < 30*time.Second {
		return *c.cached, nil
	}
	readCPU := func() (uint64, uint64, error) {
		b, e := os.ReadFile(filepath.Join(c.ProcDir, "stat"))
		if e != nil {
			return 0, 0, e
		}
		return cpu(b)
	}
	total1, idle1, err := readCPU()
	if err != nil {
		return Snapshot{}, err
	}
	timer := time.NewTimer(150 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return Snapshot{}, ctx.Err()
	case <-timer.C:
	}
	total2, idle2, err := readCPU()
	if err != nil {
		return Snapshot{}, err
	}
	result := Snapshot{SampledAt: time.Now().UTC(), UptimeSeconds: int64(time.Since(c.Started).Seconds())}
	if total2 > total1 && idle2 >= idle1 && idle2-idle1 <= total2-total1 {
		value := 100 * (1 - float64(idle2-idle1)/float64(total2-total1))
		result.CPUPercent = &value
	}
	data, err := os.ReadFile(filepath.Join(c.ProcDir, "meminfo"))
	if err != nil {
		return Snapshot{}, err
	}
	mem := memory(data)
	result.MemoryTotal = mem["MemTotal"]
	if result.MemoryTotal == 0 || mem["MemAvailable"] > result.MemoryTotal {
		return Snapshot{}, errors.New("memory metrics unavailable")
	}
	result.MemoryUsed = result.MemoryTotal - mem["MemAvailable"]
	data, err = os.ReadFile(filepath.Join(c.ProcDir, "self/status"))
	if err != nil {
		return Snapshot{}, err
	}
	result.ProcessMemory = memory(data)["VmRSS"]
	result.DiskTotal, result.DiskAvailable, err = disk(c.DataDir)
	if err != nil {
		return Snapshot{}, err
	}
	c.cached = &result
	return result, nil
}
