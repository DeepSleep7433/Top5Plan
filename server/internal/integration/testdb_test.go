package integration

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

func testStore(t *testing.T) *store.Store {
	t.Helper()
	dsn := os.Getenv("T5_TEST_DSN")
	if dsn == "" {
		t.Skip("T5_TEST_DSN not set; MySQL integration test skipped")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatalf("parse T5_TEST_DSN: %v", err)
	}
	cfg.ParseTime = true
	cfg.Loc = time.UTC
	adminCfg := *cfg
	adminCfg.DBName = ""
	admin, err := sql.Open("mysql", adminCfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	dbName := "t5_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:12]
	if _, err := admin.Exec("CREATE DATABASE `" + dbName + "` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"); err != nil {
		t.Fatalf("create test database: %v", err)
	}
	cfg.DBName = dbName
	st, err := store.Open(context.Background(), cfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = st.Close()
		cleanup, err := sql.Open("mysql", adminCfg.FormatDSN())
		if err == nil {
			_, _ = cleanup.Exec("DROP DATABASE IF EXISTS `" + dbName + "`")
			_ = cleanup.Close()
		}
	})
	return st
}

func mustUUID(t *testing.T) string {
	t.Helper()
	id, err := uuid.NewRandom()
	if err != nil {
		t.Fatal(err)
	}
	return id.String()
}

func TestSchemaApplies(t *testing.T) {
	st := testStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := st.Ready(ctx); err != nil {
		t.Fatal(err)
	}
	gen, err := st.AccountGeneration(ctx)
	if err != nil || gen == "" {
		t.Fatalf("generation: %q %v", gen, err)
	}
	var count int
	if err := st.DB.QueryRow("SELECT COUNT(*) FROM sync_sequence").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("sync_sequence rows = %d", count)
	}
}
