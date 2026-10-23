//go:build !linux && !darwin

package backup

import "errors"

func availableDisk(string) (uint64, error) {
	return 0, errors.New("server disk budget requires Linux or macOS")
}
