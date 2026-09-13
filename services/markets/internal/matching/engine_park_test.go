package matching

import (
	"errors"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func engineWithClock(now *time.Time) *Engine {
	b := newMatchBackoff()
	b.now = func() time.Time { return *now }
	return &Engine{backoff: b}
}

// The wiring, not just the parts: an executor error carrying a revert that can never succeed must
// park the pair through noteMatchFailure, so the next ticks skip it instead of resubmitting (#50).
func TestEngineParksAPairOnAPermanentSettlementRevert(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	e := engineWithClock(&now)
	candidate := orders.MatchCandidate{
		Taker: orders.Order{OrderID: "spot-795437f5", SubaccountID: "19", FilledAmount: "0"},
		Maker: orders.Order{OrderID: "spot-7e72d86e", SubaccountID: "19", FilledAmount: "1325"},
	}

	e.noteMatchFailure("USDCcNGN-SPOT", candidate, "executor_error", classifySettlementRevert(errors.New(selfTradeExecutorError)))

	now = now.Add(6 * time.Hour)
	if !e.backoff.shouldSkip(candidate.Taker, candidate.Maker) {
		t.Fatal("a pair that reverted AC_CannotTransferAssetToOneself was retried six hours later")
	}
}

// And the converse: an error it cannot classify keeps the ordinary retry schedule.
func TestEngineBacksOffButKeepsRetryingAnUnrecognisedFailure(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	e := engineWithClock(&now)
	candidate := orders.MatchCandidate{
		Taker: orders.Order{OrderID: "taker", SubaccountID: "19"},
		Maker: orders.Order{OrderID: "maker", SubaccountID: "15"},
	}

	e.noteMatchFailure("USDCcNGN-SPOT", candidate, "executor_error", classifySettlementRevert(errors.New("executor returned status 502")))

	if !e.backoff.shouldSkip(candidate.Taker, candidate.Maker) {
		t.Fatal("a failed pair must be inside its backoff window immediately")
	}
	now = now.Add(matchBackoffBase + time.Millisecond)
	if e.backoff.shouldSkip(candidate.Taker, candidate.Maker) {
		t.Fatal("an unrecognised failure must be retried once its backoff window elapses")
	}
}
