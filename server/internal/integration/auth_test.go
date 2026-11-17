package integration

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/t5plan/t5/server/internal/auth"
)

func TestPairingCodeIsOneTimeAndTokenRevocable(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &auth.Service{Store: st, TTL: 30 * time.Second}
	code, _, err := svc.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	dev, token, err := svc.Pair(ctx, code, "Windows 主力机", "windows")
	if err != nil {
		t.Fatal(err)
	}
	if token == "" || dev.ID == "" {
		t.Fatal("empty token or device id")
	}
	if len(code) != 6 {
		t.Fatalf("pairing code length = %d, want 6", len(code))
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			t.Fatalf("pairing code is not numeric: %q", code)
		}
	}
	if _, _, err := svc.Pair(ctx, code, "重放设备", "android"); !errors.Is(err, auth.ErrInvalidCode) {
		t.Fatalf("pairing replay: %v", err)
	}
	got, err := svc.Authenticate(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != dev.ID {
		t.Fatalf("device mismatch: %s != %s", got.ID, dev.ID)
	}
	if err := svc.RevokeDevice(ctx, dev.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Authenticate(ctx, token); !errors.Is(err, auth.ErrUnauthorized) {
		t.Fatalf("revoked token accepted: %v", err)
	}
}

func TestExpiredPairingCodeRejected(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &auth.Service{Store: st, TTL: -time.Second}
	code, _, err := svc.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.Pair(ctx, code, "设备", "android"); !errors.Is(err, auth.ErrInvalidCode) {
		t.Fatalf("expired code: %v", err)
	}
}

func TestNewPairingCodeInvalidatesOlderCode(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &auth.Service{Store: st, TTL: 30 * time.Second}
	first, _, err := svc.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.InvalidateOpenCodes(ctx); err != nil {
		t.Fatal(err)
	}
	second, _, err := svc.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.Pair(ctx, first, "old", "android"); !errors.Is(err, auth.ErrInvalidCode) {
		t.Fatalf("old pairing code accepted: %v", err)
	}
	if _, _, err := svc.Pair(ctx, second, "new", "android"); err != nil {
		t.Fatalf("new pairing code rejected: %v", err)
	}
}

func TestPairingAttemptRateLimit(t *testing.T) {
	st := testStore(t)
	svc := &auth.Service{Store: st, TTL: 30 * time.Second}
	for i := 0; i < 6; i++ {
		if !svc.AllowPairAttempt("127.0.0.1") {
			t.Fatalf("attempt %d rejected too early", i)
		}
	}
	if svc.AllowPairAttempt("127.0.0.1") {
		t.Fatal("seventh attempt within a minute should be rate limited")
	}
	if !svc.AllowPairAttempt("127.0.0.2") {
		t.Fatal("different client should have its own bucket")
	}
}
