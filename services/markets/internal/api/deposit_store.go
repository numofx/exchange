package api

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// depositRecord is one row of the deposits table (migration 000018).
type depositRecord struct {
	ActionHash            string    `json:"action_hash"`
	Owner                 string    `json:"owner"`
	Nonce                 string    `json:"nonce"`
	SubaccountIDRequested string    `json:"subaccount_id_requested"`
	AmountUnits           string    `json:"amount_units"`
	Status                string    `json:"status"`
	TxHash                string    `json:"tx_hash,omitempty"`
	PermitTxHash          string    `json:"permit_tx_hash,omitempty"`
	BlockNumber           string    `json:"block_number,omitempty"`
	SubaccountID          string    `json:"subaccount_id,omitempty"`
	Error                 string    `json:"error,omitempty"`
	Revert                string    `json:"revert,omitempty"`
	CreatedAt             time.Time `json:"created_at"`
	UpdatedAt             time.Time `json:"updated_at"`
}

const (
	depositPending   = "pending"
	depositSubmitted = "submitted"
	depositConfirmed = "confirmed"
	depositReverted  = "reverted"
	depositRejected  = "rejected"
	depositUnknown   = "unknown"
)

// depositStore persists deposits by action hash, so idempotency and status survive restarts and receipt timeouts.
type depositStore interface {
	// Claim inserts a pending record. If one exists it is returned unchanged with claimed false -- unless it is
	// rejected (nothing was sent), in which case it is reset to pending and claimed is true: the same request may be
	// retried after it was refused.
	Claim(ctx context.Context, rec depositRecord) (existing depositRecord, claimed bool, err error)
	Save(ctx context.Context, rec depositRecord) error
	Get(ctx context.Context, actionHash string) (depositRecord, bool, error)
}

type pgDepositStore struct{ pool *pgxpool.Pool }

const depositColumns = `action_hash, owner, nonce, subaccount_id_requested, amount_units::text, status,
	coalesce(tx_hash, ''), coalesce(permit_tx_hash, ''), coalesce(block_number, ''), coalesce(subaccount_id, ''),
	coalesce(error, ''), coalesce(revert, ''), created_at, updated_at`

func scanDeposit(row pgx.Row) (depositRecord, error) {
	var r depositRecord
	err := row.Scan(&r.ActionHash, &r.Owner, &r.Nonce, &r.SubaccountIDRequested, &r.AmountUnits, &r.Status,
		&r.TxHash, &r.PermitTxHash, &r.BlockNumber, &r.SubaccountID, &r.Error, &r.Revert, &r.CreatedAt, &r.UpdatedAt)
	return r, err
}

func (s *pgDepositStore) Claim(ctx context.Context, rec depositRecord) (depositRecord, bool, error) {
	// One statement: insert, or reclaim a rejected row; anything else is left as it is and read back.
	row := s.pool.QueryRow(ctx, `
		insert into deposits (action_hash, owner, nonce, subaccount_id_requested, amount_units, status)
		values ($1, $2, $3, $4, $5::numeric, 'pending')
		on conflict (action_hash) do update
		  set status = 'pending', error = null, revert = null, updated_at = now()
		  where deposits.status = 'rejected'
		returning `+depositColumns,
		rec.ActionHash, rec.Owner, rec.Nonce, rec.SubaccountIDRequested, rec.AmountUnits)
	claimed, err := scanDeposit(row)
	if err == nil {
		return claimed, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return depositRecord{}, false, err
	}
	existing, _, err := s.Get(ctx, rec.ActionHash)
	return existing, false, err
}

func (s *pgDepositStore) Save(ctx context.Context, rec depositRecord) error {
	_, err := s.pool.Exec(ctx, `
		update deposits set status = $2, tx_hash = nullif($3, ''), permit_tx_hash = nullif($4, ''),
		  block_number = nullif($5, ''), subaccount_id = nullif($6, ''), error = nullif($7, ''), revert = nullif($8, ''),
		  updated_at = now()
		where action_hash = $1`,
		rec.ActionHash, rec.Status, rec.TxHash, rec.PermitTxHash, rec.BlockNumber, rec.SubaccountID, rec.Error, rec.Revert)
	return err
}

func (s *pgDepositStore) Get(ctx context.Context, actionHash string) (depositRecord, bool, error) {
	rec, err := scanDeposit(s.pool.QueryRow(ctx, `select `+depositColumns+` from deposits where action_hash = $1`, actionHash))
	if errors.Is(err, pgx.ErrNoRows) {
		return depositRecord{}, false, nil
	}
	return rec, err == nil, err
}

// memDepositStore is depositStore in memory, for tests.
type memDepositStore struct {
	mu   sync.Mutex
	rows map[string]depositRecord
}

func newMemDepositStore() *memDepositStore { return &memDepositStore{rows: map[string]depositRecord{}} }

func (s *memDepositStore) Claim(_ context.Context, rec depositRecord) (depositRecord, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.rows[rec.ActionHash]; ok && existing.Status != depositRejected {
		return existing, false, nil
	}
	rec.Status = depositPending
	rec.CreatedAt, rec.UpdatedAt = time.Now(), time.Now()
	s.rows[rec.ActionHash] = rec
	return rec, true, nil
}

func (s *memDepositStore) Save(_ context.Context, rec depositRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec.UpdatedAt = time.Now()
	s.rows[rec.ActionHash] = rec
	return nil
}

func (s *memDepositStore) Get(_ context.Context, hash string) (depositRecord, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.rows[hash]
	return rec, ok, nil
}
