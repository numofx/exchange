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
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/matching"
	"github.com/numofx/matching-backend/internal/orders"
)

func main() {
	// Probe mode: the container health check is this binary calling its own /healthz, since the
	// runtime image has no shell. It needs no config, database or chain.
	if isHealthcheckArg(os.Args) {
		os.Exit(runHealthcheck())
	}
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

	// A series with no taker fee is dropped, or kept close-only while it holds positions, rather than
	// refused at load: refusing would stop every market, not just the one missing its fee.
	cfg = futures.ResolveUnpricedSeries(ctx, cfg, futures.ChainPositions(cfg.ChainRPCURL))

	pool, err := db.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("connect database", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	ordersRepo := orders.NewRepository(pool)

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
