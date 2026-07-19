package orders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/pricing"
)

var ErrNotFound = errors.New("order not found")

type CreateOrderParams struct {
	OrderID         string
	OwnerAddress    string
	SignerAddress   string
	SubaccountID    string
	RecipientID     string
	Nonce           string
	Side            Side
	AssetAddress    string
	SubID           string
	DesiredAmount   string
	FilledAmount    string
	LimitPrice      string
	LimitPriceTicks string
	WorstFee        string
	Expiry          int64
	ActionJSON      json.RawMessage
	Signature       string
}

type CancelOrderParams struct {
	OwnerAddress string
	Nonce        string
	Reason       string
}

type MatchCandidate struct {
	Taker Order
	Maker Order
}

type MarketDiagnostics struct {
	OpenBidCount       int32
	OpenAskCount       int32
	TradeCount         int64
	LastTradeTimestamp *time.Time
}

type OrderStatusSnapshot struct {
	OrderID       string
	Status        Status
	DesiredAmount string
	FilledAmount  string
	CancelReason  string
	UpdatedAt     time.Time
}

type Repository struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) *Repository {
	return &Repository{pool: pool}
}

func (r *Repository) BackfillLimitPriceTicks(ctx context.Context, registry *instruments.Registry) error {
	if registry == nil {
		return fmt.Errorf("instrument registry is required for limit price backfill")
	}

	const query = `
select order_id, asset_address, sub_id, limit_price
from active_orders
where limit_price_ticks is null
`

	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return mapPGError(err)
	}
	defer rows.Close()

	type missing struct {
		OrderID      string
		AssetAddress string
		SubID        string
		LimitPrice   string
	}

	var updates []missing
	for rows.Next() {
		var item missing
		if err := rows.Scan(&item.OrderID, &item.AssetAddress, &item.SubID, &item.LimitPrice); err != nil {
			return mapPGError(err)
		}
		updates = append(updates, item)
	}
	if err := rows.Err(); err != nil {
		return mapPGError(err)
	}

	for _, item := range updates {
		instrument, ok := registry.ByAssetAndSubID(strings.ToLower(item.AssetAddress), item.SubID)
		if !ok {
			slog.Warn(
				"skip limit price tick backfill for unknown instrument",
				"order_id", item.OrderID,
				"asset_address", item.AssetAddress,
				"sub_id", item.SubID,
			)
			continue
		}
		converter, err := pricing.NewConverter(instrument)
		if err != nil {
			return err
		}
		ticks, _, err := converter.Parse(item.LimitPrice)
		if err != nil {
			return fmt.Errorf("backfill price ticks for order %s: %w", item.OrderID, err)
		}

		if _, err := r.pool.Exec(ctx, `update active_orders set limit_price_ticks = $2 where order_id = $1`, item.OrderID, ticks); err != nil {
			return mapPGError(err)
		}
	}

	return nil
}

func (r *Repository) Create(ctx context.Context, params CreateOrderParams) (Order, error) {
	const query = `
insert into active_orders (
  order_id,
  owner_address,
  signer_address,
  subaccount_id,
  recipient_id,
  nonce,
  side,
  asset_address,
  sub_id,
  desired_amount,
  filled_amount,
  limit_price,
  limit_price_ticks,
  worst_fee,
  expiry,
  action_json,
  signature,
  status
) values (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18
)
returning order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
          desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
`

	order := Order{}
	if err := r.pool.QueryRow(
		ctx,
		query,
		params.OrderID,
		params.OwnerAddress,
		params.SignerAddress,
		params.SubaccountID,
		params.RecipientID,
		params.Nonce,
		params.Side,
		params.AssetAddress,
		params.SubID,
		params.DesiredAmount,
		params.FilledAmount,
		params.LimitPrice,
		params.LimitPriceTicks,
		params.WorstFee,
		params.Expiry,
		params.ActionJSON,
		params.Signature,
		StatusActive,
	).Scan(
		&order.OrderID,
		&order.OwnerAddress,
		&order.SignerAddress,
		&order.SubaccountID,
		&order.RecipientID,
		&order.Nonce,
		&order.Side,
		&order.AssetAddress,
		&order.SubID,
		&order.DesiredAmount,
		&order.FilledAmount,
		&order.LimitPrice,
		&order.LimitPriceTicks,
		&order.WorstFee,
		&order.Expiry,
		&order.ActionJSON,
		&order.Signature,
		&order.Status,
		&order.CreatedAt,
	); err != nil {
		return Order{}, mapPGError(err)
	}

	return order, nil
}

func (r *Repository) CancelByOwnerNonce(ctx context.Context, params CancelOrderParams) (Order, error) {
	const query = `
update active_orders
set status = $3
where owner_address = $1 and nonce = $2 and status = 'active'
returning order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
          desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
`

	order := Order{}
	if err := r.pool.QueryRow(ctx, query, params.OwnerAddress, params.Nonce, StatusCancelled).Scan(
		&order.OrderID,
		&order.OwnerAddress,
		&order.SignerAddress,
		&order.SubaccountID,
		&order.RecipientID,
		&order.Nonce,
		&order.Side,
		&order.AssetAddress,
		&order.SubID,
		&order.DesiredAmount,
		&order.FilledAmount,
		&order.LimitPrice,
		&order.LimitPriceTicks,
		&order.WorstFee,
		&order.Expiry,
		&order.ActionJSON,
		&order.Signature,
		&order.Status,
		&order.CreatedAt,
	); err != nil {
		return Order{}, mapPGError(err)
	}

	return order, nil
}

func (r *Repository) FindActiveByOwnerNonce(ctx context.Context, params CancelOrderParams) (Order, error) {
	const query = `
select order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
          desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
from active_orders
where owner_address = $1 and nonce = $2 and status = 'active'
`

	order := Order{}
	if err := r.pool.QueryRow(ctx, query, params.OwnerAddress, params.Nonce).Scan(
		&order.OrderID,
		&order.OwnerAddress,
		&order.SignerAddress,
		&order.SubaccountID,
		&order.RecipientID,
		&order.Nonce,
		&order.Side,
		&order.AssetAddress,
		&order.SubID,
		&order.DesiredAmount,
		&order.FilledAmount,
		&order.LimitPrice,
		&order.LimitPriceTicks,
		&order.WorstFee,
		&order.Expiry,
		&order.ActionJSON,
		&order.Signature,
		&order.Status,
		&order.CreatedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Order{}, ErrNotFound
		}
		return Order{}, mapPGError(err)
	}

	return order, nil
}

func (r *Repository) GetOrderStatusSnapshot(ctx context.Context, orderID string) (OrderStatusSnapshot, error) {
	const query = `
select
  order_id,
  status,
  desired_amount,
  filled_amount,
  ''::text as cancel_reason,
  created_at as updated_at
from active_orders
where order_id = $1
`

	var snapshot OrderStatusSnapshot
	if err := r.pool.QueryRow(ctx, query, strings.TrimSpace(orderID)).Scan(
		&snapshot.OrderID,
		&snapshot.Status,
		&snapshot.DesiredAmount,
		&snapshot.FilledAmount,
		&snapshot.CancelReason,
		&snapshot.UpdatedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return OrderStatusSnapshot{}, ErrNotFound
		}
		return OrderStatusSnapshot{}, mapPGError(err)
	}
	return snapshot, nil
}

func (r *Repository) ListBook(ctx context.Context, assetAddress string, subID string, limit int32) ([]Order, []Order, error) {
	if err := r.ExpireOrders(ctx, time.Now()); err != nil {
		return nil, nil, err
	}

	bids, err := r.listBySide(ctx, strings.ToLower(assetAddress), subID, SideBuy, limit)
	if err != nil {
		return nil, nil, err
	}

	asks, err := r.listBySide(ctx, strings.ToLower(assetAddress), subID, SideSell, limit)
	if err != nil {
		return nil, nil, err
	}

	return bids, asks, nil
}

func (r *Repository) BestBidAndAsk(ctx context.Context, assetAddress string, subID string) (*Order, *Order, error) {
	if err := r.ExpireOrders(ctx, time.Now()); err != nil {
		return nil, nil, err
	}

	bid, err := r.bestBySide(ctx, strings.ToLower(assetAddress), subID, SideBuy)
	if err != nil {
		return nil, nil, err
	}

	ask, err := r.bestBySide(ctx, strings.ToLower(assetAddress), subID, SideSell)
	if err != nil {
		return nil, nil, err
	}

	return bid, ask, nil
}

func (r *Repository) AcquireMatchCandidate(ctx context.Context, assetAddress string, subID string, now time.Time) (*MatchCandidate, error) {
	slog.Info(
		"acquire_match_candidate_start",
		"asset_address", strings.ToLower(assetAddress),
		"sub_id", subID,
	)

	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = tx.Rollback(ctx)
	}()

	if err := expireOrders(ctx, tx, now); err != nil {
		return nil, err
	}

	bid, err := lockBestBySide(ctx, tx, strings.ToLower(assetAddress), subID, SideBuy)
	if err != nil {
		return nil, err
	}
	ask, err := lockBestBySide(ctx, tx, strings.ToLower(assetAddress), subID, SideSell)
	if err != nil {
		return nil, err
	}
	if bid == nil || ask == nil {
		slog.Info(
			"acquire_match_candidate_no_pair",
			"asset_address", strings.ToLower(assetAddress),
			"sub_id", subID,
			"has_bid", bid != nil,
			"has_ask", ask != nil,
		)
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
		return nil, nil
	}

	taker, maker := chooseTakerMaker(*bid, *ask)
	if err := reserveOrders(ctx, tx, []string{taker.OrderID, maker.OrderID}); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	slog.Info(
		"acquire_match_candidate_reserved",
		"asset_address", strings.ToLower(assetAddress),
		"sub_id", subID,
		"taker_order_id", taker.OrderID,
		"taker_side", taker.Side,
		"taker_price_ticks", taker.LimitPriceTicks,
		"maker_order_id", maker.OrderID,
		"maker_side", maker.Side,
		"maker_price_ticks", maker.LimitPriceTicks,
	)

	return &MatchCandidate{Taker: taker, Maker: maker}, nil
}

func (r *Repository) ReleaseMatch(ctx context.Context, orderIDs ...string) error {
	if len(orderIDs) == 0 {
		return nil
	}

	const query = `
update active_orders
set status = 'active'
where order_id = any($1) and status = 'matching'
`

	_, err := r.pool.Exec(ctx, query, orderIDs)
	return mapPGError(err)
}

func (r *Repository) MarkMatchFailed(ctx context.Context, orderIDs []string, reason string) error {
	return r.ReleaseMatch(ctx, orderIDs...)
}

func (r *Repository) FinalizeMatch(ctx context.Context, takerOrderID string, makerOrderID string, fillAmount string) error {
	return r.FinalizeMatchWithPrice(ctx, takerOrderID, makerOrderID, "", fillAmount)
}

func (r *Repository) FinalizeMatchWithPrice(
	ctx context.Context,
	takerOrderID string,
	makerOrderID string,
	fillPrice string,
	fillAmount string,
) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() {
		_ = tx.Rollback(ctx)
	}()

	takerOrder, err := applyFill(ctx, tx, takerOrderID, fillAmount)
	if err != nil {
		return err
	}
	makerOrder, err := applyFill(ctx, tx, makerOrderID, fillAmount)
	if err != nil {
		return err
	}
	if fillPrice == "" {
		fillPrice = makerOrder.LimitPrice
	}
	if err := insertTradeFill(ctx, tx, takerOrder, makerOrder, fillPrice, fillAmount); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func (r *Repository) ExpireOrders(ctx context.Context, now time.Time) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() {
		_ = tx.Rollback(ctx)
	}()

	if err := expireOrders(ctx, tx, now); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func (r *Repository) listBySide(ctx context.Context, assetAddress string, subID string, side Side, limit int32) ([]Order, error) {
	orderBy := "limit_price_ticks::numeric desc, created_at asc"
	if side == SideSell {
		orderBy = "limit_price_ticks::numeric asc, created_at asc"
	}

	query := fmt.Sprintf(`
select order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
       desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
from active_orders
where asset_address = $1 and sub_id = $2 and side = $3 and status = 'active'
order by %s
limit $4
`, orderBy)

	rows, err := r.pool.Query(ctx, query, assetAddress, subID, side, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()

	var results []Order
	for rows.Next() {
		order, err := scanOrder(rows)
		if err != nil {
			return nil, err
		}
		results = append(results, order)
	}

	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}

	return results, nil
}

func (r *Repository) ListTrades(ctx context.Context, assetAddress string, subID string, beforeTradeID int64, limit int32) ([]TradeFill, error) {
	query := `
select trade_id, asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at
from trade_fills
where asset_address = $1 and sub_id = $2
  and ($3 = 0 or trade_id < $3)
order by created_at desc, trade_id desc
limit $4
`

	rows, err := r.pool.Query(ctx, query, strings.ToLower(assetAddress), subID, beforeTradeID, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()

	var results []TradeFill
	for rows.Next() {
		var item TradeFill
		if err := rows.Scan(
			&item.TradeID,
			&item.AssetAddress,
			&item.SubID,
			&item.Price,
			&item.Size,
			&item.AggressorSide,
			&item.TakerOrderID,
			&item.MakerOrderID,
			&item.CreatedAt,
		); err != nil {
			return nil, mapPGError(err)
		}
		results = append(results, item)
	}

	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}

	return results, nil
}

func (r *Repository) GetTradeStats24h(ctx context.Context, assetAddress string, subID string) (TradeStats24h, error) {
	const query = `
with recent as (
  select trade_id, price::numeric as price, size::numeric as size, created_at
  from trade_fills
  where asset_address = $1 and sub_id = $2 and created_at >= now() - interval '24 hours'
),
latest as (
  select price from recent order by created_at desc, trade_id desc limit 1
),
earliest as (
  select price from recent order by created_at asc, trade_id asc limit 1
)
select
  coalesce((select price::text from latest), ''),
  coalesce((select max(price)::text from recent), ''),
  coalesce((select min(price)::text from recent), ''),
  coalesce((select sum(size)::text from recent), ''),
  coalesce((
    select ((select price from latest) - (select price from earliest))::text
  ), '')
`

	var stats TradeStats24h
	err := r.pool.QueryRow(ctx, query, strings.ToLower(assetAddress), subID).Scan(
		&stats.Last,
		&stats.High,
		&stats.Low,
		&stats.Volume,
		&stats.Change,
	)
	if err != nil {
		return TradeStats24h{}, mapPGError(err)
	}
	return stats, nil
}

func (r *Repository) GetMarketDiagnostics(ctx context.Context, assetAddress string, subID string) (MarketDiagnostics, error) {
	const query = `
with bid_counts as (
  select count(*)::int4 as count
  from active_orders
  where asset_address = $1 and sub_id = $2 and side = 'buy' and status in ('active', 'matching')
),
ask_counts as (
  select count(*)::int4 as count
  from active_orders
  where asset_address = $1 and sub_id = $2 and side = 'sell' and status in ('active', 'matching')
),
trade_stats as (
  select count(*)::int8 as count, max(created_at) as last_trade_at
  from trade_fills
  where asset_address = $1 and sub_id = $2
)
select
  coalesce((select count from bid_counts), 0),
  coalesce((select count from ask_counts), 0),
  coalesce((select count from trade_stats), 0),
  (select last_trade_at from trade_stats)
`

	var diagnostics MarketDiagnostics
	err := r.pool.QueryRow(ctx, query, strings.ToLower(assetAddress), subID).Scan(
		&diagnostics.OpenBidCount,
		&diagnostics.OpenAskCount,
		&diagnostics.TradeCount,
		&diagnostics.LastTradeTimestamp,
	)
	if err != nil {
		return MarketDiagnostics{}, mapPGError(err)
	}

	return diagnostics, nil
}

func (r *Repository) bestBySide(ctx context.Context, assetAddress string, subID string, side Side) (*Order, error) {
	orders, err := r.listBySide(ctx, assetAddress, subID, side, 1)
	if err != nil {
		return nil, err
	}
	if len(orders) == 0 {
		return nil, nil
	}
	return &orders[0], nil
}

func lockBestBySide(ctx context.Context, tx pgx.Tx, assetAddress string, subID string, side Side) (*Order, error) {
	slog.Info(
		"lock_best_by_side_start",
		"asset_address", strings.ToLower(assetAddress),
		"sub_id", subID,
		"side", side,
	)

	orderBy := "limit_price_ticks::numeric desc, created_at asc"
	if side == SideSell {
		orderBy = "limit_price_ticks::numeric asc, created_at asc"
	}

	query := fmt.Sprintf(`
select order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
       desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
from active_orders
where asset_address = $1 and sub_id = $2 and side = $3 and status = 'active'
order by %s
limit 1
for update skip locked
`, orderBy)

	order, err := scanOrder(tx.QueryRow(ctx, query, assetAddress, subID, side))
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			slog.Info(
				"lock_best_by_side_empty",
				"asset_address", strings.ToLower(assetAddress),
				"sub_id", subID,
				"side", side,
			)
			return nil, nil
		}
		return nil, err
	}

	slog.Info(
		"lock_best_by_side_hit",
		"asset_address", strings.ToLower(assetAddress),
		"sub_id", subID,
		"side", side,
		"order_id", order.OrderID,
		"order_status", order.Status,
		"price_ticks", order.LimitPriceTicks,
		"desired_amount", order.DesiredAmount,
		"filled_amount", order.FilledAmount,
	)
	return &order, nil
}

func reserveOrders(ctx context.Context, tx pgx.Tx, orderIDs []string) error {
	const query = `
update active_orders
set status = 'matching'
where order_id = any($1) and status = 'active'
`

	tag, err := tx.Exec(ctx, query, orderIDs)
	if err != nil {
		return mapPGError(err)
	}
	if tag.RowsAffected() != int64(len(orderIDs)) {
		return fmt.Errorf("failed to reserve all orders")
	}
	return nil
}

func expireOrders(ctx context.Context, tx pgx.Tx, now time.Time) error {
	const query = `
update active_orders
set status = 'expired'
where status = 'active' and expiry <= $1
`

	_, err := tx.Exec(ctx, query, now.Unix())
	return mapPGError(err)
}

func applyFill(ctx context.Context, tx pgx.Tx, orderID string, fillAmount string) (Order, error) {
	const selectQuery = `
select order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
       desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
from active_orders
where order_id = $1 and status = 'matching'
for update
`

	order, err := scanOrder(tx.QueryRow(ctx, selectQuery, orderID))
	if err != nil {
		return Order{}, err
	}

	newFilledAmount, err := addDecimalString(order.FilledAmount, fillAmount)
	if err != nil {
		return Order{}, err
	}

	status := StatusActive
	cmp, err := compareDecimalStrings(newFilledAmount, order.DesiredAmount)
	if err != nil {
		return Order{}, err
	}
	switch {
	case cmp > 0:
		return Order{}, fmt.Errorf("fill amount exceeds desired amount for order %s", order.OrderID)
	case cmp == 0:
		status = StatusFilled
	}

	const updateQuery = `
update active_orders
set filled_amount = $2, status = $3
where order_id = $1
`

	_, err = tx.Exec(ctx, updateQuery, orderID, newFilledAmount, status)
	if err != nil {
		return Order{}, mapPGError(err)
	}
	order.FilledAmount = newFilledAmount
	order.Status = status
	return order, nil
}

func insertTradeFill(ctx context.Context, tx pgx.Tx, taker Order, maker Order, price string, size string) error {
	const query = `
insert into trade_fills (
  asset_address,
  sub_id,
  price,
  size,
  aggressor_side,
  taker_order_id,
  maker_order_id
) values ($1, $2, $3, $4, $5, $6, $7)
`

	_, err := tx.Exec(
		ctx,
		query,
		strings.ToLower(taker.AssetAddress),
		taker.SubID,
		price,
		size,
		taker.Side,
		taker.OrderID,
		maker.OrderID,
	)
	return mapPGError(err)
}

func chooseTakerMaker(left Order, right Order) (Order, Order) {
	if left.CreatedAt.After(right.CreatedAt) {
		return left, right
	}
	if right.CreatedAt.After(left.CreatedAt) {
		return right, left
	}
	if left.OrderID > right.OrderID {
		return left, right
	}
	return right, left
}

func scanOrder(row pgx.Row) (Order, error) {
	var order Order
	if err := row.Scan(
		&order.OrderID,
		&order.OwnerAddress,
		&order.SignerAddress,
		&order.SubaccountID,
		&order.RecipientID,
		&order.Nonce,
		&order.Side,
		&order.AssetAddress,
		&order.SubID,
		&order.DesiredAmount,
		&order.FilledAmount,
		&order.LimitPrice,
		&order.LimitPriceTicks,
		&order.WorstFee,
		&order.Expiry,
		&order.ActionJSON,
		&order.Signature,
		&order.Status,
		&order.CreatedAt,
	); err != nil {
		return Order{}, mapPGError(err)
	}

	return order, nil
}

func mapPGError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}

	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return fmt.Errorf("duplicate order: %w", err)
	}

	return err
}

func (o Order) IsExpired(now time.Time) bool {
	return o.Expiry <= now.Unix()
}

func addDecimalString(a string, b string) (string, error) {
	left, ok := new(big.Int).SetString(a, 10)
	if !ok {
		return "", fmt.Errorf("invalid decimal value")
	}
	right, ok := new(big.Int).SetString(b, 10)
	if !ok {
		return "", fmt.Errorf("invalid decimal value")
	}
	return new(big.Int).Add(left, right).String(), nil
}

func compareDecimalStrings(a string, b string) (int, error) {
	left, ok := new(big.Int).SetString(a, 10)
	if !ok {
		return 0, fmt.Errorf("invalid decimal value")
	}
	right, ok := new(big.Int).SetString(b, 10)
	if !ok {
		return 0, fmt.Errorf("invalid decimal value")
	}
	return left.Cmp(right), nil
}
