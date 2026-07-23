package main

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/numofx/matching-backend/internal/config"
	projectmigrations "github.com/numofx/matching-backend/migrations"
)

// migrationAdvisoryLockKey serializes concurrent migration runners (e.g. two
// services of the same repo deploying at once) on a single Postgres advisory lock.
const migrationAdvisoryLockKey = int64(0x6e756d6f) // "numo"

// Migration DDL (e.g. DROP/CREATE TRIGGER on active_orders / trade_fills) takes
// ACCESS EXCLUSIVE locks on tables the live matcher and market-makers write every
// couple of seconds. Bound the wait and retry instead of risking a deadlock abort
// killing the deploy.
const (
	migrationLockTimeout = "15s"
	migrationMaxAttempts = 4
	migrationRetryPause  = 5 * time.Second
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("load config", "error", err)
		os.Exit(1)
	}

	ctx := context.Background()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("connect database", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	// Pin one connection: the advisory lock is session-scoped and must be held on
	// the same connection the migrations run on. It auto-releases on disconnect.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		slog.Error("acquire connection", "error", err)
		os.Exit(1)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "select pg_advisory_lock($1)", migrationAdvisoryLockKey); err != nil {
		slog.Error("acquire migration advisory lock", "error", err)
		os.Exit(1)
	}
	defer func() {
		_, _ = conn.Exec(ctx, "select pg_advisory_unlock($1)", migrationAdvisoryLockKey)
	}()

	if _, err := conn.Exec(ctx, `create table if not exists schema_migrations (
  version    text primary key,
  applied_at timestamptz not null default now()
)`); err != nil {
		slog.Error("ensure schema_migrations", "error", err)
		os.Exit(1)
	}

	applied := map[string]bool{}
	rows, err := conn.Query(ctx, "select version from schema_migrations")
	if err != nil {
		slog.Error("read schema_migrations", "error", err)
		os.Exit(1)
	}
	for rows.Next() {
		var version string
		if err := rows.Scan(&version); err != nil {
			slog.Error("scan schema_migrations", "error", err)
			os.Exit(1)
		}
		applied[version] = true
	}
	if err := rows.Err(); err != nil {
		slog.Error("read schema_migrations", "error", err)
		os.Exit(1)
	}

	entries, err := fs.ReadDir(projectmigrations.Files, ".")
	if err != nil {
		slog.Error("read migrations", "error", err)
		os.Exit(1)
	}

	var files []string
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".up.sql") {
			continue
		}
		files = append(files, entry.Name())
	}
	sort.Strings(files)

	for _, name := range files {
		if applied[name] {
			continue
		}
		sqlBytes, err := fs.ReadFile(projectmigrations.Files, name)
		if err != nil {
			slog.Error("read migration", "file", name, "error", err)
			os.Exit(1)
		}
		sql := strings.TrimSpace(string(sqlBytes))
		if sql == "" {
			continue
		}
		if err := applyMigration(ctx, conn, name, sql); err != nil {
			slog.Error("apply migration", "file", name, "error", err)
			os.Exit(1)
		}
		slog.Info("applied migration", "file", name)
	}
}

// applyMigration runs one migration file and records it in schema_migrations
// atomically. lock_timeout bounds DDL lock waits against live order/fill traffic;
// a timed-out or deadlocked attempt rolls back and retries after a pause.
func applyMigration(ctx context.Context, conn *pgxpool.Conn, name, sql string) error {
	var lastErr error
	for attempt := 1; attempt <= migrationMaxAttempts; attempt++ {
		lastErr = func() error {
			tx, err := conn.Begin(ctx)
			if err != nil {
				return err
			}
			defer func() { _ = tx.Rollback(ctx) }()
			if _, err := tx.Exec(ctx, "set local lock_timeout = '"+migrationLockTimeout+"'"); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, sql); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "insert into schema_migrations (version) values ($1)", name); err != nil {
				return err
			}
			return tx.Commit(ctx)
		}()
		if lastErr == nil {
			return nil
		}
		if !isRetryableLockError(lastErr) || attempt == migrationMaxAttempts {
			return lastErr
		}
		slog.Warn("migration blocked by live traffic; retrying", "file", name, "attempt", attempt, "error", lastErr)
		time.Sleep(migrationRetryPause)
	}
	return lastErr
}

// isRetryableLockError matches lock_not_available (55P03, from lock_timeout) and
// deadlock_detected (40P01) — both transient contention with live traffic.
func isRetryableLockError(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "55P03" || pgErr.Code == "40P01"
	}
	return false
}
