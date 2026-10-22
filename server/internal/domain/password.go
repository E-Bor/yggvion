package domain

import (
	"encoding/base64"
	"errors"
)

// PasswordEnvelope is an opaque client-generated wrapping. The relay cannot
// verify its MAC or decrypt it; clients authenticate it with their workspace key.
type PasswordEnvelope struct {
	Version     int    `json:"v"`
	KeyID       string `json:"key_id"`
	Revision    int64  `json:"revision"`
	KDF         string `json:"kdf"`
	Memory      int    `json:"memory"`
	Iterations  int    `json:"iterations"`
	Parallelism int    `json:"parallelism"`
	Salt        string `json:"salt"`
	Nonce       string `json:"nonce"`
	Box         string `json:"box"`
	MAC         string `json:"mac"`
}

func (p PasswordEnvelope) Validate() error {
	if p.Version != 1 || !ValidHash(p.KeyID) || p.Revision < 1 || p.Revision > 2147483647 ||
		p.KDF != "argon2id" || p.Memory != 19456 || p.Iterations != 2 || p.Parallelism != 1 {
		return errors.New("invalid password envelope")
	}
	for _, v := range []struct {
		text string
		size int
	}{{p.Salt, 16}, {p.Nonce, 12}, {p.Box, 48}, {p.MAC, 32}} {
		if len(v.text) > 128 {
			return errors.New("invalid password envelope")
		}
		b, err := base64.StdEncoding.Strict().DecodeString(v.text)
		if err != nil || len(b) != v.size {
			return errors.New("invalid password envelope")
		}
	}
	return nil
}
