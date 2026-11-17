package ai

import (
	"testing"
	"time"
)

func mustLoc(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return loc
}

func TestLatestDailyUsesMostRecentScheduledTime(t *testing.T) {
	loc := mustLoc(t, "Asia/Shanghai")
	now := time.Date(2026, 11, 16, 20, 0, 0, 0, loc)
	start, end, due, label := latestDaily(now, "Asia/Shanghai", 21, 0)
	if label != "2026-11-15" {
		t.Fatalf("label = %s", label)
	}
	if !due.Equal(time.Date(2026, 11, 15, 21, 0, 0, 0, loc)) {
		t.Fatalf("due = %s", due)
	}
	if end.Sub(start) != 24*time.Hour {
		t.Fatalf("period = %v", end.Sub(start))
	}

	now = time.Date(2026, 11, 16, 21, 30, 0, 0, loc)
	_, _, _, label = latestDaily(now, "Asia/Shanghai", 21, 0)
	if label != "2026-11-16" {
		t.Fatalf("label after due = %s", label)
	}
}

func TestLatestWeeklyUsesISOWeekAndPriorSunday(t *testing.T) {
	loc := mustLoc(t, "Asia/Shanghai")
	// Monday 2026-11-16 before the next Sunday report: latest is Sunday the 15th.
	now := time.Date(2026, 11, 16, 10, 0, 0, 0, loc)
	start, end, _, label := latestWeekly(now, "Asia/Shanghai", 21, 30)
	if label != "2026-W46" {
		t.Fatalf("label = %s", label)
	}
	if start.In(loc).Weekday() != time.Monday || start.In(loc).Hour() != 0 {
		t.Fatalf("start = %s", start.In(loc))
	}
	if end.Sub(start) != 7*24*time.Hour {
		t.Fatalf("period = %v", end.Sub(start))
	}
}
