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

The v1 sizing (`docs/cngn-future-security-module.md` on `risk/futures-sm-step-10pct`) rests on the inverse payoff and a
fixed-USD maintenance margin. Both go:

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
- **Caps.** 30 contracts over both sides is ~$22k at 0.000743, against v1's $30k. Re-size against the SecurityModule
  with the linear formula before the enable batch opens it.

## Migration

There is no `changeManager` in SubAccounts. Holders move by opening a v2 account and withdrawing and re-depositing.
`test/fork/MarginEngineV2DeployFork.t.sol` proves a v1 account and a v2 account trade spot cNGN against USDC directly,
each held to its own engine, so `cNGN-USDC` and `EURC-USDC` keep one book through the move.

Order:

1. Deploy v2 (`scripts/deploy-margin-engine-v2.s.sol`): closed, nothing reused wired.
2. `MARGIN_ENGINE_V2_VAULT_ACTIONS`: accept, wire the cash, every escrow at v1's cap, and the auction; v1's guardian.
3. `MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS`: open the future and register it on the TradeModule.
4. markets-service lists `cNGN-31DEC26`; new spot deposits default to v2 accounts.
5. v1 close-only: caps **at** live open interest, never below (a cap below OI freezes holders).
6. 30NOV26 fixes and closes out on v1; holders withdraw and re-deposit under v2.
