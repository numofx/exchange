# markets-service

Offchain backend for the `matching` contracts.

Initial scope:

- one order type: limit order
- one module path: `TradeModule`
- one executor
- one matching loop

This repo is intentionally narrow. It is not a generic exchange backend.

## Responsibilities

- expose a REST API for order entry and book inspection
- expose a WebSocket API for real-time `book`, `trades`, and (authenticated) `orders` streams
- run a price-time matching loop
- submit executor payloads for `Matching.verifyAndMatch(...)`

## Out of Scope

- RFQ
- liquidation
- a full frontend
- direct onchain execution from Go

## Layout

```text
cmd/
  api/        HTTP + WebSocket API for orders, book inspection, and health checks
  matcher/    background matching worker
  migrate/    database migration runner
internal/
  api/        HTTP/WebSocket server wiring and handlers
  config/     environment configuration
  db/         Postgres connection helpers
  events/     LISTEN/NOTIFY event hub fanning market_events out to WS subscribers
  instruments/ instrument metadata and registry
  matching/   matching loop and orchestration
  orders/     order model, repository contracts, and stream snapshots
  pricing/    price helpers
  wsauth/     EIP-191 signature verification for authenticated WS channels
migrations/   database schema (incl. market_events table + triggers)
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
- `CNGN_SPOT_ASSET_ADDRESS`
- `CASH_ASSET_ADDRESS` — CashAsset contract, for the pre-trade funding check
- `ENFORCE_FUNDING_CHECK` — default `true`

The pre-trade funding check needs `CASH_ASSET_ADDRESS`, `MATCHING_ADDRESS` and `CHAIN_RPC_URL`.
**With `ENFORCE_FUNDING_CHECK=true` and any of them missing, the service refuses to start in
production** — an inert guard is invisible from the outside, and a missing variable must not be the
difference between it running and not. Any `APP_ENV` other than `dev`/`development`/`local`/`test`/
`ci` counts as production, so a typo fails safe. To run without the check, set
`ENFORCE_FUNDING_CHECK=false` deliberately. Outside production it logs `funding_check_inert` and
continues.
- optionally `EXPECTED_ORDER_OWNER`
- optionally `EXPECTED_ORDER_SIGNER`



The spot market is only enabled when `CNGN_SPOT_ASSET_ADDRESS` is set. The registry resolves the
instrument by exact `(asset_address, sub_id)` and exposes the canonical market symbol
(`USDCcNGN-SPOT`). Human-readable pair formatting remains in display fields such as
`display_name` and `display_label`.

- `contract_type=spot`
- `settlement_type=spot`
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

### Order Signature Verification

The API rebuilds the EIP-712 digest `ActionVerifier` checks on-chain and recovers the signer from
`signature`. A signature that does not authorize the action can never settle, so without this the
order rests on the book as depth that cannot trade until it expires, and the matcher retries it on
the backoff schedule the whole time.

Contract signers are handled: when local recovery does not match, the signer is checked for code
and, if it has any, `isValidSignature` is called per ERC-1271 — mirroring
`SignatureChecker.isValidSignatureNow` in `ActionVerifier`. Session-key authorization
(`signer != owner`) is not checked here; it stays an on-chain concern.

Relevant env:

- `ENFORCE_ORDER_SIGNATURES=false` (default) — signatures are always checked and logged; this flag
  decides whether a bad one is rejected. Keep it off until the logs show a clean run against real
  traffic, since a digest that does not match the contract would reject every order.
- `CHAIN_ID` and `MATCHING_ADDRESS` — the EIP-712 domain. Verification is skipped entirely if
  either is unset.
- `CHAIN_RPC_URL` — only needed to resolve contract signers.

Log lines to watch:

- `order_signature_invalid` — the signature did not authorize the action
- `order_signature_unverifiable` — the check could not complete (for example an RPC failure), which
  never rejects, even when enforcing

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

The script submits namespaced order IDs (`smoke:spot:...`) so they stay separated from bot order
namespaces and cancel sweeps, and then verifies terminal order state through `GET /v1/orders/{order_id}`.


