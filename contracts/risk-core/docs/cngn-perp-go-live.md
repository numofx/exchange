# USDCcNGN-PERP go-live

The order to launch the perp in, with every human action and amount; the rules each step has to
meet; and the operator procedures the running market needs: the guardian, the cap, reopening after
a real index step, and settling one that is too large to reopen. Every step here can be
rehearsed first on `scripts/local-venue/up.sh`, and the index step on `step-drill.sh`.

Nothing in this runbook broadcasts or signs by itself. Deploys are signed by the deployer from a
forge keystore account (`--account numo-deployer`); the key is never put on a command line or in
an environment variable. Vault actions go through MPCVault, and a human approves each one.

## Go-live checklist

Every human action, in order, with amounts. Gas figures are measured on a Base fork and priced at
0.006 gwei (Base, 2026-09-29), with the L1 data fee from Base's GasPriceOracle; the ETH amounts
leave 10-25x for gas spikes. Totals: **0.097 ETH** across five addresses and **$30,500 USDC**
across three accounts.

**Before anything (blocking)**

1. **Index sources.** On the ops host: `node dist/main.js --probe-sources` (perp-feeds). It must
   report all 3 fiat sources answering and the peg tripwire watching near parity (see Index sources
   below). That is exactly 3, with no spare: from the ops host, Bybit P2P above all must answer
   (it failed DNS from a developer machine once on 2026-09-30, then answered).
2. **Code live, spot first.** The new markets-service and execution-service must carry spot
   unchanged before anything perp is switched on.
   - **Regression, before deploying:** `scripts/local-venue/up.sh --spot-only` passes on the commit
     being deployed. It runs both services with every perp variable unset, as they will run until
     step 12. It checks that `/v1/markets` serves spot only, that a spot fill matches the fill
     contract (both legs, the 25 bps fee) and was sent with gas headroom, and that a spot withdrawal
     pays out.
   - **Record the rollback point:** the current task-definition revision of each of the three ECS
     services (markets api, matcher, execution):
     `aws ecs describe-services --cluster <cluster> --services <service> --query 'services[0].taskDefinition'`.
   - **Deploy** markets-service (api and matcher) and execution-service to ECS, with no
     `cngn_perp_*` / `PERP_TRADE_MODULE_ADDRESS` set. #81 adds **no database migrations**, so the
     previous revision can run on the same database.
   - **Watch window: 24 hours**, and at least five real spot fills, before step 3. Each must hold:
     - every spot settlement succeeds: in the execution log, and one real crossing order checked
       end to end by nonce, transaction hash and `verifyAndMatch` selector, since a green canary
       proves nothing;
     - `/v1/markets` still lists spot only, with unchanged fields;
     - no new errors in the api, matcher or execution logs;
     - one small real withdrawal (1 USDC) pays out.
   - **Rollback**, on any failed spot fill or withdrawal or a new error class: return each service
     to its recorded revision with
     `aws ecs update-service --cluster <cluster> --service <service> --task-definition <recorded revision>`,
     then `aws ecs wait services-stable ...`. Re-pin the previous image tag in Terraform afterwards,
     so the next `apply` does not redeploy the bad one.
   - Merge numofx/trading-app#103 (its ticket stays closed until `trading_enabled`) and
     numofx/market-maker#26.
3. **Pager and its dead-man's switch.**
   - Create a heartbeat check (healthchecks.io or equivalent) with period 1 minute and grace
     5 minutes, and route its alert to your phone (its Pushover or PagerDuty integration). If the
     pager stops running (the timer, the host, the RPC), the pings stop and this check pages you. A
     failed run pings `<check>/fail` and pages at once.
   - Put the pager secrets in SSM under `/numo/pager/`: `provider` (`pushover` or `pagerduty`), its
     keys, and `heartbeat_url` (**required**: without it the pager pages you once a day about that,
     and the enable gate refuses).
   - Run `scripts/ops/run-with-ssm-pager.sh python3 scripts/ops/check_perp_pager.py --test-page`
     and **confirm your phone received it**. A 2xx from the pager API is not delivery.
   - The timer goes on in step 14, once there are feeds to watch.
4. **Guardian key.**
   - `terraform apply` creates `alias/<name>-perp-guardian` (`perp_guardian_kms_enabled`).
   - Read its address with `AWS_KMS_KEY_ID=alias/<name>-perp-guardian cast wallet address --aws`.
   - Fund it **0.002 ETH** (a pause is ~50k gas).

**Deploy**

5. Fund the deployer **0.005 ETH**. The deploy is 77 transactions, 33.0M gas, ~0.0002 ETH today.
   The deployer's key lives in a forge keystore named `numo-deployer`
   (`cast wallet import numo-deployer --interactive`, once; `cast wallet address --account
   numo-deployer` must print the deployer). Both deploy scripts refuse to run without a sender.
6. Broadcast the stack, from `contracts/risk-core`:
   ```bash
   FEED_SIGNER=0xdA1976E83D54B76D0c794B35262228960a1a918f PERP_GUARDIAN=<the KMS address> \
     forge script scripts/deploy-cngn-perp-stack.s.sol --rpc-url $BASE_RPC_URL \
     --account numo-deployer --broadcast
   ```
   `FEED_SIGNER` must be what `/numo/feeds/feed_signer_key` derives to (checked 2026-09-30).
   `PERP_OI_CAP` defaults to 50,000,000 cNGN.
7. Broadcast the module, from `contracts/execution`:
   ```bash
   forge script scripts/deploy-cngn-perp-trade-module.s.sol --rpc-url $BASE_RPC_URL \
     --account numo-deployer --broadcast
   ```
8. Commit the deployment artifacts (`CNGN_PERP_STACK*.json`, `CNGN_PERP_TRADE_MODULE*.json`).
9. **Requires the follow-up exchange PR (the index rework and the pager's dead-man's switch) to
   be merged first.** Then **render the review file:** `python3 scripts/ops/render_perp_vault_review.py` writes
   `deployments/8453/CNGN_PERP_VAULT_REVIEW.md` with every action of all three batches: target,
   function, decoded arguments, purpose and digest. Every row is checked by re-encoding the
   calldata and recomputing the digest. Read it before signing anything, and match each digest in
   MPCVault against it.

**Vault custody** (MPCVault; the market stays closed)

10. `CNGN_PERP_STACK_VAULT_ACTIONS.json`: 12 actions, `acceptOwnership` on 11 contracts then
    `srm.setGuardian`.
11. `CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json`: 1 action, `acceptOwnership`.

**Services**

12. Set the `cngn_perp_*` Terraform vars from the artifacts, `terraform apply`, and redeploy
    markets-service and execution-service.
    - `/v1/markets` then lists `USDCcNGN-PERP`. Its `perp` block (with `trading_enabled: false`)
      appears once the index feed has published (step 14); until then markets-service logs a
      `read perp state … BLF_DataTooOld` warning per request and serves the entry without it.
    - Watch spot for an hour, with the step 2 checks.
    - **Rollback** here is to unset the perp vars and redeploy. The perp is closed, so nothing
      depends on them yet.
13. Top up the executor (`0xF68ebcC8…678703`) by **0.02 ETH**. A perp settlement is ~1.6M gas,
    ~0.00001 ETH: about 2,000 settlements.
14. **Feeds and pager on.**
    - The ops box has Node v22.23.3 (CI's major version; official build, SHA-256 checked) in
      `/opt/node-v22.23.3-linux-x64`, linked as `/usr/bin/node`, `npm`, `npx` and `pnpm` (8.7.3,
      the repo's `packageManager`), installed 2026-09-30. Build per the service files' `Install:`
      lines.
    - Fund the feed relayer (`0xC9F1…0FDc`) **0.05 ETH** and start perp-feeds live. Measured per
      publish: index 46k gas, mark + impacts 120k gas. That is ~0.0003 ETH a day typical and 0.0013
      worst case (a mark every minute), so 0.05 ETH lasts more than a month at worst.
    - `/etc/numo/perp-pager.env` holds `KEEPER_HEALTH_URL=http://127.0.0.1:9464/health`,
      `PERP_INDEX_STATUS_FILE` (perp-feeds' status file, `/var/lib/numo/perp-index-status.json`) and
      `PAGER_STATE_FILE`; then `systemctl enable --now numo-perp-pager.timer`. On the ops box the
      perp units run from the clean checkout `/home/ec2-user/exchange-perp`, not `~/exchange`.
    - The "keeper unhealthy" page is armed only once the keeper has reported healthy once, or the
      market is open (cap > 0): no page for a keeper that is not installed yet. From here the pager
      also pages **low gas** on the executor and relayer (under 2 days of measured burn, or under
      the floor), and warns in Slack under 7 days.
15. **Keeper funding** (before the rehearsal, which uses this account).
    - Fund the keeper EOA **0.006 ETH** or more. A full liquidation cycle is ~3M gas ≈ 0.00002 ETH, so
      that is ~200 cycles; the keeper, the enable gate and the pager all floor at 0.002 ETH.
    - From the keeper EOA, directly on SubAccounts: `createAccount(keeperEOA, perpSRM)`, approve
      USDC to the perp cash, then `CashAsset.deposit(account, 5_000e6)` for **$5,000 USDC**
      (`scripts/local-venue`-style one-shot from the ops box, keeper key from SSM).
      Not through the app or SubAccountCreator: that parks the account in Matching, where the
      keeper cannot move its cash, and every bid fails. The keeper and the gate both refuse it.
    - Put `KEEPER_ACCOUNT`, `MAX_BID_USD=1500` and `HEALTH_PORT=9464` in `/etc/numo/perp-keeper.env`,
      and `KEEPER_EOA=<the keeper EOA>` plus `KEEPER_ACCOUNT` in `/etc/numo/perp-pager.env` so the
      pager watches its gas and its cash against open interest.
    - Why $5,000 and a $1,500 bid cap: the keeper must hold maintenance margin (20%) for whatever it
      inherits in an auction, and carries it until unwound; $5k margins up to ~$25k of inherited
      notional, and the bid cap keeps one account from taking it all in one bite (the largest
      account at the cap, one full side ≈ $18k, then takes a few auction rounds). In the 40% drill
      the keeper tied up $2,070. The collateral rule below says when this must grow.
16. **Keeper smoke, ~10 minutes of `DRY_RUN=true` on the real config.** A closed market has nothing
    to liquidate, so this proves only that the keeper is wired:
    - `/health` shows `lastPassOk: true` and `dryRun: true`;
    - account discovery completes;
    - one alert reaches Slack prefixed `[TEST]`, and you read it in the channel.
17. **Mainnet-fork rehearsal: the liquidation path, with the production build, config and key.**
    ```bash
    export KEEPER_KEY="$(aws ssm get-parameter --name /numo/keeper/keeper_key --with-decryption \
      --query Parameter.Value --output text --region us-east-1)"
    BASE_RPC_URL=<archive RPC> REHEARSAL_ALERT_WEBHOOK_URL=<test channel, optional> \
      scripts/local-venue/rehearse-mainnet.sh --keeper-env /etc/numo/perp-keeper.env
    unset KEEPER_KEY
    ```
    It must print `REHEARSAL PASSED`. On a fork of Base taken now, served as chain 31337, the
    production keeper build liquidates two accounts with the real funding account:
    - it closes an insolvent one, and the SecurityModule pays;
    - it cuts a solvent one back above margin and ends its auction.

    Guards:
    - the script refuses unless the RPC reports 31337;
    - the keeper runs with `CHAIN_ID=31337` and refuses to start if its RPC disagrees;
    - every keeper transaction is checked to be signed for 31337, so none is valid on Base;
    - the deployed feeds and Matching are checked to rebuild their EIP-712 domain for 31337 (the
      keeper itself signs no typed data);
    - every alert is prefixed `[REHEARSAL]`, and alerts go only to the test channel if one is given.
18. **Keeper live:** `DRY_RUN=false`. The pager sees it healthy and arms "keeper unhealthy" from
    then on (a page if it ever stops); the step-16 dry run paged nothing, by design.
19. **SecurityModule:** approve USDC to the SecurityModule, then `donate(8_000e6)` for
    **$8,000 USDC**. The rule below needs $6,065 at 1374 cNGN/USDC. $8,000 still meets it if
    cNGN strengthens to 1,042 per USDC.
20. **Market maker:**
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

21. `python3 scripts/ops/propose_perp_enable_batch.py`: every gate must pass. Then run it with
    `--propose`, and approve action 0 (`setTotalPositionCap`) and then action 1
    (`setAllowedModule`), matching each digest against batch 3 of the review file.
22. Within 30s `/v1/markets` reports `trading_enabled: true` and the app's ticket opens. Set
    `MM_PERP_QUOTE_WHILE_CLOSED=false` again.

The gates step 21 checks:

| Gate | What must hold |
| --- | --- |
| custody | The vault owns every contract. The SRM has a guardian that is not the vault. The market is still closed. |
| feeds | The index and all three diff feeds are 10 minutes old or less. |
| keeper | Its last pass succeeded recently and it is not in dry run. The keeper EOA owns its funding account, which is under the perp SRM, holds only cash and has enough of it. It has gas. |
| sm | The SecurityModule holds at least the seed rule. |
| quoter | The book is two-sided, with at least $1k within 2% of the index on each side. |
| pager | `check_perp_pager.py` ran successfully within 3 minutes, with a real provider and a dead-man's switch. |

## SecurityModule seed

**The SecurityModule must hold at least a third of ONE side's notional at the current cap:**

```text
seed >= (cap / 2 cNGN) × index (USDC per cNGN) / 3
```

The cap counts `|position|` over both sides, so one side is half of it. At the 50M cNGN launch cap
and 1374 cNGN/USDC, one side is $18,195, so the seed is at least **$6,065**. The enable gate computes
this from the live index and refuses below it; `--min-sm-cash` (default $5k) is only a floor under
it.

**Raising the cap is a new launch** for this rule: top the SecurityModule up to a third of the new
side first.

## Keeper collateral

**The keeper's bid account must hold at least a third of ONE side's notional at the cap**, the same
shape as the seed rule, for the same reason: a third is what it takes to margin and carry that side
if it has to be taken over.

```text
keeper cash >= (cap / 2 cNGN) × index (USDC per cNGN) / 3
```

At the 50M cNGN launch cap and 1362 cNGN/USDC one side is $18,350, so the rule asks **$6,117**; the
$5,000 funded at step 15 is a deliberate shortfall accepted at launch, which the pager covers: it
Slack-warns when one side's live OI passes 2x the keeper's cash ($10k) and pages at 3x ($15k, 82% of
the side at the cap). **Before any cap increase, top the keeper account up to a third of the new
side**, exactly as for the SecurityModule; the enable gate's `--min-keeper-cash` (default $5,000)
is only the floor under it.

Why a third: it is the initial margin on that side. In
`CngnPerpStackFork.testSecurityModuleLossFromIndexJumpAtFullCap`, the whole long side sits in one
account just above maintenance margin and the insolvent auction runs to its most expensive second.
The SecurityModule's payout there reaches this size at an index jump of about 50%:

| Index jump | SecurityModule pays (at 50M cNGN) |
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
holds it. It is used only from your admin AWS session. Keep ~0.002 ETH at its address.

**You pause and unpause alone.** As the single operator, you may do both with this key; no second
person is needed. The discipline that replaces the second person: write down why you paused, and
unpause only once that cause is removed.

```bash
export AWS_KMS_KEY_ID=alias/<name>-perp-guardian AWS_REGION=us-east-1
SRM=$(jq -r .srm contracts/risk-core/deployments/8453/CNGN_PERP_STACK.json)

cast call $SRM "adjustmentsPaused()(bool)" --rpc-url $BASE_RPC_URL                           # state
cast send $SRM "setAdjustmentsPaused(bool)" true  --aws --rpc-url $BASE_RPC_URL              # pause
cast send $SRM "setAdjustmentsPaused(bool)" false --aws --rpc-url $BASE_RPC_URL              # unpause
cast call $SRM "adjustmentsPaused()(bool)" --rpc-url $BASE_RPC_URL                           # confirm
```

**Recovery, when the key is lost, unusable or compromised.** Suspect compromise if a pause or
unpause happened that you did not send. The worst a compromised key can do is freeze or unfreeze
the book; it cannot move funds. Recovery is the vault reclaiming the role and rotating the key:

1. **Vault: `srm.setGuardian(<vault address>)`** (MPCVault custom transaction). From this moment the
   old key can do nothing, and the vault is guardian.
2. If the book must change state now, **vault: `srm.setAdjustmentsPaused(true|false)`** through
   MPCVault. It is slow, because it needs your signers, but it works without the hot key.
3. Create a new key. Add a second `aws_kms_key` / `aws_kms_alias` pair with a new alias (the old
   one's `prevent_destroy` keeps it), `terraform apply`, read its address, and fund it 0.002 ETH.
4. **Vault: `srm.setGuardian(<new key address>)`.** Update the alias in the commands above.
5. Only then, and only if you want to, remove the old key: drop its `prevent_destroy` and schedule
   deletion. Never before step 1, or the chain keeps pointing at a key you can no longer use.

**What pages your phone** (`check_perp_pager.py`, every minute, through Pushover emergency priority
or PagerDuty). Each page also goes to Slack. It re-pages every 30 minutes while a condition lasts,
and tells you when it clears.

| Page | What it means | First response | Pause? |
| --- | --- | --- | --- |
| feed halt | The index or an impact feed is more than 16 minutes old, or the mark more than 10. At 20 minutes (index) the market halts itself: no trades, no liquidations. Two refused publishes in a row reach 15 minutes without halting anything, so the page waits for a third. | Check perp-feeds is running, its relayer has gas, and `--probe-sources` shows 3 sources. If the jump guard stopped it, follow the index-step procedure. | Only if the feeds are publishing *wrong* prices (a compromised signer). A stale feed already stops the market. |
| keeper unhealthy | `/health` is unreachable, in dry run, or failing. Nothing is liquidating. Armed once the keeper has ever reported healthy, or the market is open. | Restart the keeper. Check its funding account's cash and its gas. | No: a pause also blocks the liquidations you need. |
| OI vs keeper | One side's open interest (at the index) is 3x or more the keeper bid account's cash; Slack warns from 2x. The keeper could not margin what a liquidation hands it. | Top up the keeper account (`CashAsset.deposit`), or **cap = current OI** until it is topped up. | No. |
| low gas | The executor, relayer or keeper EOA holds under 2 days of its measured 24h burn, or under its floor (executor 0.002 / relayer 0.003 / keeper 0.002 ETH; a liquidation cycle is ~3M gas ≈ 0.00002 ETH, so 0.002 is ~100 cycles). Slack warns under 7 days. Measured 2026-10-01: executor ~0.00003 ETH/day (6 settlements), relayer 0.0003 typical / 0.0013 worst, keeper ~0 idle. | Top it up. The relayer stopping halts the market within 20 minutes; the executor stopping fails every fill; the keeper stopping leaves liquidations to no one. | No. |
| SecurityModule payout | The SecurityModule paid for a liquidation. | Expected after an insolvent liquidation. Check it still meets the seed rule and top it up if not. | Only if the payouts are not explained by liquidations (an exploit). |
| peg guard | cNGN is more than 100 bps from NGN parity on Quidax's peg market, so perp-feeds refuses to update the index. It halts when the index goes stale. | Check `cngnngn` on Quidax and cNGN news. If cNGN has really depegged, the index cannot follow it; treat it as a step (index-step procedure, or settlement if over 50%). | Only if the depeg comes from an exploit. |
| insolvent account | An account is below zero. The keeper should be auctioning it, and the SecurityModule will pay. | Watch the keeper take it. If several go at once, consider **cap = current OI** (below). | Only if it is the result of an exploit. |

## Emergency levers

In order of preference. Each is narrower than the next, and each is safer than it looks only if its
limits are respected.

1. **Reduce risk: cap = current OI.** Vault `perp.setTotalPositionCap(srm, perp.totalPosition(srm))`.
   No new position can open, and everyone can still add margin, withdraw, close and be liquidated.
   **Set it to the current OI, never lower**: below the current OI, every account holding the perp
   is frozen out of deposits and withdrawals (next section).
2. **Close the venue.** Vault `matching.setAllowedModule(perpModule, false)`. Matching stops trading
   the perp; spot is untouched. Transfers between accounts outside Matching are still bounded by the
   cap, so pair it with lever 1.
3. **Stop the matcher.** An off-chain stop, needing no signers, but it **halts spot too**.
4. **Guardian pause.** Exploits only (the section above). It freezes everything, liquidations
   included.

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
   INDEX_STEP_MAX_BPS=10000 node dist/main.js --accept-index-step --level=<cNGN per USDC> \
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
   node dist/main.js --accept-index-step --level=<cNGN per USDC> \
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

**What the index measures: fiat NGN per USD stablecoin, taken as cNGN at redemption parity.**
cNGN's price is held by redemption (1 cNGN redeems for 1 NGN), not by trading, so the deep fiat
NGN/USDT markets are the right basis, and the thin cNGN trading markets are not. Every source is a
fiat venue (`services/perp-feeds/src/index-sources.ts`); its NGN per USDT is used as cNGN per USDT
with no conversion.

| Source | Market | 2026-09-30 |
| --- | --- | --- |
| Quidax | `usdtngn` (fiat NGN) | 1368.22 |
| Textile | `USDT_NGN` (Textile Credit FX feed) | 1368.82 |
| Bybit P2P | USDT ads in NGN, fraud-filtered | 1367.50 |

A sample is their median, refused unless all 3 answer and each sits within 150 bps of it. There
are **exactly 3, with no spare**: one venue failing halts the index once it goes stale. Textile's
`USDC_NGN` is the same venue as its `USDT_NGN`, so it is not a fourth source. Binance P2P has no
official API. USDT is taken as USDC, which the perp settles in.

**The peg tripwire** (`peg.ts`) is not a source, and it converts nothing. It watches whether cNGN
still sits at NGN parity: a 15-minute TWAP of Quidax `cngnngn` book mids, sampled every minute (the
market trades too rarely for a trade TWAP: 27 of 300 hours to 2026-09-30), from books no wider
than 50 bps.
- **Tripped** (more than 100 bps from parity): every sample is refused, so the index halts once it
  goes stale, and the pager pages "peg guard". The index cannot follow a real depeg; handle it as a
  step (index-step procedure, or settlement if over 50%).
- **Blind** (no good peg sample in 15 minutes): the index carries on at parity, because redemption
  does not depend on Quidax. perp-feeds alerts `peg-blind` to the alert channel (not the pager) and
  the status file (`INDEX_STATUS_FILE`) records `peg.state: "blind"`.

The direct cNGN markets (Quidax `usdtcngn`, the Blockradar benchmark, HyperFX `USDC-cNGN` on Base)
are not sources: they measure cNGN trading, which is thin (Quidax `usdtcngn` ~30 USDT/day, HyperFX
one solver a side). Their readers were built and removed in exchange#83; the history has them.
