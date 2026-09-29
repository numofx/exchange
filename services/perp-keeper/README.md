# perp-keeper

Liquidation keeper for `USDCcNGN-PERP`. Every 15 seconds it:

1. **Finds every account** under the perp SRM from `AccountCreated` / `AccountManagerChanged` logs.
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
and funding against the block timestamp, so an estimate from one block can fall short in the next.

## Bid accounts

DutchAuction only takes a bid from an account holding nothing but cash (`DA_InvalidBidderPortfolio`).
So `KEEPER_ACCOUNT` is a **funding** account that only ever holds cash, and each live bid goes from a
fresh subaccount the keeper creates, funds with exactly that bid's requirement (+2%), and bids from.
Inherited positions stay in those bid accounts. The keeper does **not** close or hedge them — it
alerts (`keeper-inventory`), and an operator or the market maker takes them from there.

## Dry run by default

`DRY_RUN=true` unless set otherwise: it reads, decides and simulates every action against the chain,
alerts what it would have done, and sends nothing. Watch it through real market conditions before
turning it off.

## Running

Secrets from SSM (`/numo/keeper/keeper_key`); the rest in `/etc/numo/perp-keeper.env`:

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
```

Fund the keeper EOA with ETH for gas and `KEEPER_ACCOUNT` with the stack's cash (USDC deposited
through `CashAsset.deposit`). Its cash bounds the largest auction it can take in one bid.

## Tests

```bash
pnpm test                               # every decision branch and health alarm
BASE_RPC_URL=... ./scripts/e2e.sh       # the real stack on an anvil fork: deploy, crash, liquidate
```

The fork test is what found three bugs no unit test could: a start that ran out of gas one block after
its estimate, reverts that did not decode, and the bidder-must-be-cash-only rule that stopped the
keeper after its first liquidation.
