package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEncryptSecretRoundTripAndTamper(t *testing.T) {
	key := []byte("0123456789abcdef0123456789abcdef")
	enc, err := EncryptSecret(key, []byte("sk-private"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(enc), "sk-private") {
		t.Fatal("plaintext leaked into ciphertext")
	}
	plain, err := DecryptSecret(key, enc)
	if err != nil || string(plain) != "sk-private" {
		t.Fatalf("decrypt: %q %v", plain, err)
	}
	enc[len(enc)-1] ^= 1
	if _, err := DecryptSecret(key, enc); err == nil {
		t.Fatal("tampered ciphertext accepted")
	}
}

func TestOpenAICompatibleProvider(t *testing.T) {
	var gotAuth string
	var gotMax int
	var gotModel string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Errorf("path = %s", r.URL.Path)
		}
		gotAuth = r.Header.Get("Authorization")
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotMax = int(body["max_tokens"].(float64))
		gotModel = body["model"].(string)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"model":"mock-model","choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}`))
	}))
	defer server.Close()
	result, err := CallChat(context.Background(), ProviderConfig{
		BaseURL: server.URL + "/v1", Model: "test-model", APIKey: "sk-test",
		Timeout: 5 * time.Second, MaxOutputTokens: 2000,
	}, "system", "user", 100)
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "OK" || result.Model != "mock-model" || result.Usage.TotalTokens != 9 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if gotAuth != "Bearer sk-test" || gotMax != 100 || gotModel != "test-model" {
		t.Fatalf("request auth=%q max=%d model=%q", gotAuth, gotMax, gotModel)
	}
}

func TestProviderErrorsAreClassified(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"bad key"}}`))
	}))
	defer server.Close()
	_, err := CallChat(context.Background(), ProviderConfig{
		BaseURL: server.URL, Model: "m", APIKey: "x", Timeout: 5 * time.Second, MaxOutputTokens: 100,
	}, "s", "u", 10)
	pe, ok := err.(*ProviderError)
	if !ok || pe.Code != "unauthorized" || pe.Status != 401 {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func TestProviderTimeoutIsUncertain(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(400 * time.Millisecond)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"late"}}]}`))
	}))
	defer server.Close()
	_, err := CallChat(context.Background(), ProviderConfig{
		BaseURL: server.URL, Model: "m", APIKey: "x", Timeout: 80 * time.Millisecond, MaxOutputTokens: 100,
	}, "s", "u", 10)
	pe, ok := err.(*ProviderError)
	if !ok || !pe.Uncertain {
		t.Fatalf("timeout should be uncertain: %#v", err)
	}
}

func TestProviderRateLimitAndEmptyResult(t *testing.T) {
	rate := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "3")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"message":"rate"}}`))
	}))
	defer rate.Close()
	_, err := CallChat(context.Background(), ProviderConfig{
		BaseURL: rate.URL, Model: "m", APIKey: "x", Timeout: 5 * time.Second, MaxOutputTokens: 100,
	}, "s", "u", 10)
	pe, ok := err.(*ProviderError)
	if !ok || pe.Code != "rate_limited" || pe.RetryAfter != 3*time.Second {
		t.Fatalf("rate limit classification: %#v", err)
	}

	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[]}`))
	}))
	defer empty.Close()
	_, err = CallChat(context.Background(), ProviderConfig{
		BaseURL: empty.URL, Model: "m", APIKey: "x", Timeout: 5 * time.Second, MaxOutputTokens: 100,
	}, "s", "u", 10)
	pe, ok = err.(*ProviderError)
	if !ok || pe.Code != "empty_result" {
		t.Fatalf("empty result classification: %#v", err)
	}
}
