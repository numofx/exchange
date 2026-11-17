# EURC-30NOV26 expiry run-sheet (Sunday 2026-11-30)

The first EURC series with outside users, an `OnchainBook` market and no pager (removed 2026-11-17). Times UTC.
Written 2026-11-17 from the contracts, the keeper and the deployment artifacts; re-check the "Before" list on 11-28.

## Facts

| | |
|---|---|
| Series | `FutureAsset` v3 `0xC350243c1d07Ff598770ECe12323799D2EFbB227`, subId **1796050800** |
| Last trade | **14:30** (1796049000): `Matching` and the book stop trading it |
| Fixing window | **14:30–15:00**, the index sampled at least every **120 s** (`maxSampleGap`); the keeper samples every 30 s |
| Expiry | **15:00** (1796050800): settlement price = the window's TWAP of the index |
| Recovery | If the window broke: a new window opens **1 h** later (`recoveryDelay`), 30 min long, repeating until one completes. Never EUR/USD, never a chosen price (spec A8.2) |
| Marks | From 14:30 the mark is the index (A8.3) |
| Engine | MarginEngine v2 `0x0705…0950`, pool account #37 |
| Index | `EurcIndexFeed` `0x5658…24D9`, reverts when its reports are over **60 s** old |
| Keeper | ops box `numo-future-feeds-v3@eurc-30nov26`: posts reports every 20 s, forward marks, fixing samples, settlement, close-out. Pays gas from the v3 relayer `0x0AbA…12e5` |
| Book | `OnchainBook` `0x8Fc6…d456`, market 1; maker ECS `market-maker-book` on #56. **If v2 is live** (`onchain-book-v2-runsheet.md`): the v2 book (`ONCHAIN_BOOK_V2.json`), market 1, maker ECS `market-maker-book-v2`, self-priced, on its own account |
| Matching maker | ECS `market-maker-future-v2-eurc` on #40 |
| Open interest | 2 EURC on 2026-11-17 (`totalPosition(engine)` / 2) |

## What tells us something is wrong (no pager)

Nothing phones anyone. During the day someone has to be watching **Slack** and **healthchecks.io**, from 13:00 until
the series is settled and closed out.
- **Pages (Pushover, through healthchecks.io), since 2026-11-17:** `report-age` (the adapter's reports over 120 s old
  for two minutes running) and `signer-balance-alert` (any hot wallet under 2 days of gas; under 7 days is a
  low-priority push).
- **Slack:** the keeper's alerts (`fixing-failed`, a recovery opened, `close-out-failed-<id>`), the settlement
  canary, `NUMO HOT WALLET LOW GAS`, `NUMO FILL VOIDED`, settlement-verifier posts.
- **healthchecks.io:** `settlement-canary`, `settlement-canary-ecs`, `book-maker`, `signer-balance-alert`,
  `heartbeats`, `rebalance-check`.
- **The chain:** the checks below. Use `RPC=https://mainnet.base.org` or the keyed endpoint.

```sh
F=0xC350243c1d07Ff598770ECe12323799D2EFbB227; S=1796050800; E=0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950
cast call $F 'futureContracts(uint256)((bool,bool,uint64,uint64,uint64,uint256,int256))' $S --rpc-url $RPC   # listed, settled, …, markPrice
cast call $F 'fixings(uint256)((uint32,uint64,uint64,uint64,uint64,uint64,uint64,address,uint256,uint256))' $S --rpc-url $RPC  # round, window, largestGap
cast call 0x56582804c815A17c806d140e8554fA36777B24D9 'getSpot()(uint256,uint256)' --rpc-url $RPC   # reverts when the index is stale
cast call $F 'totalPosition(address)(uint256)' $E --rpc-url $RPC   # 2 x open interest; 0 when all closed out
cast balance 0x0AbAac33E5ab7E62dED100Be465032A3636b12e5 --ether --rpc-url $RPC   # the keeper's gas
```
On the box: `journalctl -u numo-future-feeds-v3@eurc-30nov26 -f`.

## Before (by Friday 11-28)

- [ ] **Keeper gas.** The v3 relayer holds at least 0.01 ETH beyond its burn to 12-01 (~0.003 ETH/day). It posts
      every report the fixing samples; an empty relayer on the day breaks the window.
- [ ] **Feed signer** and **market-maker wallet** funded the same way (Slack's signer-balance alert quiet).
- [ ] The keeper unit active, its last fixing-related log line sane; `getSpot()` answers.
- [ ] `settlement-canary` and `settlement-canary-ecs` green; `book-maker` green.
- [ ] Someone named to watch Slack 13:00 → settled, with box (SSM) and AWS access, and a funded laptop key for
      permissionless calls if the keeper is down.
- [ ] Decide whether to roll: is a next EURC series to be listed (a separate deploy, not part of this sheet)?

## The day

| Time | What happens | Check | If not |
|---|---|---|---|
| **13:30** | Both makers stop quoting: the book-maker's cutoff (`MM_BOOK_CUTOFF_SECONDS` 3600) cancels its spline; the Matching maker's orders cannot be signed past 13:30 | `splines(1,56)` active = false; no `mm:EURC-30NOV26` orders on `/book` | Book: `aws ecs update-service … market-maker-book --desired-count 0` (SIGTERM cancels). Matching: its orders expire within 300 s |
| 13:30–14:30 | Users may still trade each other on Matching; no maker | — | — |
| **14:30** | Last trade: the matcher stops crossing the series; the book refuses takes (`OB_TradingClosed`); fixing window opens | `fixings(S).windowStart` = 1796049000; samples appear (`lastSampleTime` moving) | Index stale? → **Index down** below |
| 14:30–15:00 | Keeper samples every 30 s | `largestGap` ≤ 120 | A gap > 120 s breaks the window → recovery (below), no action now except restoring the index |
| **15:00** | Expiry. Keeper calls `fixSettlementFromIndex` | `futureContracts(S).settled` = true; price = TWAP | Window broke → keeper opens recovery and alerts |
| 15:00+ | Keeper calls `closeOutExpired(account, S)` on every holder, a batch a tick | `totalPosition(engine)` → 0 | `close-out-failed-<id>` → **Close-out** below |

## If something breaks

**Index down (reports stale > 60 s)** — a dry relayer, the keeper stopped, Data Streams or Base RPC trouble.
1. Relayer balance; if low, fund it from any wallet (the feed signer's spare, or outside ETH).
2. `systemctl status` / restart `numo-future-feeds-v3@eurc-30nov26` over SSM; watch it post.
3. If samples were missed for over 120 s the window is already broken: do not try to rescue it. Recovery opens 1 h
   after the break; get the index healthy before then. Settlement then comes from the recovery window (16:00–16:30
   if the first window broke at expiry), and repeats until one completes. Margin keeps following the index meanwhile
   (A8.3); holders cannot exit after 14:30 (they carry the price until settlement).

**Keeper's relayer empty or its key lost: switch to the backup relayer.** Posting reports and the fixing calls accept
any sender, and forward marks are signed by the KMS forward signer, so the keeper runs from any funded key. The
standby is `0x0f79B47421fd21B1E4C39Ee717DF9A24d1A62F39` (SSM `/numo/feeds/forward_relayer_key_v3_eurc_backup`, readable
by the box): fund it, set `FORWARD_RELAYER_SSM_NAME=forward_relayer_key_v3_eurc_backup` in
`/etc/numo/future-feeds-v3-eurc-30nov26.env`, `systemctl restart numo-future-feeds-v3@eurc-30nov26`, and add it to
`check_signer_balance.py`'s WALLETS. Record it the same day.

**Keeper down but the index fine.** Every fixing step is permissionless: from any funded key,
`cast send $F 'recordFixingSample(uint96)' $S` (every ≤ 120 s in the window), then after expiry
`cast send $F 'fixSettlementFromIndex(uint96)' $S`, or `'openRecoveryWindow(uint96)' $S` if it broke.

**Close-out fails for an account.** `cast send $E 'closeOutExpired(uint256,uint96)' <account> $S` from any funded key.
Close-out reads no feed, so it works with the index down. Check the pool account #37's cash afterwards (the keeper's
deficit cover is shared with the cNGN series).

**Book still quoting after 13:30.** Stop `market-maker-book` (above), and `market-maker-book-v2` the same way if v2 is live. A self-priced quote lapses 30 s after its maker stops. The book itself refuses takes from 14:30 regardless.

**A phantom fill on the last trades.** The settlement verifier voids it within ~10 min and posts `NUMO FILL VOIDED`.
Before the 14:30 close, check `trade_fills_voided` stays empty.

## After (from 12-01)

- [ ] `settled` = true, `totalPosition(engine)` = 0; settlement price recorded in `OPS_BOX_CHANGES.md`.
- [ ] **Book:** set `desired_count_market_maker_book = 0` (counts.auto.tfvars) and apply; withdraw #56's USDC
      (`CashAsset.withdraw(56, …, 0x3448…)`, ~450) and the taker #57's 49.99; pause or delete the `book-maker`
      healthcheck. The market cannot trade again (past last trade); disabling it in the vault is optional.
- [ ] **Book v2, if live:** the same for `desired_count_market_maker_book_v2` and its account, and the
      `book-maker-v2` healthcheck; drop `onchain_book_v2_address` once its tape is final. Lower the MM wallet's floor back
      in `check_signer_balance.py`.
- [ ] **Matching:** `market-maker-future-v2-eurc` to 0 or onto the next series; `FUTURE_SERIES` drops EURC-30NOV26 when
      the app no longer needs to show it (a matcher redeploy: `with-matcher-mute.sh`).
- [ ] **Keeper:** after close-out, `systemctl disable --now numo-future-feeds-v3@eurc-30nov26`; sweep the v3 relayer's
      ETH to the next series' keeper or the feed signer.
- [ ] **Report age:** once the keeper is disabled the reports stop by design: `systemctl disable --now
      numo-report-age.timer` and pause the `report-age` healthcheck, unless a next series uses the same adapter.
- [ ] **Indexer:** keep `onchain_book_address` until the v2 book (spec Part C) replaces it.
- [ ] Record every hand step in `OPS_BOX_CHANGES.md` the same day.
