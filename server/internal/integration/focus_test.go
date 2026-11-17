package integration

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/t5plan/t5/server/internal/focus"
)

func TestSharedFocusTakeoverAndVersionChecks(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &focus.Service{Store: st}
	deviceA := mustUUID(t)
	deviceB := mustUUID(t)

	started, err := svc.Command(ctx, deviceA, focus.CommandRequest{
		Action: "start", ExpectedVersion: 0, TargetSeconds: 1500, Label: "写方案",
	})
	if err != nil {
		t.Fatal(err)
	}
	if started.Session == nil || started.Session.ControlDeviceID != deviceA || started.Session.Version != 1 {
		t.Fatalf("unexpected start: %+v", started.Session)
	}
	time.Sleep(15 * time.Millisecond)

	taken, err := svc.Command(ctx, deviceB, focus.CommandRequest{
		Action: "takeover", ExpectedVersion: 1, SessionID: started.Session.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if taken.Session == nil || taken.Session.ControlDeviceID != deviceB || taken.Session.Version != 2 {
		t.Fatalf("unexpected takeover: %+v", taken.Session)
	}

	// The old controller cannot pause after B took over.
	_, err = svc.Command(ctx, deviceA, focus.CommandRequest{
		Action: "pause", ExpectedVersion: 2, SessionID: started.Session.ID,
	})
	if !errors.Is(err, focus.ErrNotController) {
		t.Fatalf("old device pause: %v", err)
	}

	// A stale expected version cannot overwrite newer state.
	_, err = svc.Command(ctx, deviceB, focus.CommandRequest{
		Action: "pause", ExpectedVersion: 1, SessionID: started.Session.ID,
	})
	if !errors.Is(err, focus.ErrVersionStale) {
		t.Fatalf("stale pause: %v", err)
	}

	paused, err := svc.Command(ctx, deviceB, focus.CommandRequest{
		Action: "pause", ExpectedVersion: 2, SessionID: started.Session.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if paused.Session == nil || paused.Session.State != "paused" || paused.Session.Version != 3 {
		t.Fatalf("unexpected pause: %+v", paused.Session)
	}
	resumed, err := svc.Command(ctx, deviceB, focus.CommandRequest{
		Action: "resume", ExpectedVersion: 3, SessionID: started.Session.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if resumed.Session == nil || resumed.Session.State != "running" || resumed.Session.Version != 4 {
		t.Fatalf("unexpected resume: %+v", resumed.Session)
	}
	ended, err := svc.Command(ctx, deviceB, focus.CommandRequest{
		Action: "end", ExpectedVersion: 4, SessionID: started.Session.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if ended.Session != nil {
		t.Fatalf("ended session should be nil: %+v", ended.Session)
	}
	current, err := svc.Current(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if current.Session != nil {
		t.Fatalf("active session after end: %+v", current.Session)
	}
}

func TestOnlyOneActiveSharedSession(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &focus.Service{Store: st}
	device := mustUUID(t)
	if _, err := svc.Command(ctx, device, focus.CommandRequest{Action: "start", ExpectedVersion: 0, TargetSeconds: 60}); err != nil {
		t.Fatal(err)
	}
	_, err := svc.Command(ctx, device, focus.CommandRequest{Action: "start", ExpectedVersion: 0, TargetSeconds: 60})
	if !errors.Is(err, focus.ErrActiveSession) {
		t.Fatalf("second start: %v", err)
	}
}
