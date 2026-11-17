package config

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Addr             string
	DBDSN            string
	MasterKey        []byte
	PairingTTL       time.Duration
	SyncBatchLimit   int
	ChangesPageLimit int
	JobWorkerEvery   time.Duration
	ReportScheduler  time.Duration
	LogLevel         string
}

func Load() (Config, error) {
	cfg := Config{
		Addr:             env("T5_ADDR", ":8080"),
		DBDSN:            env("T5_DB_DSN", ""),
		PairingTTL:       30 * time.Second,
		SyncBatchLimit:   100,
		ChangesPageLimit: 500,
		JobWorkerEvery:   2 * time.Second,
		ReportScheduler:  30 * time.Second,
		LogLevel:         env("T5_LOG_LEVEL", "info"),
	}
	if cfg.DBDSN == "" {
		return Config{}, errors.New("T5_DB_DSN is required")
	}
	rawKey := env("T5_MASTER_KEY", "")
	if rawKey == "" {
		return Config{}, errors.New("T5_MASTER_KEY is required (32-byte key encoded as base64 or hex)")
	}
	key, err := parseKey(rawKey)
	if err != nil {
		return Config{}, err
	}
	cfg.MasterKey = key
	if v := env("T5_PAIRING_TTL", ""); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("T5_PAIRING_TTL: %w", err)
		}
		cfg.PairingTTL = d
	}
	if v := env("T5_SYNC_BATCH_LIMIT", ""); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			return Config{}, errors.New("T5_SYNC_BATCH_LIMIT must be 1..500")
		}
		cfg.SyncBatchLimit = n
	}
	if v := env("T5_CHANGES_PAGE_LIMIT", ""); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 2000 {
			return Config{}, errors.New("T5_CHANGES_PAGE_LIMIT must be 1..2000")
		}
		cfg.ChangesPageLimit = n
	}
	return cfg, nil
}

func parseKey(s string) ([]byte, error) {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil && len(b) == 32 {
		return b, nil
	}
	if b, err := hex.DecodeString(s); err == nil && len(b) == 32 {
		return b, nil
	}
	return nil, errors.New("T5_MASTER_KEY must decode to exactly 32 bytes (base64 or hex)")
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
