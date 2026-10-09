-- A row per sponsored deposit (POST /v1/deposits), keyed by the action's EIP-712 struct hash -- Matching.getActionHash,
-- the same key execution-service is idempotent on. It is what lets a retried request, a restart or a receipt timeout
-- be answered from what already happened instead of resubmitted, and what GET /v1/deposits/{action_hash} reads.
--
-- status: pending   claimed; being checked and submitted
--         submitted broadcast; the receipt is not known yet (a timeout); GET re-reads it from the chain
--         confirmed mined successfully
--         reverted  mined and reverted
--         rejected  refused before anything was broadcast; the same request may be retried
--         unknown   the venue could not confirm whether it was submitted
create table if not exists deposits (
  action_hash text primary key,
  owner text not null,
  nonce text not null,
  subaccount_id_requested text not null,
  amount_units numeric(78, 0) not null,
  status text not null check (status in ('pending', 'submitted', 'confirmed', 'reverted', 'rejected', 'unknown')),
  tx_hash text,
  permit_tx_hash text,
  block_number text,
  subaccount_id text,
  error text,
  revert text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists deposits_owner_created_at_idx on deposits (owner, created_at desc);
