package main

import (
	"context"
	"io/fs"
	"log/slog"
	"os"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/numofx/matching-backend/internal/config"
	projectmigrations "github.com/numofx/matching-backend/migrations"
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
		sqlBytes, err := fs.ReadFile(projectmigrations.Files, name)
		if err != nil {
			slog.Error("read migration", "file", name, "error", err)
			os.Exit(1)
		}
		sql := strings.TrimSpace(string(sqlBytes))
		if sql == "" {
			continue
		}
		if _, err := pool.Exec(ctx, sql); err != nil {
			slog.Error("apply migration", "file", name, "error", err)
			os.Exit(1)
		}
		slog.Info("applied migration", "file", name)
	}
}
