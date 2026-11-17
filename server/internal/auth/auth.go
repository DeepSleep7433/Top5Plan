package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

var (
	ErrInvalidCode  = errors.New("pairing code is invalid, expired, or already used")
	ErrUnauthorized = errors.New("unauthorized")
)

type Device struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

type Service struct {
	Store *store.Store
	TTL   time.Duration

	mu       sync.Mutex
	attempts map[string][]time.Time
}

func HashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// InvalidateOpenCodes makes the newest on-demand code the only usable one.
// It is called before issuing a new 30-second code so a stale code displayed
// on another device cannot still be used after the user asks for a refresh.
func (s *Service) InvalidateOpenCodes(ctx context.Context) error {
	_, err := s.Store.DB.ExecContext(ctx,
		`UPDATE pairing_codes SET used_at = UTC_TIMESTAMP(6)
		 WHERE used_at IS NULL`)
	return err
}

// AllowPairAttempt applies a simple per-client in-memory throttle. A six-digit
// code has a small keyspace, so pairing attempts must be rate limited in
// addition to the 30-second expiry.
func (s *Service) AllowPairAttempt(clientKey string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attempts == nil {
		s.attempts = map[string][]time.Time{}
	}
	cutoff := time.Now().Add(-time.Minute)
	list := s.attempts[clientKey]
	kept := list[:0]
	for _, t := range list {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= 6 {
		s.attempts[clientKey] = kept
		return false
	}
	kept = append(kept, time.Now())
	s.attempts[clientKey] = kept
	return true
}

func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func (s *Service) CreatePairingCode(ctx context.Context) (code string, expires time.Time, err error) {
	code, err = randomCode()
	if err != nil {
		return "", time.Time{}, err
	}
	expires = time.Now().UTC().Add(s.TTL).Truncate(time.Microsecond)
	_, err = s.Store.DB.ExecContext(ctx,
		`INSERT INTO pairing_codes(id, code_hash, expires_at, created_at) VALUES(?, ?, ?, UTC_TIMESTAMP(6))`,
		uuid.NewString(), HashToken(code), expires)
	return code, expires, err
}

func (s *Service) Pair(ctx context.Context, code, name, platform string) (Device, string, error) {
	if strings.TrimSpace(name) == "" || len(name) > 120 {
		return Device{}, "", errors.New("device name must be 1..120 characters")
	}
	if platform != "windows" && platform != "android" && platform != "unknown" {
		return Device{}, "", errors.New("platform must be windows, android, or unknown")
	}
	token, err := randomToken()
	if err != nil {
		return Device{}, "", err
	}
	dev := Device{ID: uuid.NewString(), Name: name, Platform: platform, CreatedAt: time.Now().UTC()}
	tx, err := s.Store.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return Device{}, "", err
	}
	defer tx.Rollback()
	var codeID string
	var usedAt sql.NullTime
	var expiresAt time.Time
	err = tx.QueryRowContext(ctx,
		`SELECT id, used_at, expires_at FROM pairing_codes WHERE code_hash = ? FOR UPDATE`,
		HashToken(code)).Scan(&codeID, &usedAt, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, "", ErrInvalidCode
	}
	if err != nil {
		return Device{}, "", err
	}
	if usedAt.Valid || !time.Now().UTC().Before(expiresAt) {
		return Device{}, "", ErrInvalidCode
	}
	res, err := tx.ExecContext(ctx,
		`UPDATE pairing_codes SET used_at = UTC_TIMESTAMP(6) WHERE id = ? AND used_at IS NULL`, codeID)
	if err != nil {
		return Device{}, "", err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return Device{}, "", ErrInvalidCode
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO devices(id, name, platform, token_hash, created_at, last_seen_at) VALUES(?, ?, ?, ?, UTC_TIMESTAMP(6), UTC_TIMESTAMP(6))`,
		dev.ID, dev.Name, dev.Platform, HashToken(token)); err != nil {
		return Device{}, "", err
	}
	if err := tx.Commit(); err != nil {
		return Device{}, "", err
	}
	return dev, token, nil
}

func (s *Service) Authenticate(ctx context.Context, token string) (Device, error) {
	if token == "" {
		return Device{}, ErrUnauthorized
	}
	var d Device
	var lastSeen sql.NullTime
	var revoked sql.NullTime
	err := s.Store.DB.QueryRowContext(ctx,
		`SELECT id, name, platform, created_at, last_seen_at, revoked_at
		 FROM devices WHERE token_hash = ?`, HashToken(token)).
		Scan(&d.ID, &d.Name, &d.Platform, &d.CreatedAt, &lastSeen, &revoked)
	if errors.Is(err, sql.ErrNoRows) || revoked.Valid {
		return Device{}, ErrUnauthorized
	}
	if err != nil {
		return Device{}, err
	}
	if lastSeen.Valid {
		t := lastSeen.Time
		d.LastSeenAt = &t
	}
	if !lastSeen.Valid || time.Since(lastSeen.Time) > 5*time.Minute {
		_, _ = s.Store.DB.ExecContext(ctx, `UPDATE devices SET last_seen_at = UTC_TIMESTAMP(6) WHERE id = ?`, d.ID)
	}
	return d, nil
}

func (s *Service) ListDevices(ctx context.Context) ([]Device, error) {
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT id, name, platform, created_at, last_seen_at, revoked_at FROM devices ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		var d Device
		var lastSeen, revoked sql.NullTime
		if err := rows.Scan(&d.ID, &d.Name, &d.Platform, &d.CreatedAt, &lastSeen, &revoked); err != nil {
			return nil, err
		}
		if lastSeen.Valid {
			t := lastSeen.Time
			d.LastSeenAt = &t
		}
		if revoked.Valid {
			t := revoked.Time
			d.RevokedAt = &t
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Service) RevokeDevice(ctx context.Context, id string) error {
	res, err := s.Store.DB.ExecContext(ctx,
		`UPDATE devices SET revoked_at = COALESCE(revoked_at, UTC_TIMESTAMP(6)) WHERE id = ?`, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("device not found")
	}
	return nil
}
