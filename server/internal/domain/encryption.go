package domain

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
)

// Envelope contains no application fields. Files are hashes of ciphertext,
// never hashes or names of the original attachments.
type Envelope struct {
	E2EE  int      `json:"e2ee"`
	KeyID string   `json:"key_id"`
	Nonce string   `json:"nonce"`
	Box   string   `json:"box"`
	Files []string `json:"files"`
}

func ValidHash(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 32 && hex.EncodeToString(b) == s
}

func ReadEnvelope(r Record) (Envelope, error) {
	if !ValidID(r.ID) || r.Version < 0 || r.Seq < 0 || len(r.Data) > 3*1024*1024 {
		return Envelope{}, errors.New("invalid encrypted record")
	}
	var e Envelope
	decoder := json.NewDecoder(bytes.NewReader(r.Data))
	decoder.DisallowUnknownFields()
	err := decoder.Decode(&e)
	if err != nil || decoder.Decode(new(any)) != io.EOF || e.E2EE != 1 || !ValidHash(e.KeyID) {
		return e, errors.New("invalid encrypted record")
	}
	nonce, nerr := base64.StdEncoding.Strict().DecodeString(e.Nonce)
	box, berr := base64.StdEncoding.Strict().DecodeString(e.Box)
	if nerr != nil || berr != nil || len(nonce) != 12 || len(box) < 16 || len(box) > 2*1024*1024 || len(e.Files) > 10000 {
		return e, errors.New("invalid encrypted payload")
	}
	for _, id := range e.Files {
		if !ValidHash(id) {
			return e, errors.New("invalid encrypted file")
		}
	}
	switch r.Kind {
	case "task", "block", "session", "note", "note_folder", "project", "settings", "series", "snooze", "workday", "attachment":
	default:
		return e, errors.New("unknown record kind")
	}
	return e, nil
}
