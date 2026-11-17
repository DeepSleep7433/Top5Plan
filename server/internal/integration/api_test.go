package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/t5plan/t5/server/internal/ai"
	"github.com/t5plan/t5/server/internal/api"
	"github.com/t5plan/t5/server/internal/config"
)

func newAPI(t *testing.T) (*api.Server, *httptest.Server, string) {
	t.Helper()
	st := testStore(t)
	cfg := config.Config{
		MasterKey:        []byte("0123456789abcdef0123456789abcdef"),
		PairingTTL:       5 * time.Minute,
		SyncBatchLimit:   100,
		ChangesPageLimit: 500,
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := api.New(cfg, st, log)
	ts := httptest.NewServer(svc.Handler())
	t.Cleanup(ts.Close)
	code, _, err := svc.Auth.CreatePairingCode(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{
		"pairing_token": code,
		"device_name":   "test device",
		"platform":      "windows",
	})
	resp, err := http.Post(ts.URL+"/api/v1/devices/pair", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("pair status = %d", resp.StatusCode)
	}
	var paired struct {
		Token string `json:"device_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&paired); err != nil {
		t.Fatal(err)
	}
	return svc, ts, paired.Token
}

func request(t *testing.T, ts *httptest.Server, token, method, path string, body any) (*http.Response, map[string]any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, ts.URL+path, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&decoded)
	resp.Body.Close()
	return resp, decoded
}

func TestHealthReadyAndUnauthorized(t *testing.T) {
	_, ts, _ := newAPI(t)
	resp, body := request(t, ts, "", "GET", "/healthz", nil)
	if resp.StatusCode != 200 || body["status"] != "ok" {
		t.Fatalf("health: %d %+v", resp.StatusCode, body)
	}
	resp, body = request(t, ts, "", "GET", "/readyz", nil)
	if resp.StatusCode != 200 || body["migrations"] != "current" {
		t.Fatalf("ready: %d %+v", resp.StatusCode, body)
	}
	resp, _ = request(t, ts, "", "GET", "/api/v1/settings", nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized settings = %d", resp.StatusCode)
	}
}

func TestAIWithoutConfigReturnsExplicitConflict(t *testing.T) {
	_, ts, token := newAPI(t)
	resp, body := request(t, ts, token, "POST", "/api/v1/ai/jobs", map[string]any{
		"instruction": "分析",
		"sources":     []any{},
	})
	if resp.StatusCode != http.StatusConflict || body["error"] != "ai_not_configured" {
		t.Fatalf("ai without config: %d %+v", resp.StatusCode, body)
	}
}

func TestRecoverInterruptedJobBecomesUncertain(t *testing.T) {
	svc, _, _ := newAPI(t)
	ctx := context.Background()
	cfg, err := svc.AI.CreateConfig(ctx, ai.ConfigInput{
		Name: "test", BaseURL: "https://example.com/v1", Model: "m", APIKey: "secret",
		TimeoutSeconds: 30, MaxOutputTokens: 100, Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = svc.Store.DB.ExecContext(ctx,
		`INSERT INTO ai_jobs(id, account_id, kind, status, config_id, sources_json, input_scope_json, prompt_text, model, created_at, started_at)
		 VALUES(UUID(), 1, 'manual', 'running', ?, JSON_ARRAY(), JSON_OBJECT(), 'x', 'm', UTC_TIMESTAMP(6), UTC_TIMESTAMP(6))`, cfg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.AI.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}
	var status, code string
	if err := svc.Store.DB.QueryRow(`SELECT status, error_code FROM ai_jobs LIMIT 1`).Scan(&status, &code); err != nil {
		t.Fatal(err)
	}
	if status != "uncertain" || code != "server_restarted" {
		t.Fatalf("job after restart = %s/%s", status, code)
	}
}

func TestOnDemandSixDigitPairingCode(t *testing.T) {
	_, ts, token := newAPI(t)
	resp, body := request(t, ts, token, "POST", "/api/v1/devices/pairing-code", nil)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("pairing-code status = %d %+v", resp.StatusCode, body)
	}
	code, _ := body["pairing_code"].(string)
	if len(code) != 6 {
		t.Fatalf("pairing code = %q", code)
	}
	resp, paired := request(t, ts, "", "POST", "/api/v1/devices/pair", map[string]any{
		"pairing_code": code,
		"device_name":  "second device",
		"platform":     "android",
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("pair with six-digit code: %d %+v", resp.StatusCode, paired)
	}
	if paired["device_token"] == nil || paired["device_token"] == "" {
		t.Fatal("device token missing")
	}
	// The code is single-use.
	resp, _ = request(t, ts, "", "POST", "/api/v1/devices/pair", map[string]any{
		"pairing_code": code,
		"device_name":  "replay",
		"platform":     "android",
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("pairing replay status = %d", resp.StatusCode)
	}
}
