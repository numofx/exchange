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
- optionally `DRY_RUN=true`
- optionally `WAIT_FOR_RECEIPT=true`

If `MATCHING_ADDRESS` or `TRADE_MODULE_ADDRESS` are not set, the service resolves them from `<MATCHING_REPO_PATH>/deployments/<CHAIN_ID>/matching.json`.

## API

### `GET /healthz`

Returns service status, resolved contract addresses, and runtime mode flags.

### `POST /` or `POST /execute`

Accepts the payload emitted by `matching-backend`:

```json
{
  "market": "BTC-PERP",
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
