package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/google/uuid"

	"github.com/t5plan/t5/server/migrations"
)

type Store struct {
	DB *sql.DB
}

func Open(ctx context.Context, dsn string) (*Store, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("database ping: %w", err)
	}
	return &Store{DB: db}, nil
}

func (s *Store) Close() error { return s.DB.Close() }

func (s *Store) Migrate(ctx context.Context) error {
	applied := map[int]bool{}
	rows, err := s.DB.QueryContext(ctx, `SELECT version FROM schema_migrations`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var v int
			if err := rows.Scan(&v); err != nil {
				return err
			}
			applied[v] = true
		}
		if err := rows.Err(); err != nil {
			return err
		}
	}

	files, err := migrations.Files.ReadDir(".")
	if err != nil {
		return err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name() < files[j].Name() })
	for _, f := range files {
		if f.IsDir() || !strings.HasSuffix(f.Name(), ".sql") {
			continue
		}
		var version int
		if _, err := fmt.Sscanf(f.Name(), "%03d_", &version); err != nil {
			return fmt.Errorf("migration filename %s: %w", f.Name(), err)
		}
		if applied[version] {
			continue
		}
		b, err := migrations.Files.ReadFile(f.Name())
		if err != nil {
			return err
		}
		for _, stmt := range SplitSQL(string(b)) {
			if _, err := s.DB.ExecContext(ctx, stmt); err != nil {
				return fmt.Errorf("migration %s: %w", f.Name(), err)
			}
		}
		if _, err := s.DB.ExecContext(ctx, `INSERT INTO schema_migrations(version, applied_at) VALUES(?, UTC_TIMESTAMP(6))`, version); err != nil {
			return fmt.Errorf("record migration %s: %w", f.Name(), err)
		}
	}
	return nil
}

// SplitSQL is deliberately simple: migrations must not contain stored
// procedures or semicolons inside string literals.
func SplitSQL(src string) []string {
	var out []string
	for _, part := range strings.Split(src, ";") {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func (s *Store) Ready(ctx context.Context) error {
	if err := s.DB.PingContext(ctx); err != nil {
		return err
	}
	var n int
	if err := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, migrations.LatestVersion).Scan(&n); err != nil {
		return err
	}
	if n != 1 {
		return errors.New("database migrations are not current")
	}
	return nil
}

func (s *Store) AccountGeneration(ctx context.Context) (string, error) {
	var gen string
	err := s.DB.QueryRowContext(ctx, `SELECT sync_generation FROM accounts WHERE id = 1`).Scan(&gen)
	return gen, err
}

func (s *Store) RotateGeneration(ctx context.Context) (string, error) {
	gen := uuid.NewString()
	if _, err := s.DB.ExecContext(ctx, `UPDATE accounts SET sync_generation = ?, updated_at = UTC_TIMESTAMP(6) WHERE id = 1`, gen); err != nil {
		return "", err
	}
	return gen, nil
}

func (s *Store) Timezone(ctx context.Context) (string, error) {
	var tz string
	err := s.DB.QueryRowContext(ctx, `SELECT timezone FROM accounts WHERE id = 1`).Scan(&tz)
	return tz, err
}

func (s *Store) SetTimezone(ctx context.Context, tz string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE accounts SET timezone = ?, updated_at = UTC_TIMESTAMP(6) WHERE id = 1`, tz)
	return err
}

func nowUTC() time.Time { return time.Now().UTC().Truncate(time.Microsecond) }
