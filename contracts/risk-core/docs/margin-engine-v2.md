# MarginEngine v2: the cNGN future in American terms

Decided 2026-10-21: FX pairs quote in American terms, USDC per foreign unit. Spot already does (`cNGN-USDC`,
`EURC-USDC`). The future did not: v1's `USDC-cNGN-<expiry>` is cNGN per USDC on chain, with a USDC contract and VM in
cNGN, and the v1 engine (0xA19E…0758) and its linked FutureVMLib are immutable and built around exactly that. So v2 is
a new engine, and the first v2 series lists as `cNGN-<expiry>` at the 30NOV26 roll. v1 runs its series out unchanged.

## What changes

| | v1 (`src/legacy/v1`, deployed) | v2 (`src/`) |
|---|---|---|
| symbol | `USDC-cNGN-30NOV26` | `cNGN-31DEC26` |
| price | cNGN per USDC (`1e36 / feed`) | USDC per cNGN (the feed as is) |
| contract | 1,000 USDC | 1,000,000 cNGN (~743 USDC at 0.000743) |
| long gains when | cNGN weakens | cNGN strengthens |
| VM | cNGN, paid as base first through pool 31, USDC shortfall at spot | USDC cash through the pool, nothing converted |
| VM in the price | inverse | linear: Δmark × size |
| notional for margin | fixed 1,000 USDC | \|pos\| × size × mark, moves with the price |
| pending VM in margin | gain at the base factor, loss from held base | at par, as a perp's unrealised PnL |
| close-out | converts at the settlement price | reads no feed, converts nothing |
| forward feed | published USDC per cNGN, inverted by `pullMark` | read as is; the diff is negative (cNGN at a forward discount) |
| fair forward at deploy | index × (1 + carry τ) | index / (1 + carry τ) |
| markets | NGN (spot, perp, future), EUR | NGN (spot, future), EUR; no perp |

Unchanged: every external signature the ops scripts call (`settleAccountVM`, `getPendingVM`, `pullMark`,
`recordFixingSample`, `fixSettlementFromIndex`, `closeOutExpired`, `settleAccount`, …), the mark bounds, the index band
(10% narrowing to 1% over 14 days), the fixing (1h window, 15m gap, 24h fallback within 2%), IM 25% / MM 15%.

## SecurityModule sizing: what moves

The v1 sizing ([`cngn-future-security-module.md`](cngn-future-security-module.md), from #245) rests on the inverse payoff
and a fixed-USD maintenance margin. Both go:

- **Loss on a step.** v1's `notional × premium × ln(1/(1−s))` came from inverse VM. v2's VM is linear, so a step `s`
  against a side costs `notional × s`.
- **The cliff.** v1's MM was a fixed number of dollars a contract, giving a cliff at `1 − exp(−MM/premium)` = 13.8%.
  v2's MM is a share of a notional that moves with the price. An account opened at exactly IM falls below MM at
  `s = (IM − MM) / (1 + MM)` = 8.7% for a short (cNGN rallies) and `(IM − MM) / (1 − MM)` = 11.8% for a long
  (cNGN falls), and is bankrupt at `s = IM` = 25% either way. The 15% step the v1 doc sizes to therefore liquidates
  without bankrupting an IM-margined account; the SecurityModule covers accounts that were already under IM.
- **Unsettled VM no longer flatters an account.** It is cash at par, not cNGN whose USD value moves.
- **The pool's cNGN reserve is gone.** The pool only ever holds cash, fronts winners and is repaid by losers; the
  pager's reserve check and `withdrawFromPool` rebalancing are v1-only.
- **Caps.** 30 contracts over both sides is ~$22k at 0.000743, against v1's $30k. Sized below.

### Cap against an overnight devaluation gap

Inputs, read 2026-10-21 at Base block 52,912,673: SecurityModule capacity **$3,250** (account 21's USDC cash; #245
changes the sizing formula, not the capacity, so the same figure holds on `main` and on #245). One contract is
1,000,000 cNGN × 0.000743 = **$743**. Every capped contract is taken to be a long opened at exactly IM (25%), which a
devaluation gap bankrupts at 25%; conservative, since a cap counts both sides and so admits at most half as many longs.

| Gap | Bad debt per contract, $743 × (gap − 25%) | Max cap | If the module pays the whole step, $743 × gap | Max cap |
|---|---|---|---|---|
| 30% | $37.15 | **87** | $222.90 | 14 |
| 40% | $111.45 | **29** | $297.20 | 10 |
| 50% | $185.75 | **17** | $371.50 | 8 |

**40 contracts does not pass at 40%:** $4,458 of bad debt against $3,250, short by $1,208. 29 is the most that does.

The right-hand columns are an upper bound, not the sizing rule. #245's fork run on v1 found that an insolvent auction
ends at the account's maintenance margin, so the module paid close to the step's whole loss once a side was insolvent,
not just the part past bankruptcy. Whether v2's linear payoff does the same is unmeasured: #245's
`testSecurityModuleCoverageAgainstTheFork`, run against v2, settles which column the cap should come from.

What `propose_margin_engine_v2_batch.py` enforces at `enable` and `cap`, re-read at the cap being opened and today's mark:

- **`sm`** (refuses): the SecurityModule covers the whole of a 15% step (`SM_MOVE`, the pager's) on one side,
  `check_perp_pager.sm_required_usd_linear`. v1's rule pays nothing until a side at MM is insolvent; a linear side at
  MM 15% is insolvent at exactly 15%, so that rule would read nothing at all and the whole step is the safe reading
  until the fork measures v2. $3,250 covers 58 contracts at 0.000743.
- **`gaps`** (informational, never refuses): this table at today's mark and cash, naming each gap the cap is not
  covered at. The cap itself is a decision; the deploy default of 30 is not covered at a 40% gap at 0.000743.

## Migration

There is no `changeManager` in SubAccounts. Holders move by opening a v2 account and withdrawing and re-depositing.
`test/fork/MarginEngineV2DeployFork.t.sol` proves a v1 account and a v2 account trade spot cNGN against USDC directly,
each held to its own engine, so `cNGN-USDC` and `EURC-USDC` keep one book through the move.

Order (`scripts/ops/propose_margin_engine_v2_batch.py` proposes every vault step; each is gated and re-read):

1. Deploy v2 (`scripts/deploy-margin-engine-v2.s.sol`): closed, nothing reused wired. **Not before EURC-USDC is listed
   on v1** (`DEPLOYED_ADDRESSES.md`, EURC steps 1–2): v2 copies only the markets v1 lists, so a v2 deployed first has no
   EUR market, and the EURC batch is written for v1.
2. `setup` (`MARGIN_ENGINE_V2_VAULT_ACTIONS`): accept, wire the cash, every escrow at v1's cap, and the auction; v1's
   guardian. Re-reads parity once the vault owns everything.
3. `enable` (`MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS`): open the future and register it on the TradeModule. Refused until
   v2 has its own forward keeper, liquidation keeper and pager watch (#258) and markets-service lists `cNGN-31DEC26`
   with the chain's band in USDC per cNGN (#228).
4. markets-service: new spot deposits default to v2 accounts (no listing's `margin_manager_address` is v1), and v1's
   future is listed close-only (`future.close_only`).
5. `v1-close-only`: every cap v1 holds (each escrow, the future) set **at** live open interest, never a raise. Refused
   until 3 and 4 hold. A cap that lands under open interest, because it rose between the read and the approval, is the
   same close-only and not a freeze: the deployed viewer checks only the assets a transfer touched.
   `test/fork/MarginEngineV1CloseOnlyFork.t.sol` proves holders still close, settle VM, withdraw and sell cNGN to v2,
   that nothing opens, and that under the SRM's cap check the same cap freezes them.
6. 30NOV26 fixes and closes out on v1; holders withdraw and re-deposit under v2.
