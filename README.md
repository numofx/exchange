# matching-executor

TypeScript service that accepts offchain match payloads from `matching-backend`, ABI-encodes `TradeModule.OrderData`, simulates `Matching.verifyAndMatch(...)`, and submits the transaction against the sibling `../options/matching` contracts.

## Responsibilities

- accept match execution requests over HTTP
- load ABIs and deployment addresses from the sibling `../options/matching` repo by default
- validate that the payload matches the `TradeModule`/`Matching` interface shape
- ABI-encode `TradeModule.OrderData`
- simulate `verifyAndMatch(...)`
- submit the transaction with `viem`
- optionally wait for the receipt
- return `accepted` and `tx_hash`

## Configuration

Copy `.env.example` into your environment and set:

- `RPC_URL`
- `PRIVATE_KEY`
- `CHAIN_ID`
- optionally `MATCHING_REPO_PATH`
- optionally `MATCHING_ADDRESS`
- optionally `TRADE_MODULE_ADDRESS`
- optionally `EXPECTED_ACTION_OWNER`
- optionally `EXPECTED_ACTION_SIGNER`
- optionally `DRY_RUN=true`
- optionally `WAIT_FOR_RECEIPT=true`

If `MATCHING_ADDRESS` or `TRADE_MODULE_ADDRESS` are not set, the service resolves them from `<MATCHING_REPO_PATH>/deployments/<CHAIN_ID>/matching.json`.

For a self-hosted EOA-owned deployment, set `EXPECTED_ACTION_OWNER` and/or `EXPECTED_ACTION_SIGNER` to reject payloads whose actions do not match the addresses your deployment expects.

## API

### `GET /healthz`

Returns service status, resolved contract addresses, runtime mode flags, the derived executor address, and any configured action-owner/signer expectations.

### `POST /` or `POST /execute`

Accepts the payload emitted by `matching-backend`:

```json
{
  "market": "BTCUSDC-CVXPERP",
  "asset_address": "0x...",
  "module_address": "0x...",
  "maker_order_id": "maker-1",
  "taker_order_id": "taker-1",
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
    "manager_data": "0x"
  }
}
```

Success response:

```json
{
  "accepted": true,
  "tx_hash": "0x..."
}
```

If `WAIT_FOR_RECEIPT=true`, the response also includes `receipt_status` and `block_number` after mining.

## Development

```bash
pnpm install
pnpm dev
```

Type-check:

```bash
pnpm check
```

Run tests:

```bash
pnpm test
```

### Generate EOA-Owned Orders

You can generate a backend-ready signed order payload for an EOA-owned deployment with:

```bash
OWNER_PRIVATE_KEY=0x... \
CHAIN_ID=8453 \
RPC_URL=https://... \
MATCHING_ADDRESS=0xe4c2a55401F73A540CA6e1C43067Aa7164f89088 \
TRADE_MODULE_ADDRESS=0x5fba217bFf9DfE7EDaD333972866DbA83c50B0f2 \
ORDER_ID=taker-eoa-1 \
SUBACCOUNT_ID=10 \
RECIPIENT_ID=10 \
NONCE=1 \
EXPIRY=1893456000 \
ASSET_ADDRESS=0x... \
SUB_ID=0 \
SIDE=buy \
LIMIT_PRICE=78000000000000000000 \
DESIRED_AMOUNT=1000000000000000000 \
WORST_FEE=0 \
node scripts/generate_trade_order.mjs > taker-order.json
```

For sells, set `SIDE=sell`. `DESIRED_AMOUNT` stays a positive integer; the side is determined by `SIDE`, matching `TradeModule`'s `isBid` flag.

The emitted JSON can be posted directly to [../matching-backend/scripts/submit_eoa_order_pair.sh](/Users/robertleifke/Code/work/matching-backend/scripts/submit_eoa_order_pair.sh) or the backend `/v1/orders` endpoint.

### Deliverable FX future example

The execution path is generic over `asset_address + sub_id`, so the live Base staging `USDC/cNGN` future can be signed without code changes:

```bash
ASSET_ADDRESS=0x752803d72c1835cdcd300C7fDE6c7D7d2F12E679 \
SUB_ID=1777507200 \
SIDE=buy \
LIMIT_PRICE=1605000000000000000000 \
DESIRED_AMOUNT=100000000000000000 \
node scripts/generate_trade_order.mjs
```

That encodes a `0.1` contract order against the staged deliverable future.

### Create Or Inspect Subaccounts

Inspect current subaccount ownership on the configured deployment with:

```bash
TARGET_OWNER=0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310 \
bash scripts/list_subaccounts.sh
```

Create and deposit a new subaccount directly into `Matching` with:

```bash
MARKET=BTC_SQUARED \
bash scripts/create_subaccount.sh
```

This calls `Matching.createSubAccount(manager)`, which creates the `SubAccounts` NFT under the matching contract and records your EOA as the logical owner in `subAccountToOwner`.

To fund a subaccount with Base USDC cash collateral:

```bash
ACCOUNT_ID=6 \
AMOUNT_USDC=1 \
bash scripts/deposit_cash.sh
```

This approves Base USDC to the cash asset and then calls `CashAsset.deposit(accountId, stableAmount)`.
