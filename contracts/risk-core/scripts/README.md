# Deployment script

## Runbook note (Base)

For Base (`chainId 8453`), always run deploy scripts with `--slow` in this flow to force serialized sends and avoid provider nonce/in-flight transaction errors.

## Setup

Add an `.env` file with following:

```python
# required
PRIVATE_KEY=<your key>
```

And run this to make sure it's loaded in shell
```
source .env
```

Also, it's easier to add the rpc network into `foundry.toml`, so we can use the alias later in the script

```
[rpc_endpoints]
sepolia = https://sepolia.infura.io/v3/26251a7744c548a3adbc17880fc70764
```


## Deploying to a new network 

## 1. Deploy mock contracts if needed:

If you don't need to deploy mock contracts (for example doing on mainnet or L2), just add the following config to `scripts/input/<networkId>/config.json`:

```json
{
  "usdc": "0xe80F2a02398BBf1ab2C9cc52caD1978159c215BD",
  "useMockedFeed": false,
  "wbtc": "0xF1493F3602Ab0fC576375a20D7E4B4714DB4422d",
  "weth": "0x3a34565D81156cF0B1b9bC5f14FD00333bcf6B93"
}
```

If you're deploying to a new testnet and need to deploy some mocked USDC, WBTC and WETH, we have a setup script already which generates the config file for the network. Let's assume the networkId is 999, run the following command:

```shell
# where the config will live
mkdir scripts/input/999

# deploy mocks and write (or override) config. 
# Note: Replace sepolia with other network alias if needed
forge script scripts/deploy-erc20s.s.sol  --rpc-url sepolia --broadcast
```

## 2. Deploy Core contracts

Run the following script, (assuming network id = 999)

```shell
# create folder to store deployed addresses
mkdir deployments/999

forge script scripts/deploy-core.s.sol  --rpc-url sepolia --broadcast
```


To change parameters: goes to `scripts/config-mainnet.sol` and update the numbers.

Example Output 
```
== Logs ==
  Start deploying core contracts! deployer:  0x77774066be05E9725cf12A583Ed67F860d19c187
  predicted addr 0xfe3e0ACFA9f4165DD733FCF6912c9d90c3aC0008
  Core contracts deployed and setup!
  Written to deployment  options-core/deployments/901/core.json
```

The configs will now be written as something like this: (example `deployment/901/core.json`)
```
{
  "auction": "0x6772299e3b0C7FF1AC8728F942A252e72CA1b521",
  "cash": "0x41d847D2dF78b27c0Bc730F773993EfE247c3f78",
  "rateModel": "0x1d61223Caea948f97d657aB3189e23F48888b6b0",
  "securityModule": "0x59E8b474a8061BCaEF705c7B93a903dE161FD149",
  "srm": "0xfe3e0ACFA9f4165DD733FCF6912c9d90c3aC0008",
  "srmViewer": "0xDb1791026c3824441FAe8A105b08E40dD02e1469",
  "stableFeed": "0xb77efe3e7c049933853e2C845a1412bCd36a2899",
  "subAccounts": "0x1dC3c8f65529E32626bbbb901cb743d373a7193e"
}
```

### 3. Deploy Single Market

Running this script will create a new set of "Assets" for this market, create a new PMRM, and link everything to the shared standard manager + setup default parameters

Not that you need to pass in the "market" you want to deploy with env variables. Similarly you can update default params in `scripts/config-mainnet.sol` before running the script.

```shell
MARKET_NAME=weth forge script scripts/deploy-market.s.sol  --rpc-url sepolia --broadcast
```

#### Output
```
== Logs ==
  Start deploying new market:  weth
  Deployer:  0x77774066be05E9725cf12A583Ed67F860d19c187
  target erc20: 0x3a34565D81156cF0B1b9bC5f14FD00333bcf6B93
  All asset whitelist both managers!
  market ID for newly created market: 1
  Written to deployment  /numo/options-core/deployments/999/weth.json
```

And every address will be stored in `deployments/999/weth.json`

```json
{
  "base": "0xF79FFb054429fb2b261c0896490f392fc8Ab998d",
  "forwardFeed": "0x48326634Ad484F086A9939cCF162960d8b3ce1D0",
  "iapFeed": "0x31de1F10347f8CBa52242A95dC7934FA98E70975",
  "ibpFeed": "0x45eC148853607f0969c5aB053fd10d59FA340B0A",
  "option": "0xc8FE03d1183053c1F3187c76A8A003323B9C5314",
  "perp": "0xAFf5ae727AecAf8aD4B03518248B5AD073edd99d",
  "perpFeed": "0xBbfb755C9B7A5DDEBc67651bAA15C659d001baD1",
  "pmrm": "0x105E635F61676E3a71bFAE7C02D17acd81A9b1D0",
  "pmrmLib": "0x991f05b9b450333347d266Fe362CFE19973FA70A",
  "pmrmViewer": "0x9F21BFA6607Eb71372B2654dfd528505896cB90B",
  "pricing": "0xD9d8d903707e03A7Cb1D8c9e3338F4E1Cc5Ec136",
  "rateFeed": "0x95721653d1E1C77Ac5cE09c93f7FF11dd5D87190",
  "spotFeed": "0x8a4A11BBE33C25F03a8b11EaC32312E2360858aD",
  "volFeed": "0xc97d681A8e58e4581F7456C2E5bC9F4CF26b236a"
}
```

You can update the market name to "wbtc" and run the script again to deploy wbtc markets.

### 4. Deploy Squared-Perp Market (Base)

For Base (`chainId 8453`), run the squared-perp deployment with `--slow`.

This flow assumes:
- `deployments/8453/core.json` already exists
- the underlying market JSON already exists at `deployments/8453/<MARKET_NAME>.json`
- the existing market JSON contains the `spotFeed` to reuse for the squared perp

Example for `SFP`:

```shell
MARKET_NAME=SFP forge script scripts/deploy-squared-perp-market.s.sol --rpc-url base --broadcast --slow
```

This deploys:
- a new `SquaredPerpAsset`
- new perp and impact price diff feeds
- a dedicated `SquaredPerpManager`
- a dedicated `BasePortfolioViewer`

The deployment artifact is written to:

```text
deployments/8453/SFP_SQUARED.json
```

The artifact includes:
- the new squared perp address
- the manager and viewer addresses
- the perp and impact feeds
- `managerConfig`
- `riskConfig`

Example artifact shape:

```json
{
  "spotFeed": "0x...",
  "perp": "0x...",
  "perpFeed": "0x...",
  "iapFeed": "0x...",
  "ibpFeed": "0x...",
  "manager": "0x...",
  "viewer": "0x...",
  "managerConfig": {
    "maxAccountSize": 128,
    "minOIFee": 50000000000000000000,
    "oiFeeRateBPS": 100000000000000000,
    "perpCap": 250000000000000000000000
  },
  "riskConfig": {
    "isWhitelisted": true,
    "isSquared": true,
    "initialMarginRatio": 200000000000000000,
    "maintenanceMarginRatio": 120000000000000000,
    "initialMaxLeverage": 5000000000000000000,
    "maintenanceMaxLeverage": 5000000000000000000,
    "initialSpotShockUp": 200000000000000000,
    "initialSpotShockDown": 200000000000000000,
    "maintenanceSpotShockUp": 100000000000000000,
    "maintenanceSpotShockDown": 100000000000000000
  }
}
```

### 5. Deploy BTC Squared-Perp Market On Base (Chainlink Spot)

For `MARKET_NAME=BTC` on Base (`chainId 8453`), the squared-perp deployment script will:
- deploy a `SquaredPerpAsset`
- deploy new `perpFeed`, `iapFeed`, and `ibpFeed` contracts
- deploy a dedicated `SquaredPerpManager`
- deploy a dedicated `BasePortfolioViewer`
- deploy a `ChainlinkSpotFeed` adapter for the Base BTC/USD Chainlink oracle

The Chainlink BTC/USD spot oracle used in this flow is:

```text
0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
```

This means `deployments/8453/BTC.json` is not required just to source a spot feed.

Prerequisites:
- `deployments/8453/core.json` exists
- `deployments/8453/shared.json` exists
- `PRIVATE_KEY` is set in `.env`
- the deployer wallet has Base ETH for gas

Run:

```shell
source .env
MARKET_NAME=BTC forge script scripts/deploy-squared-perp-market.s.sol --rpc-url base --broadcast --slow
```

If you are not using a `base` alias in `foundry.toml`, pass the full Base RPC URL instead.

Artifact output:

```text
deployments/8453/BTC_SQUARED.json
```

Important operational note:
- the script deploys `perpFeed`, `iapFeed`, and `ibpFeed`
- those contracts do not self-update
- after deployment they still require signed feed updates from the configured signers in `deployments/8453/shared.json`

The BTC Chainlink spot feed covers the `spotFeed` input only. The market still needs live updates for:
- `perpFeed`
- `iapFeed`
- `ibpFeed`

### 6. Run BTC Squared-Perp Feed Updater

The repo includes a minimal updater at:

```text
scripts/update_btc_squared_feeds.py
```

It uses:
- onchain `spotFeed` as the BTC/USD anchor
- Binance `BTCUSDT` perpetual best bid/ask midpoint as the mark source

### 7. Deploy Deliverable `USDC/cNGN APR-30-2026` Future

This flow deploys the dedicated `DeliverableFXManager`, `BasePortfolioViewer`, and
`DeliverableFXFutureAsset` for the April 30, 2026 contract.

Use this path for deliverable FX staging and production.
Do not route this product through the existing `StandardManager`.

Prerequisites:
- `deployments/<chainId>/core.json` exists
- `deployments/<chainId>/WRAPPED_CNGN.json` exists
- `PRIVATE_KEY` is set
- `WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS` is set to an already deployed `WrappedERC20Asset` for deliverable `USDC`

For Base (`chainId 8453`), run with `--slow`.

Example:

```shell
source .env
forge script scripts/deploy-deliverable-fx-manager.s.sol --rpc-url base --broadcast --slow
```

The script hard-fails if:
- `lastTradeTime >= expiry`
- `WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS` is unset
- the existing `WRAPPED_CNGN` deployment does not contain `base` or `spotFeed`
- manager whitelisting or product wiring does not stick

Artifact output:

```text
deployments/8453/CNGN_APR30_2026_FUTURE.json
```

Artifact contents include:
- dedicated manager address
- dedicated viewer address
- future asset address
- series `subId`
- expiry / `lastTradeTime`
- base / quote asset addresses
- margin params and product constants

Downstream values to export into services:

```text
CNGN_APR30_2026_FUTURE_ASSET_ADDRESS=<future address>
CNGN_APR30_2026_FUTURE_SUB_ID=<series subId>
```

### 8. Canonical Launch Smoke Test

Treat the dedicated deliverable FX path as the canonical launch smoke test for this product.
Do not route this through `StandardManager`.
Do not change this path unless a new bug appears.

Canonical sequence:

1. deploy with `scripts/deploy-deliverable-fx-manager.s.sol`
2. export `CNGN_APR30_2026_FUTURE_ASSET_ADDRESS` and `CNGN_APR30_2026_FUTURE_SUB_ID`
3. boot `markets-service`
4. submit one tiny crossed live order pair
5. confirm exactly one `trade_fills` row lands
6. confirm `GET /v1/trades` returns that fill
7. confirm `stats_24h.last` equals the fill price

Hard readiness checks before launch:

- `quoteSpotFeed.getSpot()` must succeed onchain
- `/v1/trades` must reflect the latest live fill

If either check fails, the market is not launch-ready.

### 9. Feed Updater Notes

- a fixed spread around mark for `iapFeed` and `ibpFeed`
- one or more signer keys for the EIP-712 feed signatures
- one relayer key to submit transactions
- the deployed `OracleDataSubmitter` to batch all pending feed updates into one transaction

Required env vars:

```text
BASE_RPC_URL=...
SIGNER1_PRIVATE_KEY=...
```

Optional env vars:

```text
RELAYER_PRIVATE_KEY=...
SIGNER2_PRIVATE_KEY=...
DATA_SUBMITTER=...
```

If `RELAYER_PRIVATE_KEY` is omitted, the updater falls back to `PRIVATE_KEY`, then `SIGNER1_PRIVATE_KEY`.
If your feeds are configured with `requiredSigners = 1`, `SIGNER1_PRIVATE_KEY` alone is enough.
If `DATA_SUBMITTER` is omitted, the updater uses `deployments/8453/core.json`.

Optional env vars:

```text
BTC_SQUARED_MAX_BASIS_BPS=30
BTC_SQUARED_IMPACT_SPREAD_BPS=10
BTC_SQUARED_UPDATE_THRESHOLD_BPS=10
BTC_SQUARED_LOOP_INTERVAL_SEC=60
BTC_SQUARED_DEADLINE_SEC=30
BTC_SQUARED_CONFIDENCE=1000000000000000000
BTC_SQUARED_TIMESTAMP_SAFETY_SEC=15
```

Run once:

```shell
python3 scripts/update_btc_squared_feeds.py --once
```

Dry run:

```shell
python3 scripts/update_btc_squared_feeds.py --once --dry-run
```

Run continuously:

```shell
python3 scripts/update_btc_squared_feeds.py
```

The updater submits to:
- `perpFeed`
- `iapFeed`
- `ibpFeed`

By default it batches those updates through the Base `dataSubmitter` in a single transaction per cycle.

It does not publish squared prices. It publishes linear BTC perp and impact inputs, and the onchain `SquaredPerpAsset` squares them internally.
