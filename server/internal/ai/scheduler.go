package ai

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/t5plan/t5/server/internal/settings"
)

type Scheduler struct {
	Service *Service
	Log     *slog.Logger
}

func (s *Scheduler) Run(ctx context.Context) {
	if s.Log == nil {
		s.Log = slog.Default()
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if err := s.tick(ctx); err != nil {
				s.Log.Error("report scheduler", "error", err)
			}
			timer.Reset(30 * time.Second)
		}
	}
}

func (s *Scheduler) tick(ctx context.Context) error {
	st, err := (&settings.Service{Store: s.Service.Store}).Get(ctx)
	if err != nil {
		return err
	}
	if !st.DailyReportEnabled && !st.WeeklyReportEnabled {
		return nil
	}
	configID, err := s.Service.pickConfigID(ctx, st.DefaultAIConfigID)
	if err != nil {
		if errors.Is(err, ErrNoAIConfig) {
			return nil
		}
		return err
	}
	tz, err := s.Service.Store.Timezone(ctx)
	if err != nil {
		return err
	}
	now := time.Now()
	if st.DailyReportEnabled {
		h, m, _ := settings.ParseHHMM(st.DailyReportTime)
		start, end, due, label := latestDaily(now, tz, h, m)
		records, scope, err := s.Service.CollectReportSources(ctx, st, "daily", start, end, now.UTC(), tz)
		if err != nil {
			return err
		}
		_, created, err := s.Service.CreateReportJob(ctx, configID, "daily", label, start, end, now.UTC(), records, scope)
		if err != nil && !errors.Is(err, ErrDailyLimit) {
			return err
		}
		if created {
			s.Log.Info("daily report queued", "period", label, "due", due, "sources", len(records))
		}
	}
	if st.WeeklyReportEnabled {
		h, m, _ := settings.ParseHHMM(st.WeeklyReportTime)
		start, end, due, label := latestWeekly(now, tz, h, m)
		records, scope, err := s.Service.CollectReportSources(ctx, st, "weekly", start, end, now.UTC(), tz)
		if err != nil {
			return err
		}
		_, created, err := s.Service.CreateReportJob(ctx, configID, "weekly", label, start, end, now.UTC(), records, scope)
		if err != nil && !errors.Is(err, ErrDailyLimit) {
			return err
		}
		if created {
			s.Log.Info("weekly report queued", "period", label, "due", due, "sources", len(records))
		}
	}
	return nil
}

func latestDaily(now time.Time, tz string, hour, minute int) (start, end, due time.Time, label string) {
	loc := mustLocation(tz)
	localNow := now.In(loc)
	due = time.Date(localNow.Year(), localNow.Month(), localNow.Day(), hour, minute, 0, 0, loc)
	if localNow.Before(due) {
		due = due.AddDate(0, 0, -1)
	}
	start = time.Date(due.Year(), due.Month(), due.Day(), 0, 0, 0, 0, loc)
	end = start.AddDate(0, 0, 1)
	label = start.Format("2006-01-02")
	return start.UTC(), end.UTC(), due, label
}

func latestWeekly(now time.Time, tz string, hour, minute int) (start, end, due time.Time, label string) {
	loc := mustLocation(tz)
	localNow := now.In(loc)
	daysSinceSunday := int(localNow.Weekday())
	due = time.Date(localNow.Year(), localNow.Month(), localNow.Day(), hour, minute, 0, 0, loc).AddDate(0, 0, -daysSinceSunday)
	if localNow.Before(due) {
		due = due.AddDate(0, 0, -7)
	}
	monday := due.AddDate(0, 0, -6)
	start = time.Date(monday.Year(), monday.Month(), monday.Day(), 0, 0, 0, 0, loc)
	end = start.AddDate(0, 0, 7)
	year, week := start.ISOWeek()
	label = time.Date(year, 1, 4, 0, 0, 0, 0, time.UTC).Format("2006") + "-W" + pad2(week)
	return start.UTC(), end.UTC(), due, label
}

func pad2(v int) string {
	if v < 10 {
		return "0" + string(rune('0'+v))
	}
	return string(rune('0'+v/10)) + string(rune('0'+v%10))
}
