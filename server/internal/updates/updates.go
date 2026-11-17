package updates

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

type Release struct {
	ID           string    `json:"id"`
	Platform     string    `json:"platform"`
	Version      string    `json:"version"`
	DownloadURL  string    `json:"download_url"`
	SHA256       string    `json:"sha256"`
	ReleaseNotes string    `json:"release_notes"`
	Mandatory    bool      `json:"mandatory"`
	Channel      string    `json:"channel"`
	PublishedAt  time.Time `json:"published_at"`
}

type CheckResponse struct {
	UpdateAvailable bool     `json:"update_available"`
	Platform        string   `json:"platform"`
	CurrentVersion  string   `json:"current_version"`
	Latest          *Release `json:"latest,omitempty"`
}

type PublishInput struct {
	Platform     string
	Version      string
	DownloadURL  string
	SHA256       string
	ReleaseNotes string
	Mandatory    bool
	Channel      string
}

type Service struct{ Store *store.Store }

func (s *Service) Publish(ctx context.Context, in PublishInput) (Release, error) {
	if in.Platform != "windows" && in.Platform != "android" {
		return Release{}, errors.New("platform must be windows or android")
	}
	if strings.TrimSpace(in.Version) == "" || len(in.Version) > 40 {
		return Release{}, errors.New("version is required")
	}
	u, err := url.Parse(in.DownloadURL)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return Release{}, errors.New("download_url must be an http(s) URL")
	}
	if in.SHA256 != "" {
		if len(in.SHA256) != 64 {
			return Release{}, errors.New("sha256 must be 64 hex characters")
		}
		if _, err := hex.DecodeString(in.SHA256); err != nil {
			return Release{}, errors.New("sha256 must be hex")
		}
	}
	if in.Channel == "" {
		in.Channel = "stable"
	}
	if in.Channel != "stable" && in.Channel != "beta" {
		return Release{}, errors.New("channel must be stable or beta")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	id := uuid.NewString()
	_, err = s.Store.DB.ExecContext(ctx,
		`INSERT INTO app_releases(id, platform, version, download_url, sha256, release_notes, mandatory, active, channel, published_at, created_at, updated_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
		 ON DUPLICATE KEY UPDATE download_url=VALUES(download_url), sha256=VALUES(sha256),
		 release_notes=VALUES(release_notes), mandatory=VALUES(mandatory), active=1,
		 published_at=VALUES(published_at), updated_at=VALUES(updated_at)`,
		id, in.Platform, strings.TrimSpace(in.Version), in.DownloadURL, strings.ToLower(in.SHA256),
		in.ReleaseNotes, in.Mandatory, in.Channel, now, now, now)
	if err != nil {
		return Release{}, err
	}
	var r Release
	err = s.Store.DB.QueryRowContext(ctx,
		`SELECT id, platform, version, download_url, sha256, COALESCE(release_notes,''), mandatory, channel, published_at
		 FROM app_releases WHERE platform=? AND version=? AND channel=?`,
		in.Platform, strings.TrimSpace(in.Version), in.Channel).
		Scan(&r.ID, &r.Platform, &r.Version, &r.DownloadURL, &r.SHA256, &r.ReleaseNotes, &r.Mandatory, &r.Channel, &r.PublishedAt)
	return r, err
}

func (s *Service) Latest(ctx context.Context, platform, currentVersion, channel string) (CheckResponse, error) {
	if platform != "windows" && platform != "android" {
		return CheckResponse{}, errors.New("platform must be windows or android")
	}
	if channel == "" {
		channel = "stable"
	}
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT id, platform, version, download_url, sha256, COALESCE(release_notes,''), mandatory, channel, published_at
		 FROM app_releases WHERE platform=? AND channel=? AND active=1`, platform, channel)
	if err != nil {
		return CheckResponse{}, err
	}
	defer rows.Close()
	releases := []Release{}
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.ID, &r.Platform, &r.Version, &r.DownloadURL, &r.SHA256, &r.ReleaseNotes, &r.Mandatory, &r.Channel, &r.PublishedAt); err != nil {
			return CheckResponse{}, err
		}
		releases = append(releases, r)
	}
	if err := rows.Err(); err != nil {
		return CheckResponse{}, err
	}
	if len(releases) == 0 {
		return CheckResponse{Platform: platform, CurrentVersion: currentVersion}, nil
	}
	sort.SliceStable(releases, func(i, j int) bool {
		return CompareVersions(releases[i].Version, releases[j].Version) > 0
	})
	latest := releases[0]
	return CheckResponse{
		UpdateAvailable: CompareVersions(latest.Version, currentVersion) > 0,
		Platform:        platform,
		CurrentVersion:  currentVersion,
		Latest:          &latest,
	}, nil
}

// CompareVersions compares numeric dotted versions, ignoring a leading v and
// common pre-release suffixes. It is intentionally small and deterministic.
func CompareVersions(a, b string) int {
	pa := versionParts(a)
	pb := versionParts(b)
	n := len(pa)
	if len(pb) > n {
		n = len(pb)
	}
	for i := 0; i < n; i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x > y {
			return 1
		}
		if x < y {
			return -1
		}
	}
	return 0
}

func versionParts(v string) []int {
	v = strings.TrimSpace(strings.TrimPrefix(strings.ToLower(v), "v"))
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	fields := strings.Split(v, ".")
	out := make([]int, 0, len(fields))
	for _, f := range fields {
		n, err := strconv.Atoi(f)
		if err != nil {
			out = append(out, 0)
		} else {
			out = append(out, n)
		}
	}
	return out
}

func (s *Service) List(ctx context.Context, platform string) ([]Release, error) {
	q := `SELECT id, platform, version, download_url, sha256, COALESCE(release_notes,''), mandatory, channel, published_at
	      FROM app_releases`
	args := []any{}
	if platform != "" {
		q += ` WHERE platform=?`
		args = append(args, platform)
	}
	q += ` ORDER BY published_at DESC`
	rows, err := s.Store.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Release{}
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.ID, &r.Platform, &r.Version, &r.DownloadURL, &r.SHA256, &r.ReleaseNotes, &r.Mandatory, &r.Channel, &r.PublishedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Service) Delete(ctx context.Context, id string) error {
	res, err := s.Store.DB.ExecContext(ctx, `UPDATE app_releases SET active=0, updated_at=UTC_TIMESTAMP(6) WHERE id=?`, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}
