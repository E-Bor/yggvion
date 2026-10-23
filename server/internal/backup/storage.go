package backup

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	MaxImportBytes int64  = 100 << 30
	diskReserve    uint64 = 512 << 20
)

var ErrNoSpace = errors.New("insufficient disk space for backup")

func (m *Manager) CheckSpace(bytes int64) error {
	available, err := m.availableSpace(m.Dir)
	if err != nil {
		return err
	}
	if available < diskReserve || (bytes > 0 && uint64(bytes) > available-diskReserve) {
		return ErrNoSpace
	}
	return nil
}

type reserveWriter struct {
	manager   *Manager
	target    io.Writer
	remaining int64
}

func (w *reserveWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		available, err := w.manager.availableSpace(w.manager.Dir)
		if err != nil {
			return 0, err
		}
		if available < diskReserve || uint64(len(p)) > available-diskReserve {
			return 0, ErrNoSpace
		}
		w.remaining = int64(min(available-diskReserve, 8<<20))
	}
	n, err := w.target.Write(p)
	w.remaining -= int64(n)
	return n, err
}

func (m *Manager) CopyWithReserve(ctx context.Context, target io.Writer, source io.Reader) (int64, error) {
	return copyContext(ctx, &reserveWriter{manager: m, target: target}, source)
}

// Called only while opening the manager, before HTTP handlers or jobs start.
// Complete archives and their metadata are never included in these patterns.
func cleanIncomplete(dir string, prefixes ...string) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		for _, prefix := range prefixes {
			if strings.HasPrefix(entry.Name(), prefix) {
				if err = os.RemoveAll(filepath.Join(dir, entry.Name())); err != nil {
					return err
				}
				break
			}
		}
	}
	return nil
}
