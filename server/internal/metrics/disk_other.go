//go:build !linux && !darwin

package metrics

import "errors"

func disk(string) (uint64, uint64, error) { return 0, 0, errors.New("metrics require a Linux VPS") }
