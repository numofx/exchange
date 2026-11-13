package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/numofx/matching-backend/internal/api"
	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/db"
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/rpccount"
)

func main() {
	// Probe mode runs before anything else: it must not need config, a database, or
	// the instrument registry. See healthcheck.go.
	if isHealthcheckArg(os.Args) {
		os.Exit(runHealthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		slog.Error("load config", "error", err)
		os.Exit(1)
	}

	// SIGTERM is how ECS asks a task to stop. Handling it lets Run drain in-flight
	// requests instead of dropping them mid-response.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Before any client dials: every RPC call this process makes is counted and logged as "rpc_calls" each minute.
	rpccount.Install(ctx, slog.Default(), time.Minute)

	// A series with no taker fee is dropped, or kept close-only while it holds positions, rather than
	// refused at load: refusing would stop every market, not just the one missing its fee.
	cfg = futures.ResolveUnpricedSeries(ctx, cfg, futures.ChainPositions(cfg.ChainRPCURL))

	pool, err := db.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("connect database", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	registry := instruments.DefaultRegistry(cfg)
	server := api.NewServer(cfg, pool, registry)
	if err := server.Run(ctx); err != nil {
		slog.Error("run api server", "error", err)
		os.Exit(1)
	}
}
