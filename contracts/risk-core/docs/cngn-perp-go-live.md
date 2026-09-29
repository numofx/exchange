# USDCcNGN-PERP go-live

The order to launch the perp in, with every human action and amount; the rules each step has to
meet; and the operator procedures the running market needs: the guardian, the cap, reopening after
a real index step, and settling one that is too large to reopen. Every step here can be
rehearsed first on `scripts/local-venue/up.sh`, and the index step on `step-drill.sh`.

Nothing in this runbook broadcasts or signs by itself. Deploys run from the deployer key. Vault
actions go through MPCVault, and a human approves each one.

## Go-live checklist

Every human action, in order, with amounts. Gas figures are measured on a Base fork and priced at
0.006 gwei (Base, 2026-09-29), with the L1 data fee from Base's GasPriceOracle; the ETH amounts
leave 10-25x for gas spikes. Totals: **0.097 ETH** across five addresses and **$30,500 USDC**
across three accounts.

**Before anything (blocking)**

1. **Index sources.** On the ops host: `node dist/main.js --probe-sources` (perp-feeds). It must
   report at least 3 answering. As of 2026-09-29 only 2 do (Bybit P2P blocked, no Blockradar key):
   set `BLOCKRADAR_API_KEY` or confirm Bybit answers from the host.
2. **Code live.** Merge numofx/exchange#81 and deploy markets-service (api + matcher) and
   execution-service to ECS (the executor's gas headroom ships here). Build perp-feeds and
   perp-keeper on the ops host. Merge numofx/trading-app#103 (its ticket stays closed until
   `trading_enabled`) and numofx/market-maker#26.
3. **Guardian key.** `terraform apply` creates `alias/<name>-perp-guardian`
   (`perp_guardian_kms_enabled`). Read its address with
   `AWS_KMS_KEY_ID=alias/<name>-perp-guardian cast wallet address --aws`. Fund it **0.002 ETH**
   (a pause is ~50k gas).

**Deploy**

4. Fund the deployer **0.005 ETH**. The deploy is 77 transactions, 33.0M gas, ~0.0002 ETH today.
5. Broadcast `deploy-cngn-perp-stack.s.sol` with `FEED_SIGNER=0xdA1976E83D54B76D0c794B35262228960a1a918f`
   and `PERP_GUARDIAN=<the KMS address>`. `PERP_OI_CAP` defaults to 50,000,000 NGN.
6. Broadcast `deploy-cngn-perp-trade-module.s.sol`.
7. Commit the deployment artifacts (`CNGN_PERP_STACK*.json`, `CNGN_PERP_TRADE_MODULE*.json`).

**Vault custody** (MPCVault; the market stays closed)

8. `CNGN_PERP_STACK_VAULT_ACTIONS.json`: 12 actions, `acceptOwnership` on 11 contracts then
   `srm.setGuardian`.
9. `CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json`: 1 action, `acceptOwnership`.

**Services**

10. Set the `cngn_perp_*` Terraform vars from the artifacts, `terraform apply`, and redeploy
    markets-service and execution-service. `/v1/markets` then lists `USDCcNGN-PERP` with
    `trading_enabled: false`.
11. Top up the executor (`0xF68ebcC8…678703`) by **0.02 ETH**. A perp settlement is ~1.6M gas,
    ~0.00001 ETH: about 2,000 settlements.
12. Fund the feed relayer (`0xC9F1…0FDc`) **0.05 ETH** and start perp-feeds live. Measured per
    publish: index 46k gas, mark + impacts 120k gas. That is ~0.0003 ETH a day typical and 0.0013
    worst case (a mark every minute), so 0.05 ETH lasts more than a month at worst.
13. **Keeper.**
    - Fund its EOA **0.02 ETH**. The gate needs 0.005; a full liquidation cycle is ~3M gas.
    - From the keeper EOA, directly on SubAccounts: `createAccount(keeperEOA, perpSRM)`, approve
      USDC to the perp cash, then `CashAsset.deposit(account, 10_000e6)` for **$10,000 USDC**.
      Not through the app or SubAccountCreator: that parks the account in Matching, where the
      keeper cannot move its cash, and every bid fails. The keeper and the gate both refuse it.
    - Set `KEEPER_ACCOUNT`, `MAX_BID_USD=2500` and `HEALTH_PORT=9464`.
    - Run `DRY_RUN=true` for at least a day, then `DRY_RUN=false`.
    - Why $10k: the largest single account at the cap is one full side ($18,195). Taking it needs its
      maintenance margin in the bid account (~$3.6k), and the keeper carries what it inherits until
      it is unwound. In the 40% drill it tied up $2,070.
14. **SecurityModule:** approve USDC to the SecurityModule, then `donate(8_000e6)` for
    **$8,000 USDC**. The rule below needs $6,065 at 1374 NGN/USD. $8,000 still meets it if NGN
    strengthens to 1,042 per USD.
15. **Market maker:**
    - Open its perp account under the perp SRM with **$12,500 USDC**. This goes through the app's
      `/perp` "Deposit margin" or `createAndDepositSubAccount(perpCash, 12_500e6, perpSRM)`, which
      is right for the MM: its orders go through Matching.
    - Run market-maker#26 with `MM_MARKET_SYMBOL=USDCcNGN-PERP`,
      `MM_TRADE_MODULE_ADDRESS=<perp module>`, `MM_SUBACCOUNT_ID`, `MM_PERP_MAX_LEVERAGE=1.5`,
      `MM_PERP_QUOTE_WHILE_CLOSED=true`, `MM_ORDER_SIZE=1000` and `MM_MAX_LONG_INVENTORY=15000` /
      `MM_MAX_SHORT_INVENTORY=-15000`.
    - Confirm it rests at least $1k each side within 2% of the index.
    - Why $12,500: at 1.5x the MM can carry $18,750 gross, one full side at the launch cap.

**Enable** (MPCVault; opens the market)

16. `python3 scripts/ops/propose_perp_enable_batch.py`: every gate must pass. Then run it with
    `--propose`, and approve action 0 (`setTotalPositionCap`) and then action 1
    (`setAllowedModule`), comparing each digest.
17. Within 30s `/v1/markets` reports `trading_enabled: true` and the app's ticket opens. Set
    `MM_PERP_QUOTE_WHILE_CLOSED=false` again.

The gates step 16 checks:

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

## Guardian: exploits only

`PERP_GUARDIAN` is the only key that can stop the book without the vault's signers.
`srm.setAdjustmentsPaused(bool)` is guardian-only **in both directions**:
- the guardian can pause and unpause;
- the vault (owner) can do neither, unless it first makes itself guardian with `setGuardian`.

A pause reverts every adjustment on accounts under the perp SRM:
- trades, and perp transfers between accounts;
- deposits and withdrawals, so no trader can add margin;
- **liquidation bids**. An auction can still be started, but no bid lands.

It freezes the book; it does not close it out. An underwater account stays open, and its deficit can
grow until the pause is lifted. `CngnPerpStackFork` pins all of this.

**Use it only for an exploit in progress:**
- funds moving that no trade or liquidation explains;
- a contract behaving against its tests;
- a compromised feed signer, executor or module.

**Do not use it for:**
- volatility or a real index move. The jump guard halts the index, and reopening is the procedure
  below.
- a feed or keeper outage. The market halts itself when the index goes stale.
- anything the vault can fix without freezing traders' margin.

**Where the key is stored.** It is AWS KMS key `alias/<name>-perp-guardian` (secp256k1, created by
`infra/aws/secrets.tf`, `prevent_destroy`). No service role can sign with it and nothing running
holds it. It is used only from an operator's admin session:

```bash
export AWS_KMS_KEY_ID=alias/<name>-perp-guardian
cast send <perp SRM> "setAdjustmentsPaused(bool)" true  --aws --rpc-url $BASE_RPC_URL   # pause
cast send <perp SRM> "setAdjustmentsPaused(bool)" false --aws --rpc-url $BASE_RPC_URL   # unpause
```

One person may pause. Unpausing needs two: the one who paused and one other, once the cause is
removed. Keep ~0.002 ETH at the key's address. Rotate or remove it with a vault `srm.setGuardian`,
never a terraform destroy.

## Never lower the cap below open interest

When open interest is above the cap, **every account holding the perp is frozen out of deposits and
withdrawals**, including the margin top-up that would save it from liquidation. The cause: an
adjustment that does not touch the perp never snapshots its pre-trade OI, so the cap check reads the
whole OI as an increase (`BasePortfolioViewer._checkAssetCap`).

To stop OI growing, set the cap to the current OI (`perp.totalPosition(srm)`), not below it. At
exactly the current OI nobody is frozen and no new position can open.
`CngnPerpStackFork.testCapBelowOpenInterestFreezesPositionHolders` pins both.

## Index step over 50%: the market stays closed, settled by hand

The step procedure below refuses any step over `INDEX_STEP_MAX_BPS` (50%). A move that large is not
reopened: the perp is settled at the confirmed level and wound down. Mechanically:
`perp.disable()` freezes the mark, and settling an account realises its PnL at that price and
deletes its position.

1. **Keep it closed.** The jump guard has already stopped the index. Stop the market maker.
2. **Vault: `matching.setAllowedModule(perpModule, false)`**, which closes the venue. **Do not cut
   the cap yet**: with positions open it would freeze every holder (previous section).
3. **Decide the settlement level** from the sources and at least one outside confirmation, and
   write it down with two approvers.
4. **Publish it once.** With the publisher stopped, run:

   ```bash
   INDEX_STEP_MAX_BPS=10000 node dist/main.js --accept-index-step --level=<NGN per USD> \
     --approved-by=<name> --reason="settlement: <what happened>"
   ```

   Every other check still applies: the keeper must be live, and the sources must be within
   100 bps of the level. Then **restart the publisher**, because withdrawals and auctions still read
   the index. Wait for the mark to re-anchor on its next tick: `perp.getPerpPrice()` should match
   the index.
5. **Vault: `perp.disable()`**, which freezes the mark at that level. **This is permanent**: this
   PerpAsset never trades again, and a relaunch is a new market.
6. **Settle everyone.** Run `node dist/main.js --settle-frozen` (perp-keeper). It settles every
   account not in an auction and lists the ones that are.
   - Leave the keeper running. It finishes their auctions: a solvent auction that sold what it
     could but cannot terminate resolves when its solvent phase ends, within 12 h 15 min.
   - Run `--settle-frozen` again until it lists nothing.
   - Accounts left below zero go through the insolvent auction, and the SecurityModule pays. What it
     cannot cover socializes through the cash exchange rate.
7. **Only now, vault: `perp.setTotalPositionCap(srm, 0)`.** Nobody holds the perp, so nobody is
   frozen. (`disable()` deletes positions without the perp's hook, so `totalPosition` keeps its old
   value. That does no harm once nobody holds the perp.)
8. Winners withdraw as usual.

Evidence:
- `CngnPerpStackFork.testManualSettlementAfterAStepPastTheBound`: a 60% step at $7.2k notional.
  The loser's $1,820 shortfall was paid by the SecurityModule, nothing socialized, and the winner
  withdrew $14,000.
- The keeper e2e: freeze, sweep, a stuck solvent auction terminated after its solvent phase, then a
  clean sweep.

## Gas headroom

The perp cash accrues interest the first time it is touched in a block, and skips that work if it
was already touched in the same block. A gas estimate taken against the block that last touched it
therefore prices the cheap path. The transaction lands a block later and runs the expensive one: on
a deposit, 122,902 → 181,787 gas (+48%) once anything on the stack is borrowed.

With an exact estimate it reverts out of gas. That was the keeper e2e's CI flake, and it would hit
production senders the same way. Everything that sends into this stack therefore signs
`estimate × 1.5`, and never less than `estimate + 100k`:
- the executor's settlements;
- every keeper transaction;
- the app's deposits.

Unused gas is refunded. The evidence is
`CngnPerpStackFork.testDepositGasDependsOnWhetherTheCashWasTouchedThisBlock`.

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
