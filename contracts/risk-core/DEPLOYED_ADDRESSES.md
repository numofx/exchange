# Deployed Addresses

## Base (8453) — current deployment

Deployed: 2026-07-15
Owner (all contracts): MPC vault **Numo-Manager-Admin** `0x1dcA42ab54Bd3862853A821F84B29BF65245F435`
Feed signer (cNGN spot + stable feed, 1-of-1): `0xdA1976E83D54B76D0c794B35262228960a1a918f`

Core + future contracts verified on Basescan and Base Blockscout (2026-07-22).
Dune decoding submitted for the same set (project `numo` → `numo_base.*` tables).

### Core

Artifact: [deployments/8453/core.json](deployments/8453/core.json)

- `subAccounts`: `0x7019244E25FA416e6Ca2ed2F3cA25277aef72843`
- `cash`: `0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6`
- `securityModule`: `0x7d646B55Ae73fFdF44A4D37b77925f0e69550e7c`
- `auction`: `0x0EfAe56b2b583b1E84c6E4269236163C1E8050E1`
- `srm`: `0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b`
- `srmViewer`: `0x1c08f30c204EE18EbBDc161c0f0864AFb826934b`
- `stableFeed`: `0x507D645682737C6640dc73b5aC858654BcB9854f`

<!-- BEGIN GENERATED: live SRM state -->

### Live SRM state

Generated from chain at block 51101002 by `scripts/ops/refresh_deployment_artifacts.py --write`.
Do not edit by hand — rerun the script. Narrative and transaction hashes live outside this block.

- `srm`: `0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b`
- `lastMarketId`: **2**
- `borrowingEnabled`: **false**  — negative cash is rejected outright
- `stableFeed`: `0x507D645682737C6640dc73b5aC858654BcB9854f` — **static**, reads `1`

| market | spot feed | kind | getSpot | marginFactor | IMScale | oracle contingency |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `0x507D645682737C6640dc73b5aC858654BcB9854f` | static | 1 | 0 | 0 | all zero |
| 2 | `0xec4ad7B2679f54eB3e971B10120cB56cF1c061A4` | static | 0.000743376686 | 0 | 0 | all zero |

Whitelisted assets:

- `0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84` — market 1, `AssetType.Base`, wraps `USDC` `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493` — market 2, `AssetType.Base`, wraps `cNGN` `0x46C85152bFe9f96829aA94755D9f915F9B10EF5F`

**The SRM reads no live feed**, so no publisher outage can halt settlement.

<!-- END GENERATED -->

### USDC/cNGN SEP-16-2026 deliverable FX future

Artifact: [deployments/8453/CNGN_SEP16_2026_FUTURE.json](deployments/8453/CNGN_SEP16_2026_FUTURE.json)

Redeployed 2026-07-17 with the VM-denomination fix and mark-price bounds
(5% max deviation per update, 600s staleness cap). Initial mark 1379.64.

- `manager` (DeliverableFXManager): `0xcE01f3D74400caE39bd7608cd2d286C2e3874d49`
- `viewer`: `0xB0B4A877Ee72E00f677411AB828149431E659a56`
- `future` (DeliverableFXFutureAsset): `0xDd9c2Ddf97a2Dc9B9d348DcD0ef776aF5291A1F9`
- `baseAsset` (wrapped USDC): `0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84` (wraps native USDC `0x8335…2913`, 6 dec)
- `quoteAsset` (wrapped cNGN): `0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493` (wraps cNGN `0x46C8…EF5F`, 6 dec)
- `spotFeed` (cNGN): `0x41512C6a2af5AcD219EbCcfaF34f7088A2999ABC`
- Series subId: `1789567201` — last trade 2026-09-16 14:00:00 UTC, delivery 14:00:01 UTC
- Margin: 20% IM / 15% MM (5x max leverage); 3-day lifecycle ramp to full collateral

### USDC/cNGN SPOT on the SRM

**EXECUTED.** All 11 actions landed; verified against chain 2026-09-09 by
`scripts/ops/refresh_deployment_artifacts.py` and the assertions in
`test/fork/SRMMarket1InertFork.t.sol`. See
[docs/cngn-spot-srm-migration.md](docs/cngn-spot-srm-migration.md).

Spot moved off `DeliverableFXManager` (which credits cNGN at 100% of oracle value) onto the SRM as
a base-only market at `marginFactor = 0`, where the margin check reduces to `cash >= 0`.

Feeds deployed 2026-08-24 (block 50405256); wrapped cNGN whitelisted to market 2 at block 51064276.
The state this produced is in the generated **Live SRM state** section above.

`DeliverableFXManager` is **deprecated** — do not send it new actions.

- `manager`: the shared `srm` above, `0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b`
- `baseAsset` (wrapped cNGN): `0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493` — **unchanged**, shared with the deliverable stack
- `spotFeed` (LyraStaticSpotFeed): `0xec4ad7B2679f54eB3e971B10120cB56cF1c061A4` — `0.000743376685636834` USDC per cNGN, confidence `1e18`
- `stableFeed` (LyraStaticSpotFeed): `0x507D645682737C6640dc73b5aC858654BcB9854f` — `1e18`, confidence `1e18`
- Market id: **2** (`createMarket` is action 4; `lastMarketId` was 1)
- Cap: `204853778399937200000000000` — 10% of live cNGN supply at generation. Gates deposits, not trading. **Alert at 80%**: `163883022719949760000000000`
- Batch hash: `0x911288c57e4ea05fe01f257f928bd80b5e00fa4cd3bd9ff4129b96a43bb1b67f` — the value
  pinned in `scripts/ops/propose_cngn_spot_batch.py`, which re-derived the batch from live chain
  state before each proposal. An earlier hash recorded here predated that regeneration.

Both feeds were deployed by `0xdA1976E83D54B76D0c794B35262228960a1a918f` — the **feed signer key**, which
is a live operational hot key rather than a throwaway deployer. It is `pendingOwner` → vault on both
feeds. Actions 0 and 1 landed, so `owner()` on both feeds is now the vault and the signer key no
longer holds `setSpot` rights. Re-read both `getSpot()` values before relying on them rather than
trusting the deployment log.

#### COUPLED SETTINGS — do not change one alone

The static feed prices are inert **only because** margin is zero. Make margin non-zero and the venue
credits cNGN against a rate frozen at deploy time. These five move together:

1. `srm.baseMarginParams(cngnMarketId).marginFactor == 0`
2. `srm.borrowingEnabled == false`
3. market spot feed is the **static, inverted** feed (USDC-per-cNGN — the SRM's Base convention is
   USD-per-base; the DFXM feed at `0x41512C…` is cNGN-per-USDC and is **the wrong orientation here**)
4. `srm.stableFeed` is the **static** feed
5. `srm.oracleContingencyParams(cngnMarketId)` all zero

Raising `marginFactor` requires replacing **both** feeds with live, correctly-oriented ones first.
Settings 2 and 4 are **global to the SRM**, not per-market.

### Market 1 (wrapped USDC) — EXECUTED 2026-09-09

Artifact: [deployments/8453/MARKET1_INERT_VAULT_ACTIONS.json](deployments/8453/MARKET1_INERT_VAULT_ACTIONS.json)

Market 1 was moved off the live `LyraSpotFeed` `0xDAe566adc61086535986AfBd80093B1DD8686797`
(3600s heartbeat) at `marginFactor 0.98e18` onto the shared static `1e18` feed at `marginFactor 0`.
Current values are in the generated **Live SRM state** section above, not repeated here.

Two actions, sent from the vault strictly in this order by
`scripts/ops/propose_market1_inert_batch.py`:

1. `srm.setOraclesForMarket(1, 0x507D6456…, 0, 0)` — block 51097293, tx
   `0x21a7c7453de94bc6e928ee8cf6c13a31fad2608115dd2b074506b99b5c6c48e6`. There is no
   `setSpotFeed`; this setter writes all three feeds, and market 1's forward/vol were already zero.
2. `srm.setBaseAssetMarginFactor(1, 0, 0)` — block 51097344, tx
   `0x1a6a52f66366ee9bd6f27afe2c550bcd907ab1640d59f03202758dea2775454e`.

Order was a correctness requirement. After action 1 alone the market sits on a static feed at the
old `0.98` factor — strictly safer than the starting state. Reversed, the factor would be zeroed
while the market was still coupled to a feed that can go stale.

Why the repoint was needed at all: `_getMarketMargin` reads the spot price **unconditionally**,
before any margin branch, and passes it *into* `_getBaseMarginAndMtM`. Zeroing `marginFactor` alone
changes the margin number, not the feed access. Proven on a fork in
`test/fork/SRMMarket1InertFork.t.sol`, whose pre-batch assertions are pinned to block 51097292.

Nothing needed market 1 at 0.98. Only two assets have ever been whitelisted on this SRM — wrapped
USDC (market 1) and wrapped cNGN (market 2), both `AssetType.Base`. With `borrowingEnabled == false`
blocking negative cash and `WrappedERC20Asset` unable to go negative, every term of
`netMargin = cash + baseMargin(1) + baseMargin(2)` is non-negative, so base collateral value has no
load to carry at any reachable account state.

**A deposit bypasses the risk check entirely.** `handleAdjustment` leaves `riskAdding` false when no
delta is negative, so `_assessRisk` — and every feed read — is skipped. Funds go *in* fine while the
book is halted; only balance-reducing paths (trades, withdrawals) surface a stale feed. That is why
the six-day feed outage was invisible.

## Base — ABANDONED deployment (pre-2026-07)

The original deployment (owner `0xc7Be60b228B997C23094dDFdD71e22e2De6c9310`) is
**abandoned**: the owner key is lost, the contracts cannot be administered, and the
listed series have expired. Do not integrate against these addresses. This includes
the NGN/BTC perps and the APR-30-2026 future previously listed here (manager
`0x0777C37C3925666474C77f5907E3805177705543`, future `0x7528…E679`, and related feeds).

Also abandoned (2026-07-17, VM denomination bug — accrued VM in cNGN but credited
it 1:1 as USDC): the first SEP-16-2026 stack — manager `0x66E3D42cE93DEb0675F56216f15c6592298B2E28`,
viewer `0x6bdD52484cd2d26eDA0bf1357B74Acda8C37AA81`, future `0x9725e4b6ae24d8Bd76F3AcfDa6E90fC9284e82ef`.
Vault-owned but disused; never held positions.
