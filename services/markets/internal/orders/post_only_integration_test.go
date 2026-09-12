package orders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

func postOnlyParams(id string, nonce string, side Side, asset string, subID string, ticksVal string) CreateOrderParams {
	return CreateOrderParams{
		OrderID:         id,
		OwnerAddress:    "0xowner",
		SignerAddress:   "0xsigner",
		SubaccountID:    "1",
		RecipientID:     "1",
		Nonce:           nonce,
		Side:            side,
		AssetAddress:    asset,
		SubID:           subID,
		DesiredAmount:   "100",
		FilledAmount:    "0",
		LimitPrice:      ticksVal,
		LimitPriceTicks: ticksVal,
		WorstFee:        "0",
		Expiry:          time.Now().Add(time.Hour).Unix(),
		ActionJSON:      json.RawMessage(`{}`),
		Signature:       "0xsig",
		PostOnly:        true,
	}
}

// A post-only order that would take must be refused, and must leave nothing behind. A rejected
// order that still landed on the book would be worse than no check at all.
func TestPostOnlyOrderThatWouldCrossIsRejected(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("po-cross-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000po"
	subID := "1789567201"
	restingID, incomingID := suffix+"-resting", suffix+"-incoming"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1,$2)", restingID, incomingID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1,$2)", restingID, incomingID)
	})

	// A resting ask at 1378.
	if _, err := repo.Create(ctx, CreateOrderParams{
		OrderID: restingID, OwnerAddress: "0xowner", SignerAddress: "0xsigner",
		SubaccountID: "1", RecipientID: "1", Nonce: "1", Side: SideSell,
		AssetAddress: asset, SubID: subID, DesiredAmount: "100", FilledAmount: "0",
		LimitPrice: "1378", LimitPriceTicks: "1378", WorstFee: "0",
		Expiry: time.Now().Add(time.Hour).Unix(), ActionJSON: json.RawMessage(`{}`), Signature: "0xsig",
	}); err != nil {
		t.Fatalf("seed resting ask: %v", err)
	}

	// A post-only bid at 1382 would lift it.
	_, err := repo.Create(ctx, postOnlyParams(incomingID, "2", SideBuy, asset, subID, "1382"))
	if !errors.Is(err, ErrWouldCross) {
		t.Fatalf("err = %v, want ErrWouldCross", err)
	}

	var n int
	if err := pool.QueryRow(ctx, "select count(*) from active_orders where order_id = $1", incomingID).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("the rejected order was written anyway (%d rows) -- worse than no check", n)
	}
}

// The other direction: a post-only order that does not cross must rest exactly like any other.
// Without this the check could reject everything and still look correct.
func TestPostOnlyOrderThatDoesNotCrossRestsNormally(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("po-rest-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000001po"
	subID := "1789567201"
	restingID, incomingID := suffix+"-resting", suffix+"-incoming"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1,$2)", restingID, incomingID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1,$2)", restingID, incomingID)
	})

	if _, err := repo.Create(ctx, CreateOrderParams{
		OrderID: restingID, OwnerAddress: "0xowner", SignerAddress: "0xsigner",
		SubaccountID: "1", RecipientID: "1", Nonce: "1", Side: SideSell,
		AssetAddress: asset, SubID: subID, DesiredAmount: "100", FilledAmount: "0",
		LimitPrice: "1378", LimitPriceTicks: "1378", WorstFee: "0",
		Expiry: time.Now().Add(time.Hour).Unix(), ActionJSON: json.RawMessage(`{}`), Signature: "0xsig",
	}); err != nil {
		t.Fatalf("seed resting ask: %v", err)
	}

	// A post-only bid at 1377 sits below the ask and takes nothing.
	order, err := repo.Create(ctx, postOnlyParams(incomingID, "2", SideBuy, asset, subID, "1377"))
	if err != nil {
		t.Fatalf("a non-crossing post-only order must rest: %v", err)
	}
	if order.OrderID != incomingID || order.Status != StatusActive {
		t.Fatalf("order = %+v, want an active row", order)
	}

	var postOnly bool
	if err := pool.QueryRow(ctx, "select post_only from active_orders where order_id = $1", incomingID).Scan(&postOnly); err != nil {
		t.Fatalf("read post_only: %v", err)
	}
	if !postOnly {
		t.Fatal("the row does not record that it was post-only")
	}
}

// The SQL condition and the Go rule are two statements of the same thing, and a divergence is
// invisible until an order the API accepted as "will rest" is made the taker. Replays the shared
// table against a real database.
func TestSQLCrossConditionMatchesGo(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	for i, tc := range crossCases {
		t.Run(tc.name, func(t *testing.T) {
			suffix := fmt.Sprintf("po-agree-%d-%d", time.Now().UnixNano(), i)
			asset := fmt.Sprintf("0xagree%034d", i)
			subID := "1789567201"
			restingID, incomingID := suffix+"-resting", suffix+"-incoming"

			t.Cleanup(func() {
				_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1,$2)", restingID, incomingID)
				_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1,$2)", restingID, incomingID)
			})

			if _, err := repo.Create(ctx, CreateOrderParams{
				OrderID: restingID, OwnerAddress: "0xowner", SignerAddress: "0xsigner",
				SubaccountID: "1", RecipientID: "1", Nonce: "1", Side: otherSide(tc.side),
				AssetAddress: asset, SubID: subID, DesiredAmount: "100", FilledAmount: "0",
				LimitPrice: tc.opp, LimitPriceTicks: tc.opp, WorstFee: "0",
				Expiry: time.Now().Add(time.Hour).Unix(), ActionJSON: json.RawMessage(`{}`), Signature: "0xsig",
			}); err != nil {
				t.Fatalf("seed opposing order: %v", err)
			}

			_, err := repo.Create(ctx, postOnlyParams(incomingID, "2", tc.side, asset, subID, tc.ticks))
			sqlRejected := errors.Is(err, ErrWouldCross)
			if err != nil && !sqlRejected {
				t.Fatalf("unexpected error: %v", err)
			}

			goSays := WouldCross(tc.side, ticks(tc.ticks), ticks(tc.opp))
			if sqlRejected != goSays {
				t.Fatalf("SQL rejected=%v but WouldCross=%v for %s %s vs %s -- the two rules have drifted",
					sqlRejected, goSays, tc.side, tc.ticks, tc.opp)
			}
			if sqlRejected != tc.crosses {
				t.Fatalf("SQL rejected=%v, want %v", sqlRejected, tc.crosses)
			}
		})
	}
}

// The status endpoint is how a client confirms the flag was recorded rather than assuming it. A
// service that silently ignored post_only would look identical from the submit side, so without
// this the caller can only infer -- which is exactly how the bot's own quotes went unverified.
func TestOrderStatusReportsPostOnly(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("po-status-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000002po"
	subID := "1789567201"
	plainID, postOnlyID := suffix+"-plain", suffix+"-po"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1,$2)", plainID, postOnlyID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1,$2)", plainID, postOnlyID)
	})

	// An ordinary order reports false, not absent.
	if _, err := repo.Create(ctx, CreateOrderParams{
		OrderID: plainID, OwnerAddress: "0xowner", SignerAddress: "0xsigner",
		SubaccountID: "1", RecipientID: "1", Nonce: "1", Side: SideBuy,
		AssetAddress: asset, SubID: subID, DesiredAmount: "100", FilledAmount: "0",
		LimitPrice: "1300", LimitPriceTicks: "1300", WorstFee: "0",
		Expiry: time.Now().Add(time.Hour).Unix(), ActionJSON: json.RawMessage(`{}`), Signature: "0xsig",
	}); err != nil {
		t.Fatalf("create plain order: %v", err)
	}
	plain, err := repo.GetOrderStatusSnapshot(ctx, plainID)
	if err != nil {
		t.Fatalf("status of plain order: %v", err)
	}
	if plain.PostOnly {
		t.Fatal("an ordinary order reported post_only")
	}

	// And a post-only one reports true, so "did my flag take effect?" is answerable.
	if _, err := repo.Create(ctx, postOnlyParams(postOnlyID, "2", SideBuy, asset, subID, "1200")); err != nil {
		t.Fatalf("create post-only order: %v", err)
	}
	po, err := repo.GetOrderStatusSnapshot(ctx, postOnlyID)
	if err != nil {
		t.Fatalf("status of post-only order: %v", err)
	}
	if !po.PostOnly {
		t.Fatal("a post-only order did not report post_only; the flag is unobservable")
	}
}
