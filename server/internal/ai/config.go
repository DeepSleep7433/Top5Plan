package ai

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

type ConfigInput struct {
	Name            string `json:"name"`
	BaseURL         string `json:"base_url"`
	Model           string `json:"model"`
	APIKey          string `json:"api_key,omitempty"`
	TimeoutSeconds  int    `json:"timeout_seconds"`
	MaxOutputTokens int    `json:"max_output_tokens"`
	Enabled         bool   `json:"enabled"`
}

type ConfigPublic struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	BaseURL         string    `json:"base_url"`
	Model           string    `json:"model"`
	TimeoutSeconds  int       `json:"timeout_seconds"`
	MaxOutputTokens int       `json:"max_output_tokens"`
	Enabled         bool      `json:"enabled"`
	HasAPIKey       bool      `json:"has_api_key"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

type configSecret struct {
	Public    ConfigPublic
	APIKey    string
	CreatedAt time.Time
}

type Service struct {
	Store     *store.Store
	MasterKey []byte
}

func (s *Service) validateInput(in ConfigInput, requireKey bool) error {
	if strings.TrimSpace(in.Name) == "" || len(in.Name) > 100 {
		return errors.New("name must be 1..100 characters")
	}
	u, err := url.Parse(strings.TrimSpace(in.BaseURL))
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return errors.New("base_url must be an http(s) URL")
	}
	if strings.TrimSpace(in.Model) == "" || len(in.Model) > 200 {
		return errors.New("model must be 1..200 characters")
	}
	if in.TimeoutSeconds == 0 {
		in.TimeoutSeconds = 120
	}
	if in.TimeoutSeconds < 5 || in.TimeoutSeconds > 600 {
		return errors.New("timeout_seconds must be 5..600")
	}
	if in.MaxOutputTokens == 0 {
		in.MaxOutputTokens = 2000
	}
	if in.MaxOutputTokens < 16 || in.MaxOutputTokens > 20000 {
		return errors.New("max_output_tokens must be 16..20000")
	}
	if requireKey && strings.TrimSpace(in.APIKey) == "" {
		return errors.New("api_key is required")
	}
	return nil
}

func (s *Service) ListConfigs(ctx context.Context) ([]ConfigPublic, error) {
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT id, name, base_url, model, timeout_seconds, max_output_tokens, enabled, created_at, updated_at
		 FROM ai_configs WHERE account_id = 1 ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ConfigPublic{}
	for rows.Next() {
		var c ConfigPublic
		if err := rows.Scan(&c.ID, &c.Name, &c.BaseURL, &c.Model, &c.TimeoutSeconds, &c.MaxOutputTokens, &c.Enabled, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, err
		}
		c.HasAPIKey = true
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Service) CreateConfig(ctx context.Context, in ConfigInput) (ConfigPublic, error) {
	if err := s.validateInput(in, true); err != nil {
		return ConfigPublic{}, err
	}
	enc, err := EncryptSecret(s.MasterKey, []byte(strings.TrimSpace(in.APIKey)))
	if err != nil {
		return ConfigPublic{}, err
	}
	id := uuid.NewString()
	_, err = s.Store.DB.ExecContext(ctx,
		`INSERT INTO ai_configs(id, account_id, name, base_url, model, api_key_ciphertext, timeout_seconds, max_output_tokens, enabled, created_at, updated_at)
		 VALUES(?, 1, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(6), UTC_TIMESTAMP(6))`,
		id, in.Name, strings.TrimRight(in.BaseURL, "/"), in.Model, enc, in.TimeoutSeconds, in.MaxOutputTokens, in.Enabled)
	if err != nil {
		return ConfigPublic{}, err
	}
	return s.getPublic(ctx, id)
}

func (s *Service) UpdateConfig(ctx context.Context, id string, in ConfigInput) (ConfigPublic, error) {
	if err := s.validateInput(in, false); err != nil {
		return ConfigPublic{}, err
	}
	if strings.TrimSpace(in.APIKey) != "" {
		enc, err := EncryptSecret(s.MasterKey, []byte(strings.TrimSpace(in.APIKey)))
		if err != nil {
			return ConfigPublic{}, err
		}
		_, err = s.Store.DB.ExecContext(ctx,
			`UPDATE ai_configs SET name=?, base_url=?, model=?, api_key_ciphertext=?, timeout_seconds=?, max_output_tokens=?, enabled=?, updated_at=UTC_TIMESTAMP(6)
			 WHERE id = ? AND account_id = 1`,
			in.Name, strings.TrimRight(in.BaseURL, "/"), in.Model, enc, in.TimeoutSeconds, in.MaxOutputTokens, in.Enabled, id)
		if err != nil {
			return ConfigPublic{}, err
		}
	} else {
		res, err := s.Store.DB.ExecContext(ctx,
			`UPDATE ai_configs SET name=?, base_url=?, model=?, timeout_seconds=?, max_output_tokens=?, enabled=?, updated_at=UTC_TIMESTAMP(6)
			 WHERE id = ? AND account_id = 1`,
			in.Name, strings.TrimRight(in.BaseURL, "/"), in.Model, in.TimeoutSeconds, in.MaxOutputTokens, in.Enabled, id)
		if err != nil {
			return ConfigPublic{}, err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ConfigPublic{}, sql.ErrNoRows
		}
	}
	return s.getPublic(ctx, id)
}

func (s *Service) DeleteConfig(ctx context.Context, id string) error {
	_, err := s.Store.DB.ExecContext(ctx, `DELETE FROM ai_configs WHERE id = ? AND account_id = 1`, id)
	return err
}

func (s *Service) getPublic(ctx context.Context, id string) (ConfigPublic, error) {
	var c ConfigPublic
	err := s.Store.DB.QueryRowContext(ctx,
		`SELECT id, name, base_url, model, timeout_seconds, max_output_tokens, enabled, created_at, updated_at
		 FROM ai_configs WHERE id = ? AND account_id = 1`, id).
		Scan(&c.ID, &c.Name, &c.BaseURL, &c.Model, &c.TimeoutSeconds, &c.MaxOutputTokens, &c.Enabled, &c.CreatedAt, &c.UpdatedAt)
	c.HasAPIKey = err == nil
	return c, err
}

func (s *Service) getSecret(ctx context.Context, id string) (configSecret, error) {
	var c configSecret
	var enc []byte
	err := s.Store.DB.QueryRowContext(ctx,
		`SELECT id, name, base_url, model, timeout_seconds, max_output_tokens, enabled, created_at, updated_at, api_key_ciphertext
		 FROM ai_configs WHERE id = ? AND account_id = 1`, id).
		Scan(&c.Public.ID, &c.Public.Name, &c.Public.BaseURL, &c.Public.Model, &c.Public.TimeoutSeconds,
			&c.Public.MaxOutputTokens, &c.Public.Enabled, &c.Public.CreatedAt, &c.Public.UpdatedAt, &enc)
	if err != nil {
		return configSecret{}, err
	}
	key, err := DecryptSecret(s.MasterKey, enc)
	if err != nil {
		return configSecret{}, err
	}
	c.APIKey = string(key)
	c.Public.HasAPIKey = true
	return c, nil
}

func (s *Service) TestConfig(ctx context.Context, id string) map[string]any {
	c, err := s.getSecret(ctx, id)
	if err != nil {
		return map[string]any{"ok": false, "code": "config_not_found", "message": "AI 配置不存在"}
	}
	res, err := CallChat(ctx, providerConfig(c), "You are a connectivity probe. Reply with exactly OK.", "Reply OK.", 16)
	if err != nil {
		out := map[string]any{"ok": false, "code": "provider_error", "message": err.Error()}
		var pe *ProviderError
		if errors.As(err, &pe) {
			out["code"] = pe.Code
			out["status"] = pe.Status
			out["uncertain"] = pe.Uncertain
		}
		return out
	}
	return map[string]any{
		"ok": true, "model": res.Model, "latency_checked": true,
		"usage": res.Usage, "sample": truncate(res.Text, 100),
	}
}

func providerConfig(c configSecret) ProviderConfig {
	return ProviderConfig{
		Name: c.Public.Name, BaseURL: c.Public.BaseURL, Model: c.Public.Model,
		APIKey: c.APIKey, Timeout: time.Duration(c.Public.TimeoutSeconds) * time.Second,
		MaxOutputTokens: c.Public.MaxOutputTokens,
	}
}

// TestDraft performs a real connection test before a config has been saved.
func (s *Service) TestDraft(ctx context.Context, in ConfigInput) map[string]any {
	if err := s.validateInput(in, true); err != nil {
		return map[string]any{"ok": false, "code": "invalid_config", "message": err.Error()}
	}
	c := configSecret{Public: ConfigPublic{Name: in.Name, BaseURL: strings.TrimRight(in.BaseURL, "/"), Model: in.Model, TimeoutSeconds: in.TimeoutSeconds, MaxOutputTokens: 16}, APIKey: in.APIKey}
	res, err := CallChat(ctx, providerConfig(c), "You are a connectivity probe. Reply with exactly OK.", "Reply OK.", 16)
	if err != nil {
		var pe *ProviderError
		out := map[string]any{"ok": false, "code": "provider_error", "message": err.Error()}
		if errors.As(err, &pe) {
			out["code"] = pe.Code
			out["status"] = pe.Status
			out["uncertain"] = pe.Uncertain
		}
		return out
	}
	return map[string]any{"ok": true, "model": res.Model, "usage": res.Usage}
}

func MarshalScope(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

func (s *Service) ConfigsForAPI(ctx context.Context) ([]ConfigPublic, error) {
	return s.ListConfigs(ctx)
}

var _ = fmt.Sprintf
