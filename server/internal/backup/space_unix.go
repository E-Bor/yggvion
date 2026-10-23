//go:build linux || darwin

package backup

import "golang.org/x/sys/unix"

func availableDisk(path string) (uint64, error) {
	var info unix.Statfs_t
	err := unix.Statfs(path, &info)
	return info.Bavail * uint64(info.Bsize), err
}
