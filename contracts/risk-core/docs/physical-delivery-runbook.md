# Physical delivery — SEP-16-2026 cNGN future: flow map + runbook

How the `USDCcNGN-SEP16-2026` deliverable FX future settles by **physical delivery** at expiry, what
must be true on-chain for it to work, the current gaps, and the operational checklist for Sep 16.
Status: **mapped, NOT yet exercised** on the Base deployment. Everything below is derived from
`DeliverableFXFutureAsset.sol` + `DeliverableFXManager.sol` and on-chain reads (2026-07-22).

## Key addresses / params (Base 8453)
- future asset `0xDd9c2Ddf97a2Dc9B9d348DcD0ef776aF5291A1F9`, subId **1789567201** (= expiry ts)
- manager `0xcE01f3D74400caE39bd7608cd2d286C2e3874d49`, owner = MPC vault `0x1dcA42ab54…` (same key as setMarkPrice)
- baseAsset (deliverable USDC) `0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84`
- quoteAsset (deliverable cNGN) `0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493`
- **manager delivery-counterparty subaccount `accId` = 4** ← the "cNGN float" account
- `contractSizeBase = 1e22`; delivery per position: `baseAmount = |pos|·contractSizeBase/1e18`,
  `quoteAmount = baseAmount·settlementPrice/1e18`. (0.002 contracts ⇒ ~20 USDC ⇄ ~27,543 cNGN.)

## Timeline (all on-chain-enforced)
1. **Trading** (now → **Sep 16 14:00:00 UTC** = `lastTradeTime`): cash-margined. VM accrues to/from USDC
   cash each mark/trade. Mark keeper pushes `setMarkPrice` (now automated on the amd64 box).
2. **Freeze** (at `lastTradeTime`): `handleAdjustment` reverts for any non-manager amount change
   (`DFXF_TradingClosed`) and `isTradingOpen` → false. Positions can no longer be traded out. From here
   the manager requires each account to **hold + reserve** the asset it will deliver (the "collateral
   ramp" is enforced here — there is no separate ramp timestamp; Sep 13 is an *operational* funding deadline).
3. **Fixing** (owner action, at/after freeze, before delivery): MPC vault calls
   `setSettlementPrice(subId, settlementPrice)`. Must be within `maxMarkDeviation` of the last mark
   (keep the mark tracking spot into the close so the fixing passes). Accrues the final VM leg; sets
   `settlementPriceSet=true`. One-shot (reverts if already set).
4. **Delivery** (at/after **Sep 16 14:00:01 UTC** = `expiry`): for each account with a position, anyone calls
   `settleDeliverableFuture(future, accountId, subId)` (or `settleAllExpiredDeliverableFutures(accountId)`).
   It: settles final VM → checks the account holds+reserved the owed asset AND `accId=4` holds the paid-out
   asset → zeroes the position → swaps tokens vs account 4 → marks `accountSettled`.

## Who delivers what
- **LONG** (position > 0): pays `quoteAmount` **cNGN** to acct 4, receives `baseAmount` **USDC** from acct 4.
  → a long must **hold cNGN** in its subaccount to deliver.
- **SHORT** (position < 0): pays `baseAmount` **USDC** to acct 4, receives `quoteAmount` **cNGN** from acct 4.
  → a short must **hold USDC** to deliver.
- **Account 4 (manager float)** is the counterparty for every settlement; it must hold enough **USDC** (to pay
  longs) and **cNGN** (to pay shorts) to cover the net. `settleDeliverableFuture` reverts
  (`SRM_PortfolioBelowMargin`) if either the account or acct 4 is short the required token.

## Readiness rule (per account, in the delivery phase)
`isDeliveryReady(accountId)` / `getDeliveryReadiness` is true only when, for BOTH assets:
`subaccount balance ≥ required` AND `reservedBalance ≥ required`. `refreshDeliverableReservation(future,
accountId, subId)` recomputes the reservation (longs reserve cNGN = quoteAmount, shorts reserve USDC = baseAmount).

## Current on-chain state (2026-07-22) — the gaps
- **Mark:** fresh (1377.17, keeper live). settlementPrice not set (correct, pre-expiry). ✅
- **Open interest:** totalLong 0.002 / totalShort 0.002 = just the **leftover fill-test positions**
  (MM acct 9 +0.002 long, acct 8 −0.002 short).
- **Account 4 float: 0 USDC, 0 cNGN — NOT funded.** ❌ Delivery of ANY position would revert until acct 4 holds
  the payout tokens.
- **The current positions cannot physically deliver:** the long (MM) holds 0 cNGN but a 0.002 long owes ~27,543
  cNGN; acct 8 holds ~6 USDC but a 0.002 short owes ~20 USDC. Both are short the deliverable.
- **The market maker is cash-only** — it holds USDC, never cNGN. A net-LONG MM at expiry **cannot deliver**
  (needs cNGN). ⇒ **the MM MUST be flat by `lastTradeTime`**, or be liquidated in the delivery phase.
- **No delivery keeper exists.** `setSettlementPrice` and `settleDeliverableFuture` are manual/one-off; nothing
  automates them. Needs a small keeper/runbook for Sep 16.
- **Never exercised** on this deployment (smoke test + fill test proved cash-margined trading + VM only).

## Pre-Sep-16 checklist (build + operate)
1. **Flatten the leftover test positions** now (MM +0.002, acct 8 −0.002) — they can't deliver and clutter OI.
2. **MM policy:** ensure the MM is flat by the freeze — either auto-flatten near `lastTradeTime`, or accept it
   holds only shorts it can cover with USDC. Simplest: pull MM quotes / flatten before Sep 16 14:00.
3. **Fund account 4** with USDC + cNGN sized to the net delivery obligation (depends on final OI + which side
   is net long/short). This is the "cNGN float into account 4."
4. **Participant comms / collateral ramp (by Sep 13):** anyone intending to hold to delivery must top up the
   deliverable asset (longs: cNGN, shorts: USDC) and reserve it (`refreshDeliverableReservation`), else their
   position can't settle and is liquidation-eligible.
5. **Settlement-price source:** decide the Sep-16 fixing (spot at 14:00) and confirm it's within
   `maxMarkDeviation` of the last mark. Keep the mark keeper running into the close.
6. **Build a delivery keeper/runbook:** at freeze → `setSettlementPrice` (MPC-vault-signed, like the mark
   keeper); at expiry → loop `settleAllExpiredDeliverableFutures` / `settleDeliverableFuture` over every account
   with a position. Verify `previewSettlement`/`isDeliveryReady` per account first.
7. **DRY-RUN the whole thing on a short-dated test series** well before September (create a series expiring in
   minutes, trade a small pos, fund acct 4, setSettlementPrice, settle) — this is the single highest-value
   de-risking step, since delivery is entirely untested.
