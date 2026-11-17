package ai

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/settings"
)

var (
	ErrDailyLimit = errors.New("daily AI call limit reached")
	ErrNoAIConfig = errors.New("no enabled AI configuration")
)

type Job struct {
	ID              string          `json:"id"`
	Kind            string          `json:"kind"`
	Status          string          `json:"status"`
	ConfigID        string          `json:"config_id"`
	ScheduledPeriod string          `json:"scheduled_period,omitempty"`
	Sources         json.RawMessage `json:"sources"`
	InputScope      json.RawMessage `json:"input_scope"`
	PromptText      string          `json:"prompt_text,omitempty"`
	ResultText      string          `json:"result_text,omitempty"`
	Model           string          `json:"model"`
	InputTokens     *int            `json:"input_tokens,omitempty"`
	OutputTokens    *int            `json:"output_tokens,omitempty"`
	ErrorCode       string          `json:"error_code,omitempty"`
	ErrorMessage    string          `json:"error_message,omitempty"`
	CreatedAt       time.Time       `json:"created_at"`
	StartedAt       *time.Time      `json:"started_at,omitempty"`
	FinishedAt      *time.Time      `json:"finished_at,omitempty"`
}

type ManualJobInput struct {
	ConfigID    string      `json:"config_id,omitempty"`
	Instruction string      `json:"instruction"`
	Sources     []SourceRef `json:"sources"`
}

type ReportVersion struct {
	ID          string          `json:"id"`
	JobID       string          `json:"job_id"`
	Kind        string          `json:"kind"`
	PeriodStart *time.Time      `json:"period_start,omitempty"`
	PeriodEnd   *time.Time      `json:"period_end,omitempty"`
	DataCutoff  time.Time       `json:"data_cutoff"`
	ResultText  string          `json:"result_text"`
	Sources     json.RawMessage `json:"sources"`
	CreatedAt   time.Time       `json:"created_at"`
}

type Worker struct {
	Service *Service
	Log     *slog.Logger
}

func (s *Service) pickConfigID(ctx context.Context, requested string) (string, error) {
	if requested != "" {
		var enabled bool
		err := s.Store.DB.QueryRowContext(ctx, `SELECT enabled FROM ai_configs WHERE id=? AND account_id=1`, requested).Scan(&enabled)
		if err != nil || !enabled {
			return "", ErrNoAIConfig
		}
		return requested, nil
	}
	st, err := (&settings.Service{Store: s.Store}).Get(ctx)
	if err != nil {
		return "", err
	}
	if st.DefaultAIConfigID != "" {
		var enabled bool
		if err := s.Store.DB.QueryRowContext(ctx, `SELECT enabled FROM ai_configs WHERE id=? AND account_id=1`, st.DefaultAIConfigID).Scan(&enabled); err == nil && enabled {
			return st.DefaultAIConfigID, nil
		}
	}
	var id string
	err = s.Store.DB.QueryRowContext(ctx, `SELECT id FROM ai_configs WHERE account_id=1 AND enabled=1 ORDER BY created_at LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNoAIConfig
	}
	return id, err
}

func (s *Service) DailyUsed(ctx context.Context) (int, error) {
	tz, err := s.Store.Timezone(ctx)
	if err != nil {
		return 0, err
	}
	loc := mustLocation(tz)
	now := time.Now().In(loc)
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc).UTC()
	var n int
	err = s.Store.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM ai_jobs WHERE account_id=1 AND created_at >= ?`, start).Scan(&n)
	return n, err
}

func (s *Service) checkDailyLimit(ctx context.Context) error {
	st, err := (&settings.Service{Store: s.Store}).Get(ctx)
	if err != nil {
		return err
	}
	if st.AIDailyLimit <= 0 {
		return nil
	}
	used, err := s.DailyUsed(ctx)
	if err != nil {
		return err
	}
	if used >= st.AIDailyLimit {
		return ErrDailyLimit
	}
	return nil
}

func (s *Service) CreateManualJob(ctx context.Context, in ManualJobInput) (Job, error) {
	if err := s.checkDailyLimit(ctx); err != nil {
		return Job{}, err
	}
	configID, err := s.pickConfigID(ctx, in.ConfigID)
	if err != nil {
		return Job{}, err
	}
	prompt, records, err := s.BuildManualPrompt(ctx, in.Instruction, in.Sources)
	if err != nil {
		return Job{}, err
	}
	tz, _ := s.Store.Timezone(ctx)
	scope := map[string]any{
		"kind": "manual", "data_cutoff": time.Now().UTC(), "timezone": tz,
		"source_count": len(records), "instruction": strings.TrimSpace(in.Instruction),
	}
	scopeRaw, _ := json.Marshal(scope)
	sourcesRaw, _ := json.Marshal(in.Sources)
	id := uuid.NewString()
	_, err = s.Store.DB.ExecContext(ctx,
		`INSERT INTO ai_jobs(id, account_id, kind, status, config_id, sources_json, input_scope_json, prompt_text, model, created_at)
		 VALUES(?, 1, 'manual', 'queued', ?, ?, ?, ?, '', UTC_TIMESTAMP(6))`,
		id, configID, sourcesRaw, scopeRaw, prompt)
	if err != nil {
		return Job{}, err
	}
	return s.GetJob(ctx, id)
}

func (s *Service) CreateReportJob(ctx context.Context, configID, kind, periodLabel string, start, end, cutoff time.Time, records []SourceRecord, scope ReportScope) (Job, bool, error) {
	if err := s.checkDailyLimit(ctx); err != nil {
		return Job{}, false, err
	}
	st, err := (&settings.Service{Store: s.Store}).Get(ctx)
	if err != nil {
		return Job{}, false, err
	}
	prompt := s.BuildReportPrompt(kind, scope.Timezone, records, scope)
	scopeData := map[string]any{
		"kind": kind, "period_start": start.UTC(), "period_end": end.UTC(), "data_cutoff": cutoff.UTC(),
		"timezone": scope.Timezone, "record_counts": scope.RecordCounts,
	}
	scopeRaw, _ := json.Marshal(scopeData)
	sourcesRaw, _ := json.Marshal(scope.Sources)
	id := uuid.NewString()
	res, err := s.Store.DB.ExecContext(ctx,
		`INSERT IGNORE INTO ai_jobs(id, account_id, kind, status, config_id, scheduled_period, sources_json, input_scope_json, prompt_text, model, created_at)
		 VALUES(?, 1, ?, 'queued', ?, ?, ?, ?, ?, '', UTC_TIMESTAMP(6))`,
		id, kind, configID, periodLabel, sourcesRaw, scopeRaw, prompt)
	if err != nil {
		return Job{}, false, err
	}
	n, _ := res.RowsAffected()
	_ = st
	if n == 0 {
		return Job{}, false, nil
	}
	job, err := s.GetJob(ctx, id)
	return job, true, err
}

func (s *Service) GetJob(ctx context.Context, id string) (Job, error) {
	row := s.Store.DB.QueryRowContext(ctx,
		`SELECT id, kind, status, config_id, scheduled_period, sources_json, input_scope_json,
		        COALESCE(prompt_text,''), COALESCE(result_text,''), model, input_tokens, output_tokens,
		        COALESCE(error_code,''), COALESCE(error_message,''), created_at, started_at, finished_at
		 FROM ai_jobs WHERE id=? AND account_id=1`, id)
	return scanJob(row)
}

func (s *Service) ListJobs(ctx context.Context, limit int) ([]Job, error) {
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT id, kind, status, config_id, scheduled_period, sources_json, input_scope_json,
		        COALESCE(prompt_text,''), COALESCE(result_text,''), model, input_tokens, output_tokens,
		        COALESCE(error_code,''), COALESCE(error_message,''), created_at, started_at, finished_at
		 FROM ai_jobs WHERE account_id=1 ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Job{}
	for rows.Next() {
		job, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, job)
	}
	return out, rows.Err()
}

type jobScanner interface{ Scan(dest ...any) error }

func scanJob(row jobScanner) (Job, error) {
	var job Job
	var period sql.NullString
	var sources, scope []byte
	var inTok, outTok sql.NullInt64
	var started, finished sql.NullTime
	err := row.Scan(&job.ID, &job.Kind, &job.Status, &job.ConfigID, &period, &sources, &scope,
		&job.PromptText, &job.ResultText, &job.Model, &inTok, &outTok,
		&job.ErrorCode, &job.ErrorMessage, &job.CreatedAt, &started, &finished)
	if err != nil {
		return Job{}, err
	}
	if period.Valid {
		job.ScheduledPeriod = period.String
	}
	job.Sources = json.RawMessage(sources)
	job.InputScope = json.RawMessage(scope)
	if inTok.Valid {
		v := int(inTok.Int64)
		job.InputTokens = &v
	}
	if outTok.Valid {
		v := int(outTok.Int64)
		job.OutputTokens = &v
	}
	if started.Valid {
		v := started.Time
		job.StartedAt = &v
	}
	if finished.Valid {
		v := finished.Time
		job.FinishedAt = &v
	}
	return job, nil
}

func (s *Service) RecoverInterrupted(ctx context.Context) error {
	_, err := s.Store.DB.ExecContext(ctx,
		`UPDATE ai_jobs SET status='uncertain', error_code='server_restarted',
		 error_message='服务器在请求进行中重启，无法确认供应商是否已处理；未自动重试。',
		 finished_at=UTC_TIMESTAMP(6)
		 WHERE status='running'`)
	return err
}

func (w *Worker) Run(ctx context.Context) {
	if w.Log == nil {
		w.Log = slog.Default()
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			for {
				job, err := w.claim(ctx)
				if err != nil {
					if !errors.Is(err, sql.ErrNoRows) {
						w.Log.Error("claim AI job", "error", err)
					}
					break
				}
				w.execute(ctx, job)
			}
		}
	}
}

func (w *Worker) claim(ctx context.Context) (Job, error) {
	tx, err := w.Service.Store.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return Job{}, err
	}
	defer tx.Rollback()
	var id string
	err = tx.QueryRowContext(ctx,
		`SELECT id FROM ai_jobs WHERE account_id=1 AND status='queued' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED`).Scan(&id)
	if err != nil {
		return Job{}, err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE ai_jobs SET status='running', started_at=UTC_TIMESTAMP(6) WHERE id=?`, id); err != nil {
		return Job{}, err
	}
	if err := tx.Commit(); err != nil {
		return Job{}, err
	}
	return w.Service.GetJob(ctx, id)
}

func (w *Worker) execute(ctx context.Context, job Job) {
	cfg, err := w.Service.getSecret(ctx, job.ConfigID)
	if err != nil {
		w.finishError(ctx, job.ID, "config_error", "AI 配置不存在或无法解密", false)
		return
	}
	system := "你是个人信息整理与复盘助手。只依据用户授权并已同步的记录工作。不得编造事实、不得改动原始记录、不得给用户打“决策能力”分数。明确区分事实、模式与待验证建议。"
	result, err := CallChat(ctx, providerConfig(cfg), system, job.PromptText, cfg.Public.MaxOutputTokens)
	if err != nil {
		var pe *ProviderError
		if errors.As(err, &pe) {
			w.finishError(ctx, job.ID, pe.Code, pe.Error(), pe.Uncertain)
			return
		}
		if errors.Is(err, context.DeadlineExceeded) {
			w.finishError(ctx, job.ID, "timeout", "AI 请求超时，供应商是否处理未知；未自动重试。", true)
			return
		}
		w.finishError(ctx, job.ID, "internal_error", err.Error(), true)
		return
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	_, err = w.Service.Store.DB.ExecContext(ctx,
		`UPDATE ai_jobs SET status='completed', result_text=?, model=?, input_tokens=?, output_tokens=?, finished_at=?
		 WHERE id=? AND status='running'`,
		result.Text, result.Model, nullInt(result.Usage.PromptTokens), nullInt(result.Usage.CompletionTokens), now, job.ID)
	if err != nil {
		w.Log.Error("save AI result", "job_id", job.ID, "error", err)
		return
	}
	if job.Kind == "daily" || job.Kind == "weekly" {
		var scope struct {
			PeriodStart time.Time `json:"period_start"`
			PeriodEnd   time.Time `json:"period_end"`
			DataCutoff  time.Time `json:"data_cutoff"`
		}
		_ = json.Unmarshal(job.InputScope, &scope)
		_, err := w.Service.Store.DB.ExecContext(ctx,
			`INSERT INTO report_versions(id, account_id, job_id, kind, period_start, period_end, data_cutoff, result_text, sources_json, created_at)
			 VALUES(?, 1, ?, ?, ?, ?, ?, ?, ?, ?)`,
			uuid.NewString(), job.ID, job.Kind, nullTime(scope.PeriodStart), nullTime(scope.PeriodEnd), scope.DataCutoff, result.Text, []byte(job.Sources), now)
		if err != nil {
			w.Log.Error("save report version", "job_id", job.ID, "error", err)
		}
	}
}

func nullInt(v int) any {
	if v == 0 {
		return nil
	}
	return v
}

func nullTime(v time.Time) any {
	if v.IsZero() {
		return nil
	}
	return v
}

func (w *Worker) finishError(ctx context.Context, jobID, code, message string, uncertain bool) {
	status := "failed"
	if uncertain {
		status = "uncertain"
	}
	if len(message) > 2000 {
		message = message[:2000]
	}
	_, err := w.Service.Store.DB.ExecContext(ctx,
		`UPDATE ai_jobs SET status=?, error_code=?, error_message=?, finished_at=UTC_TIMESTAMP(6)
		 WHERE id=? AND status='running'`, status, code, message, jobID)
	if err != nil {
		w.Log.Error("save AI job error", "job_id", jobID, "error", err)
	}
}

func (s *Service) ListReports(ctx context.Context, kind string, limit int) ([]ReportVersion, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	q := `SELECT id, job_id, kind, period_start, period_end, data_cutoff, result_text, sources_json, created_at
	      FROM report_versions WHERE account_id=1`
	args := []any{}
	if kind != "" {
		q += ` AND kind=?`
		args = append(args, kind)
	}
	q += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.Store.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReportVersion{}
	for rows.Next() {
		var r ReportVersion
		var start, end sql.NullTime
		var src []byte
		if err := rows.Scan(&r.ID, &r.JobID, &r.Kind, &start, &end, &r.DataCutoff, &r.ResultText, &src, &r.CreatedAt); err != nil {
			return nil, err
		}
		if start.Valid {
			v := start.Time
			r.PeriodStart = &v
		}
		if end.Valid {
			v := end.Time
			r.PeriodEnd = &v
		}
		r.Sources = json.RawMessage(src)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Service) PreviewManual(ctx context.Context, refs []SourceRef, instruction string) (map[string]any, error) {
	records, err := s.LoadSources(ctx, refs)
	if err != nil {
		return nil, err
	}
	prompt, _, err := s.BuildManualPrompt(ctx, instruction, refs)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"source_count": len(records),
		"sources":      records,
		"prompt_chars": len([]rune(prompt)),
		"prompt":       prompt,
	}, nil
}

var _ = fmt.Sprintf

// RegenerateReport creates a new immutable report version for the same period,
// using only data that is currently synchronized to the server. Old versions
// are never modified.
func (s *Service) RegenerateReport(ctx context.Context, reportID string) (Job, error) {
	var jobID, kind string
	var periodStart, periodEnd time.Time
	err := s.Store.DB.QueryRowContext(ctx,
		`SELECT job_id, kind, period_start, period_end FROM report_versions WHERE id=? AND account_id=1`,
		reportID).Scan(&jobID, &kind, &periodStart, &periodEnd)
	if err != nil {
		return Job{}, err
	}
	var configID string
	if err := s.Store.DB.QueryRowContext(ctx,
		`SELECT config_id FROM ai_jobs WHERE id=? AND account_id=1`, jobID).Scan(&configID); err != nil {
		return Job{}, err
	}
	st, err := (&settings.Service{Store: s.Store}).Get(ctx)
	if err != nil {
		return Job{}, err
	}
	tz, err := s.Store.Timezone(ctx)
	if err != nil {
		return Job{}, err
	}
	now := time.Now().UTC()
	records, scope, err := s.CollectReportSources(ctx, st, kind, periodStart, periodEnd, now, tz)
	if err != nil {
		return Job{}, err
	}
	label := "regen:" + uuid.NewString()
	job, _, err := s.CreateReportJob(ctx, configID, kind, label, periodStart, periodEnd, now, records, scope)
	return job, err
}
