package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/db"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/matching"
	"github.com/numofx/matching-backend/internal/orders"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("load config", "error", err)
		os.Exit(1)
	}

	// SIGTERM is how ECS and Railway both ask a task to stop. Without this the
	// process is killed outright, and a kill between reserveOrders and the deferred
	// release in tickInstrument strands both orders in 'matching' permanently.
	// Cancelling the context instead lets the current tick unwind and run that
	// release, which uses a detached context precisely so it survives shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("connect database", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	registry := instruments.DefaultRegistry(cfg)
	ordersRepo := orders.NewRepository(pool)
	if err := ordersRepo.BackfillLimitPriceTicks(ctx, registry); err != nil {
		slog.Error("backfill limit price ticks", "error", err)
		os.Exit(1)
	}

	// Belt to the shutdown handling's braces: a SIGKILL, an OOM or a crashed node
	// leaves no chance to unwind, so recover anything a previous process stranded.
	// See orders.ReleaseStaleMatches for why this is safe to run unconditionally.
	released, err := ordersRepo.ReleaseStaleMatches(ctx)
	if err != nil {
		slog.Error("release stale matches", "error", err)
		os.Exit(1)
	}
	if released > 0 {
		slog.Warn("released orders stranded in matching by a previous process", "count", released)
	}

	engine := matching.NewEngine(cfg, pool)
	if err := engine.Run(ctx); err != nil {
		// A cancelled context is this process being asked to stop, not a failure.
		if errors.Is(err, context.Canceled) {
			slog.Info("matcher stopped")
			return
		}
		slog.Error("run matcher", "error", err)
		os.Exit(1)
	}
}
