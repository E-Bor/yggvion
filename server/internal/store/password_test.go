package store

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"

	"yggvion/server/internal/domain"
)

func passwordFixture(key string, revision int64) domain.PasswordEnvelope {
	return domain.PasswordEnvelope{
		Version: 1, KeyID: key, Revision: revision,
		KDF: "argon2id", Memory: 19456, Iterations: 2, Parallelism: 1,
		Salt:  base64.StdEncoding.EncodeToString(make([]byte, 16)),
		Nonce: base64.StdEncoding.EncodeToString(make([]byte, 12)),
		Box:   base64.StdEncoding.EncodeToString(make([]byte, 48)),
		MAC:   base64.StdEncoding.EncodeToString(make([]byte, 32)),
	}
}

func TestPasswordRotationCompareAndSwapAndRestore(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	key := strings.Repeat("a", 64)
	first := passwordFixture(key, 1)
	if err = s.EnableEncryption(ctx, key, first); err != nil {
		t.Fatal(err)
	}
	oldSnapshot, err := s.Export(ctx)
	if err != nil || oldSnapshot.PasswordEnvelope == nil || *oldSnapshot.PasswordEnvelope != first {
		t.Fatal("snapshot lost password", err)
	}
	next := passwordFixture(key, 2)
	if err = s.SetPasswordEnvelope(ctx, key, 1, next); err != nil {
		t.Fatal(err)
	}
	if err = s.SetPasswordEnvelope(ctx, key, 1, next); err != nil {
		t.Fatal("idempotent retry", err)
	}
	concurrent := next
	concurrent.Salt = base64.StdEncoding.EncodeToString([]byte("different-salt!!"))
	if err = s.SetPasswordEnvelope(ctx, key, 1, concurrent); err != ErrConflict {
		t.Fatal("lost update", err)
	}
	wrongKey := passwordFixture(strings.Repeat("b", 64), 3)
	if err = s.SetPasswordEnvelope(ctx, wrongKey.KeyID, 2, wrongKey); err != ErrConflict {
		t.Fatal("wrong key", err)
	}
	if err = s.Restore(ctx, oldSnapshot); err != nil {
		t.Fatal(err)
	}
	current, err := s.PasswordEnvelope(ctx)
	if err != nil || current == nil || *current != next {
		t.Fatal("restore reverted password", err)
	}
	fresh, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	if err = fresh.Restore(ctx, oldSnapshot); err != nil {
		t.Fatal(err)
	}
	current, err = fresh.PasswordEnvelope(ctx)
	if err != nil || current == nil || *current != first {
		t.Fatal("fresh restore lost password", err)
	}
}

func TestPasswordParametersAreBounded(t *testing.T) {
	valid := passwordFixture(strings.Repeat("c", 64), 1)
	for name, change := range map[string]func(*domain.PasswordEnvelope){
		"memory":      func(p *domain.PasswordEnvelope) { p.Memory = 999999999 },
		"iterations":  func(p *domain.PasswordEnvelope) { p.Iterations = 999999999 },
		"parallelism": func(p *domain.PasswordEnvelope) { p.Parallelism = 1000 },
		"salt":        func(p *domain.PasswordEnvelope) { p.Salt = "short" },
		"mac":         func(p *domain.PasswordEnvelope) { p.MAC = "" },
		"key":         func(p *domain.PasswordEnvelope) { p.KeyID = "invalid" },
		"revision":    func(p *domain.PasswordEnvelope) { p.Revision = -1 },
	} {
		t.Run(name, func(t *testing.T) {
			value := valid
			change(&value)
			if value.Validate() == nil {
				t.Fatal("accepted invalid wrapping")
			}
		})
	}
}
