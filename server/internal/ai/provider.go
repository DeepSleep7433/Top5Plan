package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type ProviderConfig struct {
	Name            string
	BaseURL         string
	Model           string
	APIKey          string
	Timeout         time.Duration
	MaxOutputTokens int
}

type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type ChatResult struct {
	Text  string
	Model string
	Usage Usage
}

type ProviderError struct {
	Status     int
	Code       string
	Message    string
	Uncertain  bool
	RetryAfter time.Duration
}

func (e *ProviderError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("AI provider error (%d): %s", e.Status, e.Message)
	}
	return fmt.Sprintf("AI provider error (%d)", e.Status)
}

func chatCompletionsURL(base string) (string, error) {
	base = strings.TrimRight(strings.TrimSpace(base), "/")
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return "", errors.New("invalid API base URL")
	}
	if strings.HasSuffix(base, "/chat/completions") {
		return base, nil
	}
	return base + "/chat/completions", nil
}

func CallChat(ctx context.Context, cfg ProviderConfig, systemPrompt, userPrompt string, maxTokens int) (ChatResult, error) {
	endpoint, err := chatCompletionsURL(cfg.BaseURL)
	if err != nil {
		return ChatResult{}, err
	}
	if cfg.Timeout <= 0 || cfg.Timeout > 10*time.Minute {
		cfg.Timeout = 120 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	body := map[string]any{
		"model": cfg.Model,
		"messages": []map[string]string{
			{"role": "system", "content": systemPrompt},
			{"role": "user", "content": userPrompt},
		},
		"temperature": 0.2,
		"stream":      false,
	}
	if maxTokens <= 0 || maxTokens > cfg.MaxOutputTokens {
		maxTokens = cfg.MaxOutputTokens
	}
	if maxTokens > 0 {
		body["max_tokens"] = maxTokens
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return ChatResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	req.Header.Set("Accept", "application/json")
	client := &http.Client{Timeout: cfg.Timeout}
	resp, err := client.Do(req)
	if err != nil {
		return ChatResult{}, &ProviderError{
			Status:    0,
			Code:      "network_error",
			Message:   "provider request failed",
			Uncertain: true,
		}
	}
	defer resp.Body.Close()
	limited := io.LimitReader(resp.Body, 2<<20)
	responseBody, _ := io.ReadAll(limited)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		pe := &ProviderError{Status: resp.StatusCode, Code: "http_error"}
		switch {
		case resp.StatusCode == http.StatusUnauthorized:
			pe.Code = "unauthorized"
			pe.Message = "provider rejected the API key"
		case resp.StatusCode == http.StatusTooManyRequests:
			pe.Code = "rate_limited"
			pe.Message = "provider rate limit reached"
			pe.RetryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
		case resp.StatusCode >= 500:
			pe.Code = "provider_unavailable"
			pe.Message = "provider returned a server error"
			pe.Uncertain = true
		default:
			var e struct {
				Error struct {
					Message string `json:"message"`
					Type    string `json:"type"`
				} `json:"error"`
			}
			_ = json.Unmarshal(responseBody, &e)
			if e.Error.Message != "" {
				pe.Message = truncate(e.Error.Message, 300)
			} else {
				pe.Message = fmt.Sprintf("provider returned HTTP %d", resp.StatusCode)
			}
		}
		return ChatResult{}, pe
	}
	var out struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage Usage `json:"usage"`
	}
	if err := json.Unmarshal(responseBody, &out); err != nil {
		return ChatResult{}, &ProviderError{Status: resp.StatusCode, Code: "invalid_response", Message: "provider returned invalid JSON", Uncertain: true}
	}
	if len(out.Choices) == 0 || strings.TrimSpace(out.Choices[0].Message.Content) == "" {
		return ChatResult{}, &ProviderError{Status: resp.StatusCode, Code: "empty_result", Message: "provider returned an empty result"}
	}
	model := out.Model
	if model == "" {
		model = cfg.Model
	}
	return ChatResult{Text: out.Choices[0].Message.Content, Model: model, Usage: out.Usage}, nil
}

func parseRetryAfter(v string) time.Duration {
	if v == "" {
		return 0
	}
	if d, err := time.ParseDuration(v + "s"); err == nil {
		return d
	}
	if t, err := http.ParseTime(v); err == nil {
		if d := time.Until(t); d > 0 {
			return d
		}
	}
	return 0
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
