# perp-keeper

Liquidation keeper for one manager's accounts: `MANAGER` is the perp SRM (`numo-perp-keeper`, which still
reads it as `SRM`) or the MarginEngine (`numo-engine-keeper`, the cNGN future's accounts). Nothing else is
manager-specific: DutchAuction settles an account through its manager before an auction starts and before
every bid (`settlePerpsWithIndex`, which on the engine also realises every future's VM), and reads its margin
through the manager. The engine's VM pool (`POOL_ACCOUNT`) is never a candidate. Every 15 seconds it:

1. **Finds every account** under `MANAGER` from `AccountCreated` / `AccountManagerChanged` logs, up to
   `SCAN_CONFIRMATIONS` (3) blocks behind the head: a load-balanced RPC's lagging node returns no logs, not
   an error, for blocks it has not imported, and a scan up to the head would skip them for good.
2. **Reads each one's margin and auction** through DutchAuction, and decides (`src/decide.ts`):
   - below maintenance margin, no auction → `startAuction`
   - recovered → `terminateAuction`
   - solvent auction run out while still under water → `convertToInsolventAuction`
   - solvent auction at a ≥ 2% discount to mark → **bid**, sized to the auction's max proportion and
     to what the keeper's cash can back
   - insolvent auction → **bid** once the security module's payout covers the account's deficit plus
     the same 2%; the payout starts at the deficit and grows toward maintenance margin, so an early
     bid would carry the position with nothing for the risk
3. **Checks the stack** (`src/health.ts`) and alerts on: a socialized loss (cash exchange rate < 1),
   the withdraw fee switching on, a security module that cannot cover live insolvent auctions, low
   security-module or keeper cash, low keeper gas, inventory the keeper has inherited, a keeper
   account below maintenance margin, and open interest at 80% of the cap.

Every transaction is simulated first, and sent with 50% gas headroom: auction calls settle interest
and funding against the block timestamp, so an estimate from one block can fall short in the next. After
any transaction of its own, every read, simulation and estimate is made at an explicit block no older than
the one it landed in (`src/pinned-read.ts`): a lagging node answers a call at `latest` with the state
before it (a bid simulated against a bid account whose funding it has not seen, the next bid sized from
cash already spent).

## Bid accounts

DutchAuction only takes a bid from an account holding nothing but cash (`DA_InvalidBidderPortfolio`).
So `KEEPER_ACCOUNT` is a **funding** account that only ever holds cash, and each live bid goes from a
fresh subaccount the keeper creates, funds with exactly that bid's requirement (+2%), and bids from.
Inherited positions stay in those bid accounts. The keeper does **not** close or hedge them — it
alerts (`keeper-inventory`), and an operator or the market maker takes them from there.

## cNGN collateral

Once cNGN is margin on the perp (risk-core `CNGN_PERP_COLLATERAL.json`), set `CNGN_ESCROW` to that
escrow. The keeper then reads each account's cNGN. An insolvent bid waits until the payout covers the
deficit plus `CNGN_HAIRCUT_BPS` (default 10%) of the cNGN's index value; a solvent bid is judged
at the index like any other, and the cNGN is carried as inventory (netting the haircut there would
leave an account whose equity is under it unbiddable for the whole 12-hour solvent phase, position
open — the local drill found exactly that). The SRM
credits cNGN at 50%, but the auction's end price is the maintenance-margin deficit, which on cNGN
carries that same haircut — a keeper waiting for the SRM's valuation would let every cNGN auction
run to its most expensive second. `MAX_CNGN_INVENTORY` (whole cNGN) bounds what the keeper will hold
across its accounts: a bid that would pass it is sized down to the room left, then stops
(`keeper-cngn-over-limit`). Inherited cNGN is alerted (`keeper-cngn-inventory`) and left for an
operator to sell on spot or hold, like inherited perp.

## EURC collateral (MarginEngine market 2)

Collateral is a list: each asset has its own escrow, price source, haircut and inventory limit. An
auction bid takes a share of *every* asset in the account, so once EURC is margin on the engine the
keeper is paid in EURC by any account that holds it. Set `EURC_ESCROW` and `EURC_SPOT_FEED` from
risk-core `deployments/8453/EURC_SPOT.json` (`escrow`, `spotFeed`) — both or neither; the keeper refuses
to start with one, or with `MAX_EURC_INVENTORY` and no escrow. EURC is priced at the feed's `getSpot()`
(18dp USD per EURC, Chainlink EURC/USD), haircut `EURC_HAIRCUT_BPS` (default 2%), limited by
`MAX_EURC_INVENTORY` (whole EURC; unset is no limit).

An insolvent bid waits for the deficit plus the margin plus the **sum** of every held asset's haircut;
a bid is sized to the **tightest** inventory limit among the assets the account holds, and the note
names the asset that bound. Inventory is alerted per asset (`keeper-eurc-inventory`,
`keeper-eurc-over-limit`, alongside the cNGN keys). The feed is read only for accounts holding EURC.
When it reverts (stale, `CLF_DataTooOld`), the engine's margin read for those accounts reverts too:
the keeper does nothing to them that pass — no start, no bid — notes `cannot price EURC`, and alerts
`collateral-unpriced-EURC`; every other account is handled as usual. The startup log lists the
configured collateral, and `/health` reports `eurcEscrow`, `eurcSpotFeed`, `eurcHaircutBps` and
`maxEurcInventory`.

A solvent auction sells only what restores the account's margin and ends at *buffer* margin.
When an earlier bid has put the account above maintenance margin and a rounding sliver under the
keeper's minimum is all that is left, the keeper takes it if the cash it pays in restores buffer
margin (a live auction freezes the account for its owner); otherwise the sliver waits for the
solvent window to end (12h15m at the venue's parameters), when maintenance margin is enough and
the keeper terminates it.

## Bid size and health

`MAX_BID_USD` caps one bid by the margin it ties up: a solvent bid by its price plus the buffer
margin it inherits, an insolvent one by the maintenance margin it takes on. The keeper bids a smaller
share of the account instead. Unset means no cap. At launch, set it well under `KEEPER_ACCOUNT`'s
cash so one bad auction cannot take the whole book in a single bid.

`HEALTH_PORT` serves `GET /health` on `HEALTH_HOST` (default `127.0.0.1`), which reports the last
pass's time and outcome, whether this is a dry run, and the keeper's account. The perp enable gate
(`propose_perp_enable_batch.py`, via `KEEPER_HEALTH_URL`) refuses to open the market without a
recent passing, non-dry-run keeper.

## Health, alerts and chain

`/health` also lists the last pass's `liquidatableAccounts` and `insolventAccounts`. The pager
(`contracts/risk-core/scripts/ops/check_perp_pager.py`) pages your phone on any insolvent account,
and on the keeper itself being unreachable, in dry run, or stale.

`ALERT_PREFIX` is prepended to every alert. The mainnet-fork rehearsal sets `[REHEARSAL] `.

At startup the keeper asks its RPC for the chain id and refuses to run unless it equals `CHAIN_ID`.
A keeper configured for a fork cannot reach Base, and one configured for Base cannot run against a
fork.

## Dry run by default

`DRY_RUN=true` unless set otherwise: it reads, decides and simulates every action against the chain,
alerts what it would have done, and sends nothing. Watch it through real market conditions before
turning it off.

## Running

Secrets from SSM (`/numo/keeper/keeper_key`); the rest in `/etc/numo/perp-keeper.env`:

Create `KEEPER_ACCOUNT` from the keeper EOA directly on SubAccounts (`createAccount(keeper, srm)`,
then `CashAsset.deposit`). An account opened through the app or SubAccountCreator is held by
Matching, not the keeper, so every funding transfer to a bid account would revert
(`NotEnoughSubIdOrAssetAllowances`). Each pass checks the owner and the manager, and fails the pass
(and so `/health`) if either is wrong. Bid accounts that were created but never bid from are reused,
not abandoned.

```bash
KEEPER_ACCOUNT=<cash-only subaccount under the perp SRM, owned by the keeper EOA>
SUB_ACCOUNTS=0x7019244E25FA416e6Ca2ed2F3cA25277aef72843
SRM=<CNGN_PERP_STACK.json srm>
AUCTION=<auction>
CASH=<cash>
PERP=<perp>
SECURITY_MODULE_ACCOUNT=<securityModuleAccount>
START_BLOCK=<block the stack was deployed at>
DRY_RUN=true
MAX_BID_USD=2500
HEALTH_PORT=9464
```

Fund the keeper EOA with ETH for gas and `KEEPER_ACCOUNT` with the stack's cash (USDC deposited
through `CashAsset.deposit`). Its cash bounds the largest auction it can take in one bid.

## Tests

```bash
pnpm test                               # every decision branch and health alarm
BASE_RPC_URL=... ./scripts/e2e.sh       # the real stack on an anvil fork: deploy, crash, liquidate
BASE_RPC_URL=... ./scripts/e2e-engine.sh  # the live MarginEngine on a fork: an engine account under
                                          # maintenance auctioned and bought into from the engine
```

The fork test is what found three bugs no unit test could: a start that ran out of gas one block after
its estimate, reverts that did not decode, and the bidder-must-be-cash-only rule that stopped the
keeper after its first liquidation.
