package settings

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/t5plan/t5/server/internal/store"
)

type Settings struct {
	AIDailyLimit        int      `json:"ai_daily_limit"`
	DailyReportEnabled  bool     `json:"daily_report_enabled"`
	DailyReportTime     string   `json:"daily_report_time"`
	WeeklyReportEnabled bool     `json:"weekly_report_enabled"`
	WeeklyReportTime    string   `json:"weekly_report_time"`
	ExcludedLists       []string `json:"excluded_lists"`
	ExcludedEntityIDs   []string `json:"excluded_entity_ids"`
	DefaultAIConfigID   string   `json:"default_ai_config_id,omitempty"`
}

type Service struct{ Store *store.Store }

var timePattern = regexp.MustCompile(`^([01]\d|2[0-3]):[0-5]\d$`)

func Default() Settings {
	return Settings{
		AIDailyLimit:      20,
		DailyReportTime:   "21:00",
		WeeklyReportTime:  "21:30",
		ExcludedLists:     []string{},
		ExcludedEntityIDs: []string{},
	}
}

func (s *Service) Get(ctx context.Context) (Settings, error) {
	var raw []byte
	err := s.Store.DB.QueryRowContext(ctx, `SELECT settings_json FROM account_settings WHERE account_id = 1`).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return Default(), nil
	}
	if err != nil {
		return Settings{}, err
	}
	out := Default()
	if err := json.Unmarshal(raw, &out); err != nil {
		return Settings{}, err
	}
	return out, nil
}

func (s *Service) Put(ctx context.Context, in Settings) (Settings, error) {
	if in.AIDailyLimit < 0 || in.AIDailyLimit > 1000 {
		return Settings{}, errors.New("ai_daily_limit must be 0..1000")
	}
	if !timePattern.MatchString(in.DailyReportTime) || !timePattern.MatchString(in.WeeklyReportTime) {
		return Settings{}, errors.New("report time must be HH:MM")
	}
	if in.ExcludedLists == nil {
		in.ExcludedLists = []string{}
	}
	if in.ExcludedEntityIDs == nil {
		in.ExcludedEntityIDs = []string{}
	}
	raw, _ := json.Marshal(in)
	_, err := s.Store.DB.ExecContext(ctx,
		`INSERT INTO account_settings(account_id, settings_json, updated_at) VALUES(1, ?, UTC_TIMESTAMP(6))
		 ON DUPLICATE KEY UPDATE settings_json = VALUES(settings_json), updated_at = VALUES(updated_at)`, raw)
	return in, err
}

func (s *Service) Preview(candidate Settings) (Settings, error) {
	cur, err := s.Get(context.Background())
	if err != nil {
		return Settings{}, err
	}
	if candidate.AIDailyLimit == 0 {
		candidate.AIDailyLimit = cur.AIDailyLimit
	}
	if candidate.DailyReportTime == "" {
		candidate.DailyReportTime = cur.DailyReportTime
	}
	if candidate.WeeklyReportTime == "" {
		candidate.WeeklyReportTime = cur.WeeklyReportTime
	}
	return candidate, nil
}

func ParseHHMM(v string) (hour, minute int, err error) {
	if !timePattern.MatchString(v) {
		return 0, 0, fmt.Errorf("invalid HH:MM value %q", v)
	}
	_, err = fmt.Sscanf(v, "%d:%d", &hour, &minute)
	return hour, minute, err
}

func DateInTimezone(t time.Time, tz string) time.Time {
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.FixedZone("CST", 8*3600)
	}
	return t.In(loc)
}
