package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/t5plan/t5/server/internal/ai"
	"github.com/t5plan/t5/server/internal/auth"
	"github.com/t5plan/t5/server/internal/config"
	"github.com/t5plan/t5/server/internal/focus"
	"github.com/t5plan/t5/server/internal/settings"
	"github.com/t5plan/t5/server/internal/store"
	"github.com/t5plan/t5/server/internal/sync"
	"github.com/t5plan/t5/server/internal/updates"
)

type Server struct {
	Config   config.Config
	Store    *store.Store
	Auth     *auth.Service
	Sync     *sync.Service
	Focus    *focus.Service
	AI       *ai.Service
	Settings *settings.Service
	Updates  *updates.Service
	Log      *slog.Logger
}

func New(cfg config.Config, st *store.Store, log *slog.Logger) *Server {
	return &Server{
		Config:   cfg,
		Store:    st,
		Auth:     &auth.Service{Store: st, TTL: cfg.PairingTTL},
		Sync:     &sync.Service{Store: st},
		Focus:    &focus.Service{Store: st},
		AI:       &ai.Service{Store: st, MasterKey: cfg.MasterKey},
		Settings: &settings.Service{Store: st},
		Updates:  &updates.Service{Store: st},
		Log:      log,
	}
}

type ctxKey string

const deviceKey ctxKey = "device"

func deviceFrom(ctx context.Context) auth.Device {
	d, _ := ctx.Value(deviceKey).(auth.Device)
	return d
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /api/v1/healthz", s.health)
	mux.HandleFunc("GET /api/v1/readyz", s.ready)
	mux.HandleFunc("GET /api/v1/openapi.yaml", s.openapiFile)
	mux.HandleFunc("POST /api/v1/devices/pair", s.pairDevice)
	mux.HandleFunc("GET /api/v1/app-updates/latest", s.latestAppUpdate)

	authed := http.NewServeMux()
	authed.HandleFunc("POST /api/v1/devices/pairing-code", s.createPairingCode)
	authed.HandleFunc("GET /api/v1/devices", s.listDevices)
	authed.HandleFunc("DELETE /api/v1/devices/{id}", s.revokeDevice)
	authed.HandleFunc("POST /api/v1/sync/push", s.syncPush)
	authed.HandleFunc("GET /api/v1/sync/changes", s.syncChanges)
	authed.HandleFunc("GET /api/v1/sync/bootstrap", s.syncBootstrap)
	authed.HandleFunc("GET /api/v1/focus/current", s.focusCurrent)
	authed.HandleFunc("POST /api/v1/focus/commands", s.focusCommand)
	authed.HandleFunc("GET /api/v1/settings", s.getSettings)
	authed.HandleFunc("PUT /api/v1/settings", s.putSettings)
	authed.HandleFunc("GET /api/v1/ai/configs", s.listAIConfigs)
	authed.HandleFunc("POST /api/v1/ai/configs", s.createAIConfig)
	authed.HandleFunc("POST /api/v1/ai/configs/test", s.testAIDraft)
	authed.HandleFunc("PATCH /api/v1/ai/configs/{id}", s.updateAIConfig)
	authed.HandleFunc("DELETE /api/v1/ai/configs/{id}", s.deleteAIConfig)
	authed.HandleFunc("POST /api/v1/ai/configs/{id}/test", s.testAIConfig)
	authed.HandleFunc("POST /api/v1/ai/assist/preview", s.previewAssist)
	authed.HandleFunc("POST /api/v1/ai/jobs", s.createAIJob)
	authed.HandleFunc("GET /api/v1/ai/jobs", s.listAIJobs)
	authed.HandleFunc("GET /api/v1/ai/jobs/{id}", s.getAIJob)
	authed.HandleFunc("GET /api/v1/ai/reports", s.listReports)
	authed.HandleFunc("GET /api/v1/app-updates", s.listAppUpdates)
	authed.HandleFunc("POST /api/v1/app-updates", s.publishAppUpdate)
	authed.HandleFunc("DELETE /api/v1/app-updates/{id}", s.deleteAppUpdate)
	authed.HandleFunc("POST /api/v1/ai/reports/{id}/regenerate", s.regenerateReport)
	mux.Handle("/api/v1/", s.requireAuth(authed))
	return s.recoverPanic(s.requestLog(mux))
}

func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing bearer token", nil)
			return
		}
		dev, err := s.Auth.Authenticate(r.Context(), strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
		if err != nil {
			if errors.Is(err, auth.ErrUnauthorized) {
				writeError(w, http.StatusUnauthorized, "unauthorized", "device token is invalid or revoked", nil)
			} else {
				writeError(w, http.StatusInternalServerError, "internal_error", "authentication failed", nil)
			}
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey, dev)))
	})
}

func (s *Server) recoverPanic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.Log.Error("panic recovered", "path", r.URL.Path, "panic", v)
				writeError(w, http.StatusInternalServerError, "internal_error", "internal server error", nil)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		s.Log.Info("http", "method", r.Method, "path", r.URL.Path, "status", rec.status, "duration_ms", time.Since(start).Milliseconds())
	})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "service": "t5d"})
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.Store.Ready(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "not_ready", "database or migrations unavailable", map[string]any{"detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ready", "database": "ok", "migrations": "current"})
}

func clientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) createPairingCode(w http.ResponseWriter, r *http.Request) {
	if err := s.Auth.InvalidateOpenCodes(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "pairing_failed", "cannot invalidate old pairing codes", nil)
		return
	}
	code, expires, err := s.Auth.CreatePairingCode(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "pairing_failed", "cannot create pairing code", nil)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"pairing_code":       code,
		"expires_at":         expires,
		"expires_in_seconds": int(time.Until(expires).Seconds()),
		"code_length":        6,
	})
}

func (s *Server) pairDevice(w http.ResponseWriter, r *http.Request) {
	var in struct {
		PairingToken string `json:"pairing_token"`
		PairingCode  string `json:"pairing_code"`
		DeviceName   string `json:"device_name"`
		Platform     string `json:"platform"`
	}
	if !decodeJSON(w, r, &in) {
		return
	}
	if !s.Auth.AllowPairAttempt(clientKey(r)) {
		writeError(w, http.StatusTooManyRequests, "pairing_rate_limited", "too many pairing attempts; try again later", nil)
		return
	}
	code := in.PairingCode
	if code == "" {
		code = in.PairingToken
	}
	dev, token, err := s.Auth.Pair(r.Context(), code, in.DeviceName, in.Platform)
	if err != nil {
		if errors.Is(err, auth.ErrInvalidCode) {
			writeError(w, http.StatusUnauthorized, "invalid_pairing_code", err.Error(), nil)
		} else {
			writeError(w, http.StatusBadRequest, "pairing_failed", err.Error(), nil)
		}
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"device": dev, "device_token": token})
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := s.Auth.ListDevices(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "cannot list devices", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_device", "device id is required", nil)
		return
	}
	if err := s.Auth.RevokeDevice(r.Context(), id); err != nil {
		writeError(w, http.StatusNotFound, "device_not_found", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Server) syncPush(w http.ResponseWriter, r *http.Request) {
	var req sync.PushRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Operations) > s.Config.SyncBatchLimit {
		writeError(w, http.StatusBadRequest, "batch_too_large", fmt.Sprintf("at most %d operations per request", s.Config.SyncBatchLimit), nil)
		return
	}
	dev := deviceFrom(r.Context())
	resp, err := s.Sync.Push(r.Context(), dev.ID, req)
	if err != nil {
		switch {
		case errors.Is(err, sync.ErrOperationIDReuse):
			writeError(w, http.StatusConflict, "operation_id_reuse", "operation_id was reused with a different payload", nil)
		case sync.IsValidationError(err):
			writeError(w, http.StatusBadRequest, "invalid_operation", err.Error(), nil)
		default:
			s.Log.Error("sync push", "error", err)
			writeError(w, http.StatusInternalServerError, "sync_failed", "sync push failed", nil)
		}
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) syncChanges(w http.ResponseWriter, r *http.Request) {
	cursor, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	generation := r.URL.Query().Get("generation")
	if limit == 0 {
		limit = s.Config.ChangesPageLimit
	}
	resp, err := s.Sync.Changes(r.Context(), generation, cursor, limit)
	if err != nil {
		if errors.Is(err, sync.ErrGenerationMismatch) {
			writeError(w, http.StatusConflict, "generation_mismatch", "server sync generation changed; preserve local data and bootstrap again", map[string]any{"generation": resp.Generation})
			return
		}
		s.Log.Error("sync changes", "error", err)
		writeError(w, http.StatusInternalServerError, "sync_failed", "cannot read changes", nil)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) syncBootstrap(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	resp, err := s.Sync.Bootstrap(r.Context(), r.URL.Query().Get("after_type"), r.URL.Query().Get("after_id"), limit)
	if err != nil {
		s.Log.Error("sync bootstrap", "error", err)
		writeError(w, http.StatusInternalServerError, "sync_failed", "cannot bootstrap", nil)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) focusCurrent(w http.ResponseWriter, r *http.Request) {
	resp, err := s.Focus.Current(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "focus_failed", "cannot read focus session", nil)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) focusCommand(w http.ResponseWriter, r *http.Request) {
	var req focus.CommandRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	dev := deviceFrom(r.Context())
	resp, err := s.Focus.Command(r.Context(), dev.ID, req)
	if err != nil {
		switch {
		case errors.Is(err, focus.ErrActiveSession):
			writeError(w, http.StatusConflict, "active_session", "an active focus session already exists", nil)
		case errors.Is(err, focus.ErrVersionStale):
			writeError(w, http.StatusConflict, "version_stale", "focus session changed; refresh first", nil)
		case errors.Is(err, focus.ErrNotController):
			writeError(w, http.StatusConflict, "not_controller", "another device currently controls this session", nil)
		case errors.Is(err, focus.ErrInvalidCommand):
			writeError(w, http.StatusBadRequest, "invalid_command", err.Error(), nil)
		default:
			s.Log.Error("focus command", "error", err)
			writeError(w, http.StatusInternalServerError, "focus_failed", "focus command failed", nil)
		}
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	st, err := s.Settings.Get(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "settings_failed", "cannot read settings", nil)
		return
	}
	tz, _ := s.Store.Timezone(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"timezone": tz, "settings": st})
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Timezone string            `json:"timezone"`
		Settings settings.Settings `json:"settings"`
	}
	if !decodeJSON(w, r, &in) {
		return
	}
	if in.Timezone != "" {
		if _, err := time.LoadLocation(in.Timezone); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_timezone", "timezone must be an IANA timezone name", nil)
			return
		}
		if err := s.Store.SetTimezone(r.Context(), in.Timezone); err != nil {
			writeError(w, http.StatusInternalServerError, "settings_failed", "cannot update timezone", nil)
			return
		}
	}
	st, err := s.Settings.Put(r.Context(), in.Settings)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_settings", err.Error(), nil)
		return
	}
	tz, _ := s.Store.Timezone(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"timezone": tz, "settings": st})
}

func (s *Server) listAIConfigs(w http.ResponseWriter, r *http.Request) {
	configs, err := s.AI.ListConfigs(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ai_config_failed", "cannot list AI configs", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"configs": configs})
}

func (s *Server) createAIConfig(w http.ResponseWriter, r *http.Request) {
	var in ai.ConfigInput
	if !decodeJSON(w, r, &in) {
		return
	}
	cfg, err := s.AI.CreateConfig(r.Context(), in)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_ai_config", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusCreated, cfg)
}

func (s *Server) updateAIConfig(w http.ResponseWriter, r *http.Request) {
	var in ai.ConfigInput
	if !decodeJSON(w, r, &in) {
		return
	}
	cfg, err := s.AI.UpdateConfig(r.Context(), r.PathValue("id"), in)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "ai_config_not_found", "AI config not found", nil)
		} else {
			writeError(w, http.StatusBadRequest, "invalid_ai_config", err.Error(), nil)
		}
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

func (s *Server) deleteAIConfig(w http.ResponseWriter, r *http.Request) {
	if err := s.AI.DeleteConfig(r.Context(), r.PathValue("id")); err != nil {
		writeError(w, http.StatusInternalServerError, "ai_config_failed", "cannot delete AI config", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

func (s *Server) testAIConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.AI.TestConfig(r.Context(), r.PathValue("id")))
}

func (s *Server) testAIDraft(w http.ResponseWriter, r *http.Request) {
	var in ai.ConfigInput
	if !decodeJSON(w, r, &in) {
		return
	}
	writeJSON(w, http.StatusOK, s.AI.TestDraft(r.Context(), in))
}

func (s *Server) previewAssist(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Instruction string         `json:"instruction"`
		Sources     []ai.SourceRef `json:"sources"`
	}
	if !decodeJSON(w, r, &in) {
		return
	}
	out, err := s.AI.PreviewManual(r.Context(), in.Sources, in.Instruction)
	if err != nil {
		if errors.Is(err, ai.ErrSourceNotFound) {
			writeError(w, http.StatusConflict, "source_not_available", "some selected records are not synced to the server", nil)
		} else {
			writeError(w, http.StatusBadRequest, "preview_failed", err.Error(), nil)
		}
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) createAIJob(w http.ResponseWriter, r *http.Request) {
	var in ai.ManualJobInput
	if !decodeJSON(w, r, &in) {
		return
	}
	job, err := s.AI.CreateManualJob(r.Context(), in)
	if err != nil {
		switch {
		case errors.Is(err, ai.ErrDailyLimit):
			writeError(w, http.StatusTooManyRequests, "daily_limit", "daily AI call limit reached", nil)
		case errors.Is(err, ai.ErrNoAIConfig):
			writeError(w, http.StatusConflict, "ai_not_configured", "no enabled AI configuration", nil)
		case errors.Is(err, ai.ErrSourceNotFound):
			writeError(w, http.StatusConflict, "source_not_available", "some selected records are not synced to the server", nil)
		default:
			writeError(w, http.StatusBadRequest, "ai_job_failed", err.Error(), nil)
		}
		return
	}
	writeJSON(w, http.StatusAccepted, job)
}

func (s *Server) listAIJobs(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	jobs, err := s.AI.ListJobs(r.Context(), limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ai_jobs_failed", "cannot list AI jobs", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"jobs": jobs})
}

func (s *Server) getAIJob(w http.ResponseWriter, r *http.Request) {
	job, err := s.AI.GetJob(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "ai_job_not_found", "AI job not found", nil)
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (s *Server) listReports(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	reports, err := s.AI.ListReports(r.Context(), r.URL.Query().Get("kind"), limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "reports_failed", "cannot list reports", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": reports})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must be valid JSON", map[string]any{"detail": err.Error()})
		return false
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must contain exactly one JSON value", nil)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string, details any) {
	payload := map[string]any{"error": code, "message": message}
	if details != nil {
		payload["details"] = details
	}
	writeJSON(w, status, payload)
}

func (s *Server) regenerateReport(w http.ResponseWriter, r *http.Request) {
	job, err := s.AI.RegenerateReport(r.Context(), r.PathValue("id"))
	if err != nil {
		switch {
		case errors.Is(err, ai.ErrDailyLimit):
			writeError(w, http.StatusTooManyRequests, "daily_limit", "daily AI call limit reached", nil)
		case errors.Is(err, ai.ErrNoAIConfig):
			writeError(w, http.StatusConflict, "ai_not_configured", "no enabled AI configuration", nil)
		default:
			writeError(w, http.StatusBadRequest, "regenerate_failed", err.Error(), nil)
		}
		return
	}
	writeJSON(w, http.StatusAccepted, job)
}

func (s *Server) latestAppUpdate(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	current := r.URL.Query().Get("current_version")
	channel := r.URL.Query().Get("channel")
	resp, err := s.Updates.Latest(r.Context(), platform, current, channel)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_update_query", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) listAppUpdates(w http.ResponseWriter, r *http.Request) {
	releases, err := s.Updates.List(r.Context(), r.URL.Query().Get("platform"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "updates_failed", "cannot list app updates", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"releases": releases})
}

func (s *Server) publishAppUpdate(w http.ResponseWriter, r *http.Request) {
	var in updates.PublishInput
	if !decodeJSON(w, r, &in) {
		return
	}
	release, err := s.Updates.Publish(r.Context(), in)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_release", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusCreated, release)
}

func (s *Server) deleteAppUpdate(w http.ResponseWriter, r *http.Request) {
	if err := s.Updates.Delete(r.Context(), r.PathValue("id")); err != nil {
		writeError(w, http.StatusNotFound, "release_not_found", "release not found", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
}
