package integration

import (
	"context"
	"testing"

	"github.com/t5plan/t5/server/internal/updates"
)

func TestVersionComparison(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.0.1", "1.0.0", 1},
		{"v1.2.0", "1.1.9", 1},
		{"1.0.0", "1.0.0", 0},
		{"1.0.0", "1.0.1", -1},
		{"2.0", "1.9.9", 1},
	}
	for _, c := range cases {
		if got := updates.CompareVersions(c.a, c.b); got != c.want {
			t.Fatalf("CompareVersions(%q,%q)=%d want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestPublishAndReadLatestRelease(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &updates.Service{Store: st}
	first, err := svc.Publish(ctx, updates.PublishInput{
		Platform: "windows", Version: "1.0.1", DownloadURL: "https://example.com/t5-1.0.1.exe",
		ReleaseNotes: "修复同步", Channel: "stable",
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == "" {
		t.Fatal("release id is empty")
	}
	second, err := svc.Publish(ctx, updates.PublishInput{
		Platform: "windows", Version: "1.0.2", DownloadURL: "https://example.com/t5-1.0.2.exe",
		ReleaseNotes: "新增更新按钮", Channel: "stable", Mandatory: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	resp, err := svc.Latest(ctx, "windows", "1.0.0", "stable")
	if err != nil {
		t.Fatal(err)
	}
	if !resp.UpdateAvailable || resp.Latest == nil || resp.Latest.ID != second.ID {
		t.Fatalf("latest = %+v", resp)
	}
	upToDate, err := svc.Latest(ctx, "windows", "1.0.2", "stable")
	if err != nil {
		t.Fatal(err)
	}
	if upToDate.UpdateAvailable {
		t.Fatalf("unexpected update: %+v", upToDate)
	}
	if err := svc.Delete(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	afterDelete, err := svc.Latest(ctx, "windows", "1.0.0", "stable")
	if err != nil {
		t.Fatal(err)
	}
	if afterDelete.Latest == nil || afterDelete.Latest.Version != "1.0.1" {
		t.Fatalf("after delete latest = %+v", afterDelete)
	}
}
