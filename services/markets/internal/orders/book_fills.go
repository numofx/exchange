package orders

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// BookFill is one OnchainBook Fill event, in the venue's units: Price quote per base and Size in the series' order
// units, as the matcher's rows are. It goes on the series' tape (trade_fills, source 'book') with no order ids.
type BookFill struct {
	TxHash            string
	LogIndex          uint64
	BlockNumber       uint64
	BlockTime         time.Time
	AssetAddress      string
	SubID             string
	TakerSubaccountID string
	MakerSubaccountID string
	// Side is the taker's, the aggressor's.
	Side     Side
	Price    string
	Size     string
	TakerFee string
}

// BookTake is one TakeExecuted event: the take its fills belong to.
type BookTake struct {
	TxHash            string
	LogIndex          uint64
	BlockNumber       uint64
	BlockTime         time.Time
	BookAddress       string
	MarketID          string
	AssetAddress      string
	SubID             string
	TakerSubaccountID string
	Side              Side
	Filled            string
	// AvgPrice is empty when nothing filled.
	AvgPrice  string
	Fee       string
	FillCount int
}

// BookIndexCursor is the last block the book indexer has applied for the book; ok false before its first run.
func (r *Repository) BookIndexCursor(ctx context.Context, book string) (block uint64, ok bool, err error) {
	var stored int64
	err = r.pool.QueryRow(ctx, `select block_number from book_index_cursor where book_address = $1`,
		strings.ToLower(strings.TrimSpace(book))).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, mapPGError(err)
	}
	return uint64(stored), true, nil
}

// ApplyBookEvents writes a block range's fills and takes and moves the cursor to `through`, in one transaction, so
// a range is either wholly on the tape or not at all. A row already written (the same transaction and log index) is
// left alone: re-reading a range after a crash between the chain read and the commit writes nothing twice.
func (r *Repository) ApplyBookEvents(ctx context.Context, book string, fills []BookFill, takes []BookTake, through uint64) (newFills, newTakes int, err error) {
	book = strings.ToLower(strings.TrimSpace(book))
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	for _, f := range fills {
		tag, err := tx.Exec(ctx, `
insert into trade_fills (
  asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, taker_fee, tx_hash, created_at,
  source, log_index, taker_subaccount_id, maker_subaccount_id
) values ($1, $2, $3, $4, $5, '', '', $6, $7, $8, 'book', $9, $10::numeric, $11::numeric)
on conflict (tx_hash, log_index) where source = 'book' do nothing`,
			strings.ToLower(f.AssetAddress), f.SubID, f.Price, f.Size, f.Side, f.TakerFee, strings.ToLower(f.TxHash),
			f.BlockTime, int64(f.LogIndex), f.TakerSubaccountID, f.MakerSubaccountID)
		if err != nil {
			return 0, 0, mapPGError(err)
		}
		newFills += int(tag.RowsAffected())
	}
	for _, t := range takes {
		tag, err := tx.Exec(ctx, `
insert into book_takes (
  tx_hash, log_index, book_address, market_id, asset_address, sub_id, taker_subaccount_id, side, filled, avg_price,
  fee, fill_count, block_number, block_time
) values ($1, $2, $3, $4::numeric, $5, $6, $7::numeric, $8, $9, $10, $11, $12, $13, $14)
on conflict (tx_hash, log_index) do nothing`,
			strings.ToLower(t.TxHash), int64(t.LogIndex), book, t.MarketID, strings.ToLower(t.AssetAddress), t.SubID,
			t.TakerSubaccountID, t.Side, t.Filled, t.AvgPrice, t.Fee, t.FillCount, int64(t.BlockNumber), t.BlockTime)
		if err != nil {
			return 0, 0, mapPGError(err)
		}
		newTakes += int(tag.RowsAffected())
	}
	if err := setBookCursor(ctx, tx, book, through); err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, err
	}
	return newFills, newTakes, nil
}

// SetBookIndexCursor places the cursor without writing anything: the indexer's first run, at the block before the
// book's deploy.
func (r *Repository) SetBookIndexCursor(ctx context.Context, book string, block uint64) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := setBookCursor(ctx, tx, strings.ToLower(strings.TrimSpace(book)), block); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func setBookCursor(ctx context.Context, tx pgx.Tx, book string, block uint64) error {
	_, err := tx.Exec(ctx, `
insert into book_index_cursor (book_address, block_number) values ($1, $2)
on conflict (book_address) do update set block_number = excluded.block_number, updated_at = now()`, book, int64(block))
	return mapPGError(err)
}
