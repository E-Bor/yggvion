//go:build linux || darwin

package metrics

import "golang.org/x/sys/unix"

func disk(path string) (uint64, uint64, error) {
	var s unix.Statfs_t
	if err := unix.Statfs(path, &s); err != nil {
		return 0, 0, err
	}
	return s.Blocks * uint64(s.Bsize), s.Bavail * uint64(s.Bsize), nil
}
