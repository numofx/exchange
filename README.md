# markets-service

Offchain backend for the `matching` contracts.

Initial scope:

- one order type: limit order
- one module path: `TradeModule`
- one executor
- one matching loop

This repo is intentionally narrow. It is not a generic exchange backend.

## Responsibilities

- expose a minimal API for order entry and book inspection
- run a price-time matching loop
- submit executor payloads for `Matching.verifyAndMatch(...)`

## Out of Scope

- RFQ
- liquidation
- multi-market support
- websocket market data
- a full frontend
- direct onchain execution from Go

## Layout

```text
cmd/
  api/        HTTP API for orders and health checks
  matcher/    background matching worker
internal/
  api/        HTTP server wiring and handlers
  config/     environment configuration
  db/         Postgres connection helpers
  instruments/ instrument metadata and registry
  matching/   matching loop and orchestration
  orders/     order model and repository contracts
migrations/   database schema
```

## Configuration

Copy `.env.example` into your own environment and set the required values.

Important values:

- `DATABASE_URL`
- `API_ADDR`
- `MATCHER_POLL_INTERVAL`
- `CHAIN_ID`
- `MATCHING_ADDRESS`
- `TRADE_MODULE_ADDRESS`
- `CNGN_SEP16_2026_FUTURE_ASSET_ADDRESS`
- `CNGN_SEP16_2026_FUTURE_SUB_ID`
- optionally `EXPECTED_ORDER_OWNER`
- optionally `EXPECTED_ORDER_SIGNER`



Each physically delivered future (e.g. `USDC-cNGN-SEP16-2026`) is only enabled when both its
`*_FUTURE_ASSET_ADDRESS` and `*_FUTURE_SUB_ID` env values are set. The registry resolves the
instrument by exact `(asset_address, sub_id)` and exposes the canonical market symbol
(e.g. `USDCcNGN-SEP16-2026`). Human-readable pair formatting remains in display fields such as
`display_name` and `display_label`.

- `contract_type=deliverable_fx_future`
- `settlement_type=physical_delivery`
- `base_asset_symbol=USDC`
- `quote_asset_symbol=cNGN`

If `EXPECTED_ORDER_OWNER` or `EXPECTED_ORDER_SIGNER` are set, the API rejects orders whose declared owner/signer do not match those configured addresses. The API also validates that `action_json.owner`, `action_json.signer`, `action_json.subaccount_id`, and `action_json.nonce` match the stored order fields.
With `ENFORCE_ACTION_DATA_INVARIANTS=true` (default), the API also rejects orders unless:

- `action_json.data.asset` matches `asset_address`
- `action_json.data.subId` matches `sub_id`
- `action_json.data.isBid` matches `side`
- `action_json.data.limitPrice` and `action_json.data.desiredAmount` are on the same canonical scale as normalized engine fields

Custody requirement for onchain execution:

- Orders submitted for `verifyAndMatch` must reference subaccounts already deposited into `Matching`.
- API pre-submit guard (enabled by default) checks both:
- `SubAccounts.ownerOf(subaccount_id) == MATCHING_ADDRESS`
- `Matching.subAccountToOwner(subaccount_id) != 0x0000000000000000000000000000000000000000`
- If these checks fail, order submit is rejected before persistence/executor.

Relevant env:

- `ENFORCE_MATCHING_CUSTODY=true`
- `ENFORCE_ACTION_DATA_INVARIANTS=true`
- `MATCHING_ADDRESS=0x...`
- `CHAIN_RPC_URL=https://...` (required when custody guard is enabled and matching is configured)

`EXECUTOR_URL` is the endpoint for a separate executor process, likely implemented in
TypeScript with `viem`, that performs simulation and submits `verifyAndMatch(...)`.

`EXECUTOR_MANAGER_DATA` lets the matcher attach the exact `manager_data` hex required by the
executor call. If the blob is too large for an env var, set `EXECUTOR_MANAGER_DATA_FILE`
instead. That file may contain either the raw hex string or a JSON object with a
`manager_data` field.



Expected request body:

```json
{
  "market": "BTCUSDC-CVXPERP",
  "asset_address": "0x...",
  "module_address": "0x...",
  "maker_order_id": "maker-order-id",
  "taker_order_id": "taker-order-id",
  "actions": [
    {
      "subaccount_id": "123",
      "nonce": "1",
      "module": "0x...",
      "data": "0x...",
      "expiry": "1710000000",
      "owner": "0x...",
      "signer": "0x..."
    }
  ],
  "signatures": ["0x..."],
  "order_data": {
    "taker_account": "123",
    "taker_fee": "0",
    "fill_details": [
      {
        "filled_account": "456",
        "amount_filled": "1000000000000000000",
        "price": "78000000000000000000",
        "fee": "0"
      }
    ],
    "manager_data": "0x..."
  }
}
```

The executor may return an empty `2xx` response or JSON like:

```json
{
  "accepted": true,
  "tx_hash": "0x..."
}
```

## Development

Expected local stack:

- Go 1.24+
- PostgreSQL 16+

Suggested flow:

1. Start Postgres.
2. Apply migrations:

```bash
go run ./cmd/migrate
```
3. Run the API:

```bash
env $(cat .env.example | xargs) go run ./cmd/api
```

4. Run the matcher:

```bash
env $(cat .env.example | xargs) go run ./cmd/matcher
```

For a cleaner local env, export the variables from `.env.example` or use your usual dotenv tooling.

## Railway Deploy Contract

Production deploys are expected to run database migrations before the API starts.
This repository encodes that in `railway.toml`:

- Railway builds both the API binary and the migration binary.
- Railway runs `./migrate` as the pre-deploy command.
- Railway starts the service only after the migration step succeeds.

`DATABASE_URL` in Railway should be a reference variable to the Postgres service, for example
`${{Postgres.DATABASE_URL}}`, rather than a copied literal URL.

### EOA-Owned Order Submission

For an EOA-owned deployment, set:

```dotenv
EXPECTED_ORDER_OWNER=0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310
EXPECTED_ORDER_SIGNER=0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310
```

Then submit orders whose top-level fields and `action_json` agree on:

- `owner_address` / `action_json.owner`
- `signer_address` / `action_json.signer`
- `subaccount_id` / `action_json.subaccount_id`
- `nonce` / `action_json.nonce`



### Namespace Separation For Cancels

Service-tagged cancels (`/v1/orders/cancel` requests with `service`) are blocked for protected
order namespaces so bot sweeps cannot cancel manual/smoke/validation orders.

- `CANCEL_PROTECTED_ORDER_ID_PREFIXES=validation:,smoke:,manual:`

Manual cancels without a `service` tag are still allowed.

### Production Smoke: Deposited APR Cross

Use the built-in smoke script to run the exact deposited cross flow (`ask 0.001 @ 1390`,
`buy 0.001 @ 1391`) with real signed orders and assert `/v1/trades` increments:

```bash
PRIVATE_KEY=0x... \
./scripts/smoke_deposited_cross.sh
```

The script submits namespaced order IDs (`smoke:jun:...`) so they stay separated from bot order
namespaces and cancel sweeps, and then verifies terminal order state through `GET /v1/orders/{order_id}`.


