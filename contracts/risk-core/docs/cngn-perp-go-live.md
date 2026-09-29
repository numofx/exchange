# USDCcNGN-PERP go-live

The order to launch the perp in, the rules each step has to meet, and the two operator procedures
the running market needs: pausing, and reopening after a real index step. Every step here can be
rehearsed first on `scripts/local-venue/up.sh`, and the index step on `step-drill.sh`.

Nothing in this runbook broadcasts or signs by itself. Deploys run from the deployer key. Vault
actions go through MPCVault, and a human approves each one.

## Order

1. **Deploy the stack.** Run `deploy-cngn-perp-stack.s.sol` with `FEED_SIGNER` (the revived cNGN
   signer), `PERP_GUARDIAN` (the hot ops key, see [Pausing](#pausing)) and, optionally,
   `PERP_OI_CAP`. The stack deploys **closed**, with its position cap at 0.
2. **Deploy the TradeModule.** Run `deploy-cngn-perp-trade-module.s.sol`. The module is not
   allowlisted.
3. **Vault: stack batch.** Sign `CNGN_PERP_STACK_VAULT_ACTIONS.json`:
   - `acceptOwnership` on each of the 11 contracts;
   - then `srm.setGuardian(PERP_GUARDIAN)`.
4. **Vault: module batch.** Sign `CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json`, which is
   `acceptOwnership` only. The market is still closed on both switches.
5. **Feeds.** Fund the relayer, then start `perp-feeds`.
   - First, on the host it will run on, run `node dist/main.js --probe-sources`. It must report at
     least 3 of the sources answering. If it doesn't, the index refuses every sample.
6. **Keeper.**
   - Create `KEEPER_ACCOUNT` **from the keeper EOA directly on SubAccounts** (`createAccount`, then
     `CashAsset.deposit`). Do not use the app or SubAccountCreator: that parks the account in
     Matching, where the keeper cannot move its cash, and every bid fails. The keeper and the enable
     gate both refuse such an account.
   - Set `MAX_BID_USD` and `HEALTH_PORT`.
   - Run it in `DRY_RUN` first, then live.
7. **Seed the SecurityModule** to at least the rule [below](#securitymodule-seed).
8. **Quoter.** Get a two-sided quote of at least $1k within 2% of the index. The market maker's perp
   mode does this.
9. **Vault: enable.** Run `scripts/ops/propose_perp_enable_batch.py --propose`. It proposes
   `perp.setTotalPositionCap(srm, launchOICap)` and then `matching.setAllowedModule(module, true)`,
   one action at a time, only while every gate passes:

   | Gate | What must hold |
   | --- | --- |
   | custody | The vault owns every contract. The SRM has a guardian that is not the vault. The market is still closed. |
   | feeds | The index and all three diff feeds are 10 minutes old or less. |
   | keeper | Its last pass succeeded recently and it is not in dry run. The keeper EOA owns its funding account, which is under the perp SRM, holds only cash and has enough of it. It has gas. |
   | sm | The SecurityModule holds at least the seed rule. |
   | quoter | The book is two-sided, with at least $1k within 2% of the index on each side. |

## SecurityModule seed

**The SecurityModule must hold at least a third of ONE side's notional at the current cap:**

```text
seed >= (cap / 2 NGN) × index (USD per NGN) / 3
```

The cap counts `|position|` over both sides, so one side is half of it. At the 50M NGN launch cap
and 1374 NGN/USD, one side is $18,195, so the seed is at least **$6,065**. The enable gate computes
this from the live index and refuses below it; `--min-sm-cash` (default $5k) is only a floor under
it.

**Raising the cap is a new launch** for this rule: top the SecurityModule up to a third of the new
side first.

Why a third: it is the initial margin on that side. In
`CngnPerpStackFork.testSecurityModuleLossFromIndexJumpAtFullCap`, the whole long side sits in one
account just above maintenance margin and the insolvent auction runs to its most expensive second.
The SecurityModule's payout there reaches this size at an index jump of about 50%:

| Index jump | SecurityModule pays (at 50M NGN) |
| --- | --- |
| 10% or 20% | $0 |
| 25% | $2,995 |
| 30% | $3,596 |
| 40% | $4,796 |
| 50% | $5,997 |

In the local drill of a 40% step at the full cap, the NGN long was at 3x and a live keeper bid as
soon as the payout covered the deficit plus 2%. The SecurityModule paid $1,018 and nothing
socialized. The table is the ceiling; a live keeper keeps the payout well under it.

## Pausing

`PERP_GUARDIAN` is a hot key and the only thing that can stop the book without signers.
`srm.setAdjustmentsPaused(bool)` is guardian-only **in both directions**:
- the guardian can pause and unpause;
- the vault (owner) can do neither, unless it first makes itself guardian with `setGuardian`.

A pause reverts every adjustment on accounts under the perp SRM:
- trades, and perp transfers between accounts;
- deposits and withdrawals;
- **liquidation bids**. An auction can still be started, but no bid lands.

A pause therefore freezes the book; it does not close it out. An underwater account stays open and
its deficit can grow until the pause is lifted. Pause for a broken feed or contract, not for
volatility, and unpause as soon as the cause is fixed. `CngnPerpStackFork` pins both behaviours.

Rotate or remove the key with a vault `srm.setGuardian`.

## Reopening after an index step

The index publisher refuses any move over 300 bps from the on-chain index. A real devaluation trips
that guard, publishing stops, and after the 20-minute heartbeat the market halts: trading and
liquidations alike. To reopen at the new level:

1. **Confirm the level** from outside the publisher: the sources, the news, and at least one person
   other than the operator.
2. **Check the keeper is live and funded**, from its `/health` and the funding account's cash. A
   step liquidates accounts, and a step without a working keeper leaves them open. Top the
   SecurityModule up to the seed rule at the **new** index if the step moved it.
3. **Stop the publisher.** The step shares its state file.
4. **Run the step once**, on the publisher's host and with its env:

   ```bash
   node dist/main.js --accept-index-step --level=<NGN per USD> \
     --approved-by=<name> --reason="<what happened, and who confirmed it>"
   ```

   It samples the sources once, then publishes only if all of these hold:
   - the keeper's `/health` passes (`KEEPER_HEALTH_URL`);
   - the sources' own window TWAP, with every sample guard applied, is within
     `INDEX_STEP_MATCH_BPS` (100) of the confirmed level;
   - the move is larger than the 300 bps guard and no larger than `INDEX_STEP_MAX_BPS` (5,000).

   What it publishes is the sources' TWAP, not the typed number. It appends the approval to
   `INDEX_STEP_AUDIT_FILE` (approver, reason, levels, keeper state) before sending, then appends the
   transaction, and sends an `index-step` alert. It refuses on anything else, and exits non-zero.
5. **Start the publisher.** From the new index it runs under every normal guard again, and the mark
   and impacts re-anchor to it on their next tick.
6. **Watch the keeper** take the underwater accounts. Its inherited positions raise
   `keeper-inventory` alerts, for the operator or the market maker to work off.

There is no environment-variable override any more. `INDEX_ACCEPT_JUMP` was removed: it had no
approver, no audit record and no keeper check.

## Index sources

The index needs 3 agreeing sources. As of 2026-09-29, from a developer machine:
- Quidax and Textile answer.
- Bybit P2P times out, which looks like a regional block.
- Blockradar is not configured (`BLOCKRADAR_API_KEY` unset).

Before step 5, either set `BLOCKRADAR_API_KEY` or confirm with `--probe-sources` that Bybit answers
from the ops host.
