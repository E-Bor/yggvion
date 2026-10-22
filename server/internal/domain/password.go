package domain

import (
	"encoding/base64"
	"errors"
)

// PasswordConfig contains only public KDF parameters and a derived-key fingerprint.
// No random workspace key, password or wrapped key is persisted on the relay.
type PasswordConfig struct {
	Version     int    `json:"v"`
	KeyID       string `json:"key_id"`
	KDF         string `json:"kdf"`
	Memory      int    `json:"memory"`
	Iterations  int    `json:"iterations"`
	Parallelism int    `json:"parallelism"`
	Salt        string `json:"salt"`
}

func (p PasswordConfig) Validate() error {
	if p.Version != 2 || !ValidHash(p.KeyID) || p.KDF != "argon2id" || p.Memory != 19456 || p.Iterations != 2 || p.Parallelism != 1 {
		return errors.New("invalid password configuration")
	}
	salt, err := base64.StdEncoding.Strict().DecodeString(p.Salt)
	if err != nil || len(p.Salt) != 24 || len(salt) != 16 {
		return errors.New("invalid password salt")
	}
	return nil
}
