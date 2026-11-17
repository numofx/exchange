# Ops box changes

Every change made to the ops box (`i-06107393582d770e3`) by hand, recorded the same day. The box
is not provisioned from this repo: its checkout at `/home/ec2-user/exchange` is pinned at
`bf9da89` (2026-07-22) and individual files are copied over it. Until that is fixed, this file is
the only place the box's real state is written down. Newest first.

## 2026-11-17 19:01–19:09 UTC: EURC-30NOV26's whole size moved from Matching to the v2 OnchainBook (D4 A, D6) (ECS, laptop)

Owner's choice A and yes to the 1,290 USDC move.

- **Bot.** market-maker `67de39e9`: the inventory cap (`MM_BOOK_MAX_POSITION_LOTS`): a side whose whole curve would take
  the position past the cap quotes a park curve (one lot 500,000 ticks out, outside the ±2.79% index band, so it never
  fills). Rehearsed on an anvil fork against #58: parked at −60 of a 100 cap, a further buy filled 0, unparked at −30.
  Image `market-maker:67de39e99225` (refuses a cap under one side's curve).
- **#40's Matching maker stopped:** `desired_count_market_maker_future_v2.eurc` 0 (counts.auto.tfvars), plan 1 change;
  task `29483bf6…` STOPPED 19:01:47; its 10 orders expired by 19:03:38 (`move-usdc` refused while they rested). cNGN's
  maker untouched.
- **1,290 USDC #40 → #58:** `migrate-spot-mm.ts move-usdc 40 58 1290000000 --execute` (laptop, the MM key from SSM in a
  subshell): withdrawal through `/withdrawals` `0xad3485f3…381b` (block 58,759,468), approve `0x55da99ba…ef7d`, deposit
  `0xf9ab0037…77fc` (block 58,759,477). Read back: #58 1,590.01 cash, flat; #40 10.31 cash, short 2 EURC (to expiry).
- **Book maker on the whole ladder** (`5365ddc`): curve
  `116@0,139@330,167@660,200@990,241@1320,289@1650,346@1980,416@2310,499@2640,599@2970` (3,012 EURC a side), half-spread
  880 (8 bps), skew 1 tick a lot to 2,750, cap 5,000 lots. Plan: only those env values and the image. Old task
  `adcc2fc8…` STOPPED 19:07:42; the new one (`0056e48c…`) set curve 1 and the park curve 2 (`0x34e3b313…`), preflight ok,
  quoting from its first cycle. Read back: spline half-spread 880, skew 1/2,750, curves as configured.
- **Reachable in one take, `quote` with no account:** buy 3,012 EURC at avg 1.104510, sell 3,012 at 1.098808 (one
  maker); a 4,000 order fills the same 3,012. EURC-30NOV26 had no quotes from us for ~5 minutes on Matching (19:03:38 to
  the book's 19:08 update, the book's 60-EURC canary standing until the switch).
- **Undo:** eurc back to 1 with `move-usdc 58 40` first (the book maker's curve back to the canary).

## 2026-11-17: the kit's DeltaHedgedEurcVault run on mainnet: spot, lending and the v2 book in one transaction (laptop, `cast`/`forge create`)

Owner's yes for steps 1–5; code `a69afb6` (adds `close` and `withdrawMargin`), rehearsed at head by
`DeltaHedgedEurcVaultLiveFork`. All from the canary taker wallet `0x3Fdf…a914` (key SSM
`/numo/deploy/onchain_book_taker_key`).

- **Funded:** `CashAsset.withdraw(56, 25 USDC, taker)` from the MM wallet, tx `0x22ab3e30…6ec2`.
- **Deployed** `DeltaHedgedEurcVault` at **`0xf2255C8606e887B0866681DED41e6a1c042B2abB`**, tx `0x81c4d5e2…9ff3`: owner the
  taker, book v2 market 1, its own account **#59** (engine v2), Morpho market `0xa04698b2…a8b3` (EURC collateral, USDC
  loan, Chainlink EURC/USD oracle `0x0e78…f7e0`, 86% LLTV; unlisted, ~$10 supplied by someone else), Aerodrome
  Slipstream EURC/USDC `0xc5E5…48c1`. Not audited.
- **Our own loan:** 10 USDC supplied to that market (`0xc6a449dd…0362`), so the borrow did not use a stranger's few
  dollars. 10 USDC as margin on #59 (`0xd282ad8b…2007`).
- **Open, one transaction, no reports:** tx **`0xa634e40d…55ed`**, block 58,754,433, 1,391,861 gas: Morpho flash loan
  5 USDC; 10 USDC to 9.079632 EURC on Aerodrome; the EURC as Morpho collateral, 5 USDC borrowed (repaying the flash);
  short 9 EURC on the v2 book against #58 at 1.101475 (fee 0.0049566). Delta after: +0.079632 EURC (under a lot).
  The first send timed out at the RPC; nonce 18 read unused (latest and pending), so it was re-sent once with
  `--nonce 18`.
- **Close, one transaction:** tx `0x74026401…6374`, block 58,754,531, 1,144,253 gas: bought 9 back at 1.10205 (fee
  0.0049592), flash-borrowed 6 USDC, repaid the debt, withdrew the collateral, sold it; 4.998598 USDC to the taker.
  Read back: no debt, no collateral, delta 0.
- **Back:** `withdrawMargin(9.984909)` (`0xca20871c…175a`; #59 keeps 0.0000001 dust), Morpho supply withdrawn by shares
  (`0x9ceea2a4…0ba2`, 9.999999), 24.983506 USDC deposited back to #56 (`0x7d114573…e6f9`). #56 149.9866 (was 150.0031):
  the run cost 0.0165 USDC (two book fees 0.0099, the spread, the swaps) and ~0.00004 ETH of the taker's gas. Taker
  wallet: 0 USDC, 0.000157 ETH.

## 2026-11-17 18:26–18:29 UTC: book-maker-v2 reprices at 50 ticks (ECS, terraform from `main`)

- **What** (`7009a45`, owner's call): `MM_BOOK_REPRICE_TICKS` 20 → 50 on the v2 bot only; the plan changed that value
  alone. At 20, reprices were 155 of 353 sends.
- **Rollout:** the old task (`41df820b…`) cancelled its spline at 18:26:10 (`0xf3b70b44…`) and sent nothing after; the
  new one (`adcc2fc8…`) started 18:27:05, `preflight ok` with the market enabled, re-quoted at 18:27:06; the old
  STOPPED by 18:28:47 (`wait-for-rollout.sh`). ~1 min unquoted; no warnings or errors in either stream.
- **Next:** re-measure sends an hour on, and set the burn in `check_signer_balance.py` from it.

## 2026-11-17 17:40–18:24 UTC: v2 book enabled; canary takes with no reports filled against #58 (C0 test 3a)

- **Enabled** by the vault (MPCVault `03129a0f-…` approved by the owner): tx `0xbf9bdaa8…87f7`, 17:40:55; the unit
  `numo-onchain-book-v2-enable` exited 0. Read back: `markets(1).enabled = true`.
- **Taker** #57 (`0x3Fdf…a914`, key SSM `/numo/deploy/onchain_book_taker_key`, 49.99 cash from 2026-11-16) reused:
  - 0.0002 ETH from the MM wallet (owner's yes), tx `0x7786dc77…13ac`;
  - `setAssetAllowances(57, v2 book, future and cash max both ways)`, tx `0xf73bceee…5b64`.
- **Takes, `take(o, "")`: no reports attached,** each simulated and `quote`d first (index 1.101851):
  - buy 5 EURC, tx `0xaae723ff…5c04`, block 58,747,098: filled at 1.102674 against #58, fee 0.002756685, 1,026,383 gas;
  - sell 5, tx `0x5835bba9…b715`, block 58,747,112: at 1.102074, fee 0.002755185, 812,989 gas.
- **Checked:** #57 and #58 flat; across the two blocks #58 +0.003000 (the spread), #57 −0.008512 (spread and fees),
  fee account 22 +0.005512 against 0.00551187 of fees; both `source: book` on `/trades?symbol=EURC-30NOV26` with their
  hashes.
- **Composed case: the router** (`0xd954…76aB`, a contract calling the book for #57's owner), no reports:
  - `SubAccounts.setApprovalForAll(router, true)` from the taker, tx `0x18bf5189…dfa0` (left on: #57 is the canary);
  - `route` buy 5, tx `0x09e12dc6…c108`, block 58,747,573: 1.102527 against #58, fee 0.0027563, 998,244 gas;
  - `route` sell 9 with `reduceOnly`, cut to the position's 5, tx `0x8c548129…1819`, block 58,747,585: 1.101927, fee
    0.0027548, 835,396 gas.
  - Checked as above: both flat; #58 +0.003000, #57 −0.008511, fee account 22 +0.005511 (the fees); both on the tape
    as `source: book`. The kit's `DeltaHedgedEurcVault` flow is not run on mainnet (fork-tested only).

## 2026-11-17 17:20–17:31 UTC: book-maker-v2 dead-man check proven; v2 enable proposed; MM wallet burn 0.0025 (ECS, box)

- **Measured** over the first live task (15:32:14–17:20:15, one stream): 353 sends, 197 refreshes (~25 s), 155
  reprices (20 ticks), 1 initial: ~4,700 a day, 0.0021 ETH/day. `check_signer_balance.py` burn raised to 0.0025
  (`dde270b`, on the box, sha256 `4df1f7ec…a4d5`, SSM `49276177`).
- **Dead-man test.** `aws ecs update-service --desired-count 0` at 17:20 (the task STOPPED by
  `wait-for-rollout.sh`; its spline cancelled on SIGTERM, tx `0x383641f7…`). Last ping 17:20:28; the check went
  `grace` then **`down` at 17:30:53**. Restored with `--desired-count 1` (terraform's count is 1, so no drift):
  preflight ok 17:31:17, a spline at 17:31:17 (`0x14c13a62…`), the check `up` at 17:31:26. Delivery of the email and
  Pushover alert is the owner's to confirm.
- **Enable proposed** from the box (`exchange-ops` at `5d51b72`, the proposer and artifacts unchanged since): dry run
  (SSM `a4bfdf44`) passed all six gates; `numo-onchain-book-v2-enable` (SSM `2237f5c1`) proposed MPCVault
  `03129a0f-…`, digest `0xbbb4450d…ee42`, `setMarketParams(1, …, enabled = true)`. Awaiting approval.

## 2026-11-17 15:32 UTC: book-maker-v2 live on the v2 book; MM wallet funded 0.03 ETH; balance check updated (ECS, box)

- **Funding.** The owner sent 0.03 ETH to the MM wallet (0.030387 read back).
- **Live** (`c263816`, terraform from `main`: only `MM_BOOK_DRY_RUN` true → false). The dry-run task (`80310155…`)
  STOPPED 15:31:51 before the new one (`d91e16d8…`) started 15:32:12. It sent `setCurve` `0xaf0bec01…`,
  `registerMaker` `0x32ea6dbd…`, then a spline `0xe8ec8a0f…`. Read back: `makers(1) = [58]`, `isSelfPriced(1, 58)`,
  mid 1,100,215 ticks, half-spread 300, ttl 30, active. The market is still disabled (step 8).
- **Cadence, first 2 minutes:** refreshes every ~25 s (22 s age on a 5 s poll), and 4 reprices (`MM_BOOK_REPRICE_TICKS`
  20) between them: 7 sends in 110 s, ~5,500 a day, above the 4,000 estimated. Re-measure over an hour before
  trusting the 0.002 burn.
- **Box.** `check_signer_balance.py` replaced by `c263816`'s (sha256 `e4746f85…87a0`, `--self-test` on the box first;
  backup `.bak-202611171533`). SSM `157376ce`. A run by hand read the MM wallet at ~15.2 days, and warned for the feed
  signer (0.008288 ETH, ~6.9 days, under the 7-day line: not this change).
- **Not yet proven:** the `book-maker-v2` dead-man check going down.

## 2026-11-17 15:25 UTC: book-maker-v2 running in dry run (ECS, terraform from `main`)

- **What.** `market-maker:0d687040cfa5` as service `market-maker-book-v2`, account #58 on the v2 book, curve
  `20@0,40@50`, half-spread 300, ttl 30 s, refresh 22 s, `MM_BOOK_DRY_RUN=true`. `desired_count_market_maker_book_v2 = 1`
  in the local `counts.auto.tfvars`.
- **Plan:** 3 to add (log group, task definition, service), 1 to change (the execution role's policy gained only
  `book_maker_v2_heartbeat_url`). No matcher change, so no mute.
- **Log:** `book_v2=true self_priced=true ttl=30s`, would `setCurve` and `registerMaker`, `preflight ok`
  (`market_enabled=false`), heartbeat configured, would send a spline at mid 1,100,142 ticks (1.100142). Nothing sent.
- **Next:** fund the wallet (~0.05 ETH, owner), raise its floor, then `market_maker_book_v2_dry_run = false`.

## 2026-11-17: v2 maker account #58 created, allowances to the v2 book (laptop, `cast send`)

- **What.** From the MM wallet (`0x3448…B47B`, key read from SSM `/numo/exchange/mm_private_key` into a subshell):
  - `SubAccounts.createAccount(0x3448…, MarginEngine v2 0x0705…0950)` → **#58**, tx `0x4fdd17e4…`, block 58,690,327;
  - `setAssetAllowances(58, book 0x83C5…89d5, [(future 0xC350…B227, max, max), (cash 0xA74E…4272, max, max)])`,
    tx `0x27f01fbf…`, block 58,690,343.
- **Read back:** owner the MM wallet, manager MarginEngine v2, both allowances max both ways. Gas ~0.0000012 ETH.
- **Why.** Run-sheet step 4 (D5: a new account for v2, #56 stays on v1). Terraform `onchain_book_v2_maker_account_id`
  defaults to 58; the service stays off until the image is set.
- **Margin (owner's choice B):** 300 USDC moved from #56 (v1 maker, no position) to #58 through the wallet:
  `CashAsset.withdraw(56, 300e6, wallet)` `0x06a8a5b5…` (58,693,297), USDC `approve(cash, 300e6)` `0x29eb0954…`,
  `deposit(58, 300e6)` `0x3e6ac6ab…` (58,693,321). Read back: #56 150.0 cash, #58 300.0, the wallet's USDC unchanged
  (0.047749). The v1 maker quotes 60 EURC a side on 150.

## 2026-11-17 ~13:55 UTC: book-maker-v2 dead-man check (healthchecks.io, SSM); market-maker image 0d687040cfa5 pushed

- **Check.** healthchecks.io "book-maker-v2" (`39ff502b…`), created in the dashboard (the API key in SSM is read-only):
  1 min period, 10 min grace, the project's email and Pushover integrations, never pinged so far (silent until the
  first ping). Its ping URL is SSM `/numo/exchange/book_maker_v2_heartbeat_url` (SecureString), which the execution
  role reads only once `image_market_maker_book_v2` is set (`secrets.tf`).
- **Image.** `market-maker:0d687040cfa5` (book-maker `0d687040`). A smoke run refused a 23 s refresh at a 30 s ttl, so
  the self-priced code is in it. Not deployed: the v2 service waits on the maker account (run-sheet step 4).
- **Not yet proven:** the check going down. Break it once the bot runs: stop the v2 service for 11 minutes and read the
  alert.

## 2026-11-17 13:49–13:52 UTC: markets 6bb45f2: the matcher indexes the v2 OnchainBook beside v1 (ECS)

- **What.** `markets:6bb45f2f367d` (9780841: one book indexer per configured book). The matcher also got
  `ONCHAIN_BOOK_V2_ADDRESS=0x83C5…89d5` and `ONCHAIN_BOOK_V2_START_BLOCK=58656423`, the create transaction's block. No
  migration.
- **How.** Terraform 1.13.3 (the state's writer) in Docker (`hashicorp/terraform:1.13.3`), because the laptop has no
  binary. The `numo` profile's credentials were exported for the run only, and the container's `.terraform` lives in a
  Docker volume. Applied from `main` at `6bb45f2`.
  - The plan touched only the markets, matcher and migrate task definitions (the image) and the two services; the
    matcher alone gained the two variables.
  - Applied through `with-matcher-mute.sh`: the old matcher STOPPED (`2e7e8474…`), with a fresh heartbeat after.
  - Migrate is td :57.
- **Read back.** `/health` → `book_indexers` lists v1 and v2, each at the 20-block confirmation lag with no
  `last_error`; v2 read from its create block to head.
- **Rollback:** `df70d1e726e1` with `onchain_book_v2_address = ""`, in one apply.

## 2026-11-17 13:27–13:44 UTC: OnchainBook v2 setup batch landed (box, `exchange-ops` → `5d51b72`)

- **`/home/ec2-user/exchange-ops`** fetched and detached at `5d51b72` (was `4eec6f7`), clean before and after (SSM
  `8699876c-…`). The proposer and the three `ONCHAIN_BOOK_V2*.json` matched the laptop's sha256. Only the disabled
  `numo-book-maker.service` runs from this checkout.
- **Dry run** on the box (SSM `c047c494-…`): nominated, series and parity (26/26) passed.
- **`numo-onchain-book-v2-setup`**, a transient unit (`systemd-run --uid=ec2-user`, `PYTHONUNBUFFERED=1`), ran
  `run-with-ssm-mark.sh propose_onchain_book_batch.py book-setup --propose` (SSM `9e092ebe-…`). The first start (SSM
  `15a4b2a7-…`) failed on a relative path and sent nothing. Both actions were approved by hand in MPCVault:
  - `acceptOwnership()` (MPCVault `487303fc-…`), tx `0x9dc361fa…1279`, owner the vault by 13:43:38;
  - `setMakerAllowed(0x3448…B47B, true)` (MPCVault `354ca1f2-…`), tx `0xf7528746…dece`, by 13:44:40, after the
    gates re-ran.

  The unit exited 0 and is gone.
- **Read back:** owner the vault, no pending owner, the maker allowed, market 1 still disabled.
- **Undo** the checkout: `git -C /home/ec2-user/exchange-ops checkout --detach 4eec6f7`.

## 2026-11-17 ~13:15 UTC: OnchainBook v2 deployed closed on EURC-30NOV26 (laptop, `forge script`); its deployer key created in SSM

Not a box change; recorded here with the other hand actions of the day. Owner's decisions: v2 on the existing series,
self-priced ttl 30 s (`onchain-book-v2-runsheet.md`).

- **Key.** `/numo/deploy/onchain_book_v2_deployer_key` (SecureString), created from `cast wallet new` and never
  printed. It derives `0x4FECe4c226b5eF0C235aEA97216e61b69FE5263f`. Single use.
- **Funded** 0.0002 ETH from the feed signer `0xC9F1…0FDc` (`/numo/feeds/relayer_key`, address checked before
  sending), tx `0x66a1ed81…cb72`. The feed signer kept 0.00835, ~13 days at its measured burn.
- **Deployed** `deploy-onchain-book.s.sol` at `f3747a0` with `EXPIRY=1796050800`, 5 bps, maker owner the MM wallet.
  The mainnet simulation estimated 8.57M gas.
  - Book `0x83C5741a24d57189379E1215F7A22d9f048E89d5`; router `0xd9540220b514ab2E1a98Ff3C4c4F1F5FD5cf76aB`.
  - Seven transactions in blocks 58,656,423–58,656,479; the create is `0x769e0c25…`. The artifact's `deployBlock`
    (58,656,411) is the block the script ran at, a lower bound. The deployer keeps 0.000162 ETH.
- **Read back.** Owner the deployer, pending owner the vault, `maxSelfPricedTtl` 60, tax 0, market 1 disabled, the
  maker not allowed. The proposer's v2 setup dry run passes nominated, series and parity (26/26).
- **Differs from v1:** `maxMakers` is 10 (the script's default), not v1's 3 (B14a); not passed as `MAX_MAKERS`. Makers
  are allowlisted, so only the MM wallet can register.
- **Next:** the setup batch (acceptOwnership, setMakerAllowed(0x3448…B47B)), proposed from the box. Digests
  `0x6bf0febe…aed9` and `0x7c79dba5…db2`.

## 2026-11-17 ~03:40 UTC: the retired v2 EURC keeper stopped (owner's decision) (SSM, laptop)

- **Checked first:** v2 EURC-30NOV26 `0x6Ff7…7744` (subId 1796054400) has `totalPosition(engine)` 0 and cap 0, the
  engine's market-2 future slot is v3 `0xC350…B227`, and `/markets` lists only v3. The unit's env named the v2 asset.
- `systemctl disable --now numo-future-feeds-v2@eurc-30nov26` (SSM `a1a6c95d-…`): inactive, disabled. The v3 keeper
  `numo-future-feeds-v3@eurc-30nov26` untouched (active, enabled). Undo: `systemctl enable --now` (nothing needs it).
- Its relayer `0xEEa4…5321` swept to the backup relayer (tx `0x6e258e63…bd7d`; dust 0.0000013 left). Backup now
  0.001528 ETH. Dropped from `check_signer_balance.py` (`2d3622d`, installed on the box, hash-checked; one run: six
  wallets ok, no finding). `perp-pager.env` still lists it in `GAS_WATCH`, inert with the pager off.

## 2026-11-17 03:15–03:25 UTC: keeper-liveness alerts before Stage 3 (spec C6) (SSM, healthchecks.io)

- **Report age** (new): `check_report_age.py` + `numo-report-age.{service,timer}` (every minute, through
  `run-with-heartbeat.sh report-age`, reads via `RPC_SSM=/numo/keeper/rpc_url`). Pages (exit 3) when either stored
  Data Streams report on the EURC adapter is over 120 s old for two runs in a row. healthchecks.io `report-age`
  (`7101133c…`, 1 min / 3 min grace, created in the dashboard), ping URL at SSM `/numo/pager/heartbeats/report-age`.
  First run: reports 7 s old, ok. Proven locally against mainnet with the limit forced to 1 s: run 1 waits, run 2
  exits 3; a fresh read resets.
- **Hot-wallet gas pages** (`76d0c5a`, `a63006c`): `check_signer_balance.py` exits 3 (HIGH page) for a wallet under
  2 days, keeps the low-priority finding under 7, retries 429s and reads via `RPC_SSM`. Timer 6 h → 1 h (sed on the
  box timer); the unit gained `Environment=RPC_SSM=/numo/keeper/rpc_url`. healthchecks.io `signer-balance-alert` 6 h /
  1 h → 1 h / 30 min. Its first hourly run (03:23) exited 2 on a 429 for the vault and paged; fixed by the retry and
  the keyed read, re-run 03:24 succeeded. Backups `.bak-202611170323`, `.bak-202611170324`.
- **Backup relayer** for the v3 keeper: `0x0f79B47421fd21B1E4C39Ee717DF9A24d1A62F39`, key at SSM
  `/numo/feeds/forward_relayer_key_v3_eurc_backup` (`cast wallet new`, never printed). Switch: run-sheet.
- **Backup funded 0.0013 ETH** (owner: from existing wallets; laptop, `cast send`, each key checked first): engine
  keeper v2 0.0005 (tx `0xdc047642…9879`, keeps 0.00249), perp keeper 0.0003 (tx `0xbfd12669…8ace`, keeps 0.000205),
  executor 0.0005 via KMS (tx `0xb56bbf09…d7c8`, keeps 0.00208, floor 0.002). About 11 h of the keeper's burn: time to
  refund, not a full standby. No wallet had more to spare without shortening the expiry path.
- Open: the v2 EURC relayer `0xEEa4…5321` warns (0.000229 ETH, ~4.6 days at its watched 0.00005/day) after this
  morning's transfer; its keeper `numo-future-feeds-v2@eurc-30nov26` serves the retired v2 series.

## 2026-11-17: expiry keeper enabled; EURC v3 relayer topped up from the executor (owner's decisions)

- **`numo-future-feeds-v3@eurc-30nov26` enabled** (SSM `4dbc1cf7-…`): it was active but disabled, so a reboot before
  11-30 would have left the fixing without its keeper. No restart (PID 4159626 before and after). Undo:
  `systemctl disable` (not wanted before close-out).
- **Executor → v3 relayer 0.009 ETH** (laptop, `cast send --aws` with the executor's KMS key
  `…/2c640315-0897-4657-90fd-57946fcd40eb`, which derived `0xF68e…8703` before sending; tx `0x8ca87ce7…5044`). The
  executor keeps 0.002583 (floor 0.002; a settlement costs ~0.000001). Its nonce tracker takes the chain's pending count
  when higher, so this send cannot collide with its next settlement.
- v3 relayer now 0.032050 ETH, ~11 days at 0.0029/day (to ~11-28). **Still short ~0.011 ETH to expiry: outside ETH.**
- 03:17 UTC: the owner sent 0.011 ETH from `0xeabc…fbfca` (tx `0x557b1667…`). v3 relayer **0.043032 ETH, ~15 days
  (to ~12-02)**: past the expiry.

## 2026-11-17: feed signer topped up from three spare wallets (laptop, `cast send`)

Owner's instruction: fund from existing market-maker or relayer wallets. Every key checked against its address first.
- perp keeper `0xdE57…f18` (perp delisted) → feed signer 0.00049 (tx `0xc51404a7…80bc`); keeps 0.000505.
- v2 EURC relayer `0xEEa4…5321` (series retired; `numo-future-feeds-v2@eurc-30nov26` still active) → 0.0004
  (tx `0x1717f3c4…8121`); keeps 0.000229, ~10 days at its burn.
- book taker `0x3Fdf…a914` → 0.00017 (tx `0x8db74704…3778`).
- Feed signer now 0.008817 ETH, ~14 days at 0.00063/day (to ~12-01). The EURC v3 relayer (0.0231, ~8 days at
  0.0029/day, to ~11-24) is still short ~0.019 to expiry: only the executor (0.0116, KMS) or outside ETH can cover it.
- Found: `numo-future-feeds-v3@eurc-30nov26` (the series' expiry keeper) is active but **disabled**: it would not
  restart after a reboot.

## 2026-11-17 01:36–01:43 UTC: markets df70d1e: the settlement verifier (ECS)

- **What.** Each matcher fill recorded on the executor's broadcast is `settlement = 'pending'`; the matcher checks it
  every 15 s and marks it `confirmed` on a successful receipt, or voids it only on proof (a revert, its nonce used by
  another transaction, or no node, primary or fallback, aware of it 10 min after the broadcast). A void puts both orders
  back (a completed order is cancelled, `settlement_voided`), moves a future's reduce-only ledger back, moves the row
  to `trade_fills_voided` and posts `NUMO FILL VOIDED`. 9 DB-backed tests; 11 guards mutation-tested; 732 tests pass.
- **Deploy.** Migration 000025 first (`numo-exchange-migrate:56`, task `068a7b6d…`, exit 0, applied 01:38:13); then the
  markets and matcher task definitions with `markets:df70d1e726e1` through `with-matcher-mute.sh` (01:39:12–01:42:40;
  the plan touched only those two). Old matcher STOPPED, fresh heartbeat after. `settlement_verifier_started
  dropped_after=10m0s fallback=true` at 01:40:30. Rollback: `96974ae8e208`, in one apply.

## 2026-11-17 01:13–01:26 UTC: book-maker dead-man check (healthchecks.io, SSM, ECS)

- **Check.** healthchecks.io "book-maker" (`be5e8a4d…`), created in the dashboard (the API key in SSM is read-only):
  1 min period, 10 min grace, the project's email and Pushover integrations. Its ping URL is SSM
  `/numo/exchange/book_maker_heartbeat_url` (SecureString), read by the execution role (`secrets.tf`).
- **Code.** market-maker `3d77276d`: `ShouldBeat` pings, at most once a minute, only when a cycle leaves the book
  quoted (an update landed, a live spline unchanged, or the deliberate stop before last trade). An error, dry run, a
  cancel, or a spline held down by an unreadable or diverging feed sends nothing. Seven guards mutation-tested.
- **Deploy.** market-maker image `3d77276d2efa`, `MM_BOOK_HEARTBEAT_URL` on `market-maker-book` (apply from main;
  the plan touched its task definition, its service and the execution role's secret list). Old task stopped
  01:25:56; it cancelled its spline on SIGTERM and the new task re-quoted at 01:24:08 (~1 min unquoted).
- **Seen.** 01:25: check `up`, 2 pings, no heartbeat errors. Not yet seen: the check going down (needs ~11 min with
  the book unquoted).

## 2026-11-17 00:58–01:10 UTC: both settlement canaries green again (ECS deploy; box script and unit, SSM)

- **ECS canary (`settlement-canary-ecs`).** Every invariant check had "failed to run" on every pass since at least
  2026-11-16 23:57: each starts with the whitelist scan, `eth_getLogs` from block 0, which mainnet.base.org refuses
  ("request limit reached"); the keyed endpoint answers it. `d2c409c` sends that scan through `SEND_RPC_URL`.
  Proved locally against mainnet with production's canary env: ok, no failures. Deployed as `execution:d2c409c4ef25`
  (td :45 via one apply touching only execution-service, 00:58:39; old task stopped 01:02:48). First pass 01:02:26
  `ok: true`.
- **Box canary (`settlement-canary`).** Failed 8 of 67 runs in 6 h on 429s. `a549281` retries a 429 three times with
  backoff (installed 01:04; it had been `8c55551`'s copy, whose only difference from the repo's was a docstring line).
  That did not clear the wrapper check: its full-range scan is refused as such, and `8ec06ac` sends the two scans to
  `LOGS_RPC_SSM=/numo/keeper/rpc_url` (read with the box's role, never printed). With the scan working, the wrapper check
  read a 411,131.97 cNGN mismatch on the escrow `0x37c9…`: the unit's `OTHER_MANAGERS` lacked MarginEngine v2, which
  holds exactly that credit (SRM 5,000 + v1 0.000001 + v2 411,131.965849 = 416,131.965850 held). Added. Unit and
  script replaced from `8ec06ac` (sha-checked before; backups `.bak-202611170109`), daemon-reload, one run: ok.
- healthchecks.io at 01:10: both canaries `up`; `rebalance-check` `down` for a real reason (HyperFX has no USDC -> cNGN
  depth since 2026-11-16 21:15, as on 2026-11-11 for ~4 h).

## 2026-11-17 00:49 UTC: the perp pager removed (owner's decision) (SSM)

- **Done.** `systemctl disable --now numo-perp-pager.timer` (SSM `f91faae4-…`); the service is inactive, its last run
  00:48:56. The unit files, `/etc/numo/perp-pager.env` and the checkout `/home/ec2-user/exchange-pager` are left in
  place, inert. Undo: `systemctl enable --now numo-perp-pager.timer`.
- **Decided by the owner** after being told what only the pager pages for: matcher dead, a halted index feed, an
  unhealthy liquidation keeper (v1 and v2), insolvent accounts, SecurityModule payouts and coverage, the futures pools,
  options vol, and low gas on every hot wallet. Since 00:49 nothing pages for any of these. Still running: the Slack
  signer-balance alert (`numo-signer-balance-alert`, hot-wallet runway) and execution-service's settlement canary.
- **Its dead-man's switch** (healthchecks.io check "perp pager", `9f0b72ba…`) could not be paused: the API key in SSM
  (`/numo/pager/healthchecks_api_key`) is read-only (401 on pause). It went to grace at once and will alert until it
  is paused or deleted in the dashboard.
- Also off with it: `with-matcher-mute.sh`'s mute has nothing to mute, and the proposers whose gates read the pager's
  state file (margin engine v1/v2, perp enable; all landed) would now fail those gates.

## 2026-11-17 00:28–00:34 UTC: execution-service 917da47: HTTP refusals are not sends; sends via the keyed RPC

- **Fix** (`917da47`): `classifyBroadcastError` takes an HTTP 4xx (429, 401, 403) as a refusal: the nonce is given
  back, the send fails, the matcher records no fill. A 5xx stays "may be out", as a timeout. Three tests reproduce
  the incident (red on the old code); 186/186 pass. Transactions are prepared and broadcast through `SEND_RPC_URL`
  (`/numo/exchange/rpc_fallback_url`, keyed); reads stay on `RPC_URL`. Both wirings mutation-tested.
- **Deploy** (laptop, terraform 1.13.3 from main; the plan touched only execution-service's task definition and
  service): image `execution:917da470fdd4`, td :43, applied 00:28:35; the old task STOPPED by 00:33:52. No match was
  in flight (none on any market since 00:10). Rollback: `3fe2553fb2d2`, in one apply.
- **Not yet seen:** its first send through the keyed endpoint (`rpc_calls` host `base-mainnet.g.alchemy.com`,
  `eth_sendRawTransaction`), at the next match.

## 2026-11-17 00:05–00:10 UTC: execution-service restarted after a phantom fill (ECS, laptop)

- **What happened.** 2026-11-16 23:57:58 the matcher crossed taker order `future-0f8e737c-…` (2 EURC buy, EURC-30NOV26)
  with `mm:EURC-30NOV26:sell:3589746651976157`. execution-service answered `accepted: true` with tx
  `0xfb8ba3f26fd79dd82144bb2cda70c63f0bf5a7ca0627604e938cc214662f8e2e` in 395 ms (`WAIT_FOR_RECEIPT=false`), and the
  matcher recorded the fill. That transaction exists on no node (mined or pending, mainnet.base.org and Alchemy); the
  executor's nonce stayed 253 and Matching logged nothing. `totalPosition` is 0: the app's open interest of $0 is right
  and the trade on `/trades` and the chart never settled.
- **Why (from the code and the minute's rpc_calls).** `broadcast.ts` treats an `HttpRequestError` as "the transaction may
  be out": it resends twice, then confirms the nonce and returns the locally computed hash. viem raises that error for an
  HTTP 429 or 401, and in that minute `mainnet.base.org` answered the executor 429 x12 and 401 x2 around its three
  `eth_sendRawTransaction`s. The tracker then held 254 against the chain's 253, so every later settlement on every market
  would have gone out behind the gap and been recorded as filled.
- **Done.** `aws ecs update-service --force-new-deployment` on execution-service (td :42 unchanged), 00:05:57; old task
  `bfd006f2…` STOPPED by 00:09:35 (`wait-for-rollout.sh`). The new process reads its nonce from the chain (253). No other
  phantom fill on any market in between (checked `/trades` from 23:50).
- **Open.** The phantom fill's rows (both orders filled 2, one `trade_fills` row); the broadcast classification; the
  executor's send RPC.

## 2026-11-16 23:38 UTC: gas watch covers the MM wallet (OnchainBook maker) (SSM)

- `/etc/numo/perp-pager.env`: `GAS_WATCH` gains `book-maker=0x3448…B47B:0.0001` (backup `.bak-202611162338`).
- `/home/ec2-user/exchange/…/check_signer_balance.py` replaced with `140597e`'s (sha256 `895f6c6f…0dac`; it was
  `cc752fdf…dc70`, checked before the swap; backup `.bak-202611162338`): the wallet at 0.00005 ETH/day.
- **Why.** The wallet pays every `updateSplines`: ~0.00000042 ETH each with the L1 fee, measured over its first five, up
  to ~100 a day.
- **Proved.** Forced (`WARN_RUNWAY_DAYS=100`, webhook blanked): `NUMO HOT WALLET LOW GAS … OnchainBook maker (MM wallet)
  0.000408 ETH, ~8.2 days`. Normal: ok at ~8.2 days; the same run lists the feed signer (6.5 d) and the v3 relayer
  (6.7 d) as low, which the timer posts on its own. The pager's 23:39:35 run read `gas book-maker`, refused (HTTP 429)
  and held, as 5 of its 9 gas reads were: the public RPC (open).

## 2026-11-16 22:42–22:46 UTC: OnchainBook canary takes on mainnet: filled, flat, on the tape

- **Taker funded** from #56 (owner's approval: `CashAsset.withdraw(56, 50 USDC, taker)`, tx `0x6c4f5584…5d5b`; #56 keeps
  450). Taker account **#57** (owner `0x3Fdf…a914`, engine v2): 50 USDC deposited, the book's allowances granted.
- **Buy** 5 EURC from #57 (`book-take.ts`, fresh Data Streams reports attached): tx `0xef4d39b8…124c`, block 58,393,580,
  filled at 1.100656 against #56, fee 0.00275164, 1,225,482 gas. **Sell** 5 back: tx `0x6b90fa3b…8d91`, block
  58,393,651, at 1.100036, fee 0.00275009, 952,087 gas. (One earlier simulation reverted on reports newer than the
  head; resimulated, it passed. Nothing was sent.)
- **Checked:** #56 and #57 flat; #56 +0.0031 USDC (the spread), #57 −0.0086 (spread and fees); fee account 22 +0.00550181
  against 0.00550173 of fees (the rest is cash interest); `/trades?symbol=EURC-30NOV26` lists both as `source: book`
  at block time with their hashes, through the matcher's indexer.

## 2026-11-16 22:28–22:41 UTC: matcher indexes the book; canary taker created; a second spot-maker pause moved nothing

- **markets 96974ae** (`d77228f`): migration 000024 run first by hand (`numo-exchange-migrate:55`, task `f673734c…`,
  exit 0, "applied migration 000024_book_fills.up.sql" 22:30:49), then the markets and matcher task definitions with
  `ONCHAIN_BOOK_ADDRESS`/`ONCHAIN_BOOK_START_BLOCK` on the matcher, through `with-matcher-mute.sh` (22:31:53–22:35:44;
  the old matcher STOPPED, a fresh heartbeat after). `book_indexer` on `/health`: started at 58,358,412, caught up to
  20 blocks behind the head, no error.
- **Taker** `0x3Fdfc7c750750DcCc19DB31690b62EF0056Da914`, key in SSM `/numo/deploy/onchain_book_taker_key`, 0.0002 ETH
  from the feed signer (tx `0x7b04eb47…6fc4`). No USDC yet.
- **`market-maker-eurc` paused again** 22:38:06–22:40:09 for `withdraw-usdc 43 50000000`, which refused: the maker's
  quotes (300 s expiry) still rested on #43. Nothing was withdrawn (#43 still 2,826.22 USDC). Two-sided again by 22:40:48.

## 2026-11-16 21:47–22:27 UTC: book-maker on ECS; EURC-30NOV26 open on the OnchainBook

- **ECS `market-maker-book`** (infra `bd5ec07`, `b378fb9`, applied from main with terraform 1.13.3; each plan touched
  only this service): image `market-maker:b8974faa7020` (`/app/book-maker`), #56, curve `20@0,40@50`, half-spread
  300 ticks, `desired_count_market_maker_book = 1` in counts.auto.tfvars. On `mm_rpc_url` (publicnode) its first two
  starts set the curve and registered #56 but could not read either receipt ("archive request", 403) and exited;
  moved to `rpc_fallback_url` (keyed). Since 21:49:11 it quotes at +618 ticks; refreshed 22:19.
- **Enable** (`numo-onchain-book-enable`, box transient unit, `PYTHONUNBUFFERED=1`; SSM `fbeb4866-…`): MPCVault request
  `7f572b54-4557-413e-9373-5c9b61b3ea9a` proposed ~21:52 UTC. The unit gave up waiting ("not approved within the
  timeout") before the approval; `setMarketParams(1, …, enabled = true)` landed at 22:27 (tx `0x78161adc…43a3`). Read
  back: enabled, parity 22/22, 1 maker, 1 live spline. **EURC-30NOV26 is takeable on the OnchainBook.**
- Not yet: the test takes, and the matcher's indexer (`onchain_book_address`, start block 58,358,413).

## 2026-11-16 21:38–21:45 UTC: book-maker built on the box, started, refused its key, stopped (SSM)

- **`exchange-ops`** → `4eec6f7` (clean before), for `run-with-ssm-book-maker.sh`.
- **Go 1.24.13** in `/home/ec2-user/go1.24` (go.dev tarball, sha256 checked against go.dev's list); the box had no Go.
- **`/home/ec2-user/market-maker-book`**, a clone of numofx/market-maker detached at `d6c927a7`, with `book-maker` built
  there (sha256 `026da0c05a5ad64c…`).
- **`/etc/numo/book-maker.env`** and **`/etc/systemd/system/numo-book-maker.service`** installed from `4eec6f7`. Started
  21:41:59: the box's role may not read `/numo/exchange/mm_private_key` (only while `ops_box_mm_key_grant=true` is
  applied, `run-with-ssm-mm.sh`), the wrapper carried on with empty values (`export X="$(get …)"` masks a failed
  read), and the maker exited on `MM_RPC_URL is required`, restarting every 15 s. **Disabled and stopped at 21:45.**
  Nothing was sent: #56 has no curve, registration or spline.
- Left in place, inert: the env file, the disabled unit, the toolchain and the build. Undo: `rm` those four.
- Fixed in the repo the same hour: every `run-with-ssm*.sh` now stops on a failed required read (old: the command ran,
  exit 0; new: exit 254, shown with a missing parameter). The box's checkouts still carry the old wrappers.

## 2026-11-16 21:22–21:35 UTC: OnchainBook maker account #56 funded with 500 USDC from the spot maker's #43 (laptop)

- **#56 created** by the MM wallet `0x3448…B47B`, under engine v2 and held by the wallet itself, outside Matching (tx
  `0x482f03c3…e7c8`). The book's allowances were granted on it, future and cash both ways at uint max (tx
  `0xec816e1d…9b38`).
- **`market-maker-eurc` paused** (ECS desired count 1 → 0 at 21:24:56; task `a6708256…` STOPPED 21:25:48, via
  `wait-for-rollout.sh`) so no EURC-USDC quote rested on #43. `migrate-spot-mm.ts move-usdc 43 56 500000000` (new: a
  destination the wallet holds itself) withdrew 500 USDC through `/withdrawals` (tx `0xaa1f8c68…a5b0`, block 58,370,524)
  and deposited it to #56 (tx `0xb6705860…9474`). Restored to 1 at 21:28:10; its new task quoted again by about 21:30
  (3 bids, 4 asks). **EURC-USDC spot had no quotes for about 5 minutes.** Same task definition (`:5`): no drift.
- After: #43 holds 2,826 USDC and 3,272 EURC; #56 holds 500 USDC. The MM wallet keeps 0.00041 ETH for gas.
- The book-maker's preflight against mainnet passes in dry run (owner, engine, allowlist, allowances, feeds); it would
  quote at +618 ticks with a 300-tick half-spread. Nothing sent.

## 2026-11-16 20:50–21:16 UTC: OnchainBook setup batch landed (box, `exchange-ops` → `b8998d7`)

- **`/home/ec2-user/exchange-ops`** fetched and detached at `b8998d7` (was `e4b01d0a`), clean before and after. The
  proposer and the three `ONCHAIN_BOOK*.json` matched the laptop's sha256. The self-test's ABI step needs `out/`, which
  the box lacks; the full self-test passed on the laptop at the same commit. The dry run passed nominated, series and
  parity (22/22). SSM `98337ee0-…`, `6095de3d-…`.
- **`numo-onchain-book-setup`**, a transient unit (`systemd-run --uid=ec2-user`), ran `run-with-ssm-mark.sh
  propose_onchain_book_batch.py book-setup --propose` from 20:50 UTC (SSM `10e82853-…`). Both actions approved by hand in
  MPCVault: `acceptOwnership()` landed (tx `0x86027aca…db26`) and then `setMakerAllowed(0x3448…B47B, true)` (tx
  `0xd4868d9f…9088`, MPCVault `3b274894-…`) by 21:15:37. The unit exited 0 and is gone.
- Read back: owner the vault, no pending owner, maker allowed. Market 1 still disabled.
- The unit's log printed nothing until it exited (Python buffers stdout without a tty); run the next one with
  `PYTHONUNBUFFERED=1` to see each request as it is made.
- **Undo** the checkout: `git -C /home/ec2-user/exchange-ops checkout --detach e4b01d0a`.

## 2026-11-16 ~20:45 UTC: OnchainBook deployed closed (laptop, `forge script`); its deployer key created in SSM

Not a box change; recorded here with the other hand actions of the day.

- **Key.** `/numo/deploy/onchain_book_deployer_key` (SecureString) created from `cast wallet new`, never printed; it
  derives `0xd58aa0DD4129B220Df84328f901eC49AE3dbb0b2`. Single use: the deploy script refuses a key with history.
- **Funded** 0.0002 ETH from the feed signer `0xC9F1…0FDc` (tx `0x1aff4cb4…37a9`), which keeps ~0.0081 (~13 days).
- **Deployed** `deploy-onchain-book.s.sol` at `ac3e4b1`: book `0x8Fc63DcB3a173aAF5d2de0F42648D908A519d456`, five
  transactions from block 58,358,413 (`0xa3bc740a…2baa` the create). Read back: owner the deployer, pending owner the
  vault, market 1 disabled, maker not allowed; the proposer's setup dry run passes nominated, series and parity (22/22).
  The deployer keeps 0.00017 ETH.
- **Next:** the setup batch (acceptOwnership, setMakerAllowed(0x3448…B47B)), proposed from the box; digests
  `0xef72df8a…5e3c` and `0x2434e4c5…65df`.

## 2026-11-16 20:07 UTC: pager fixed (block rate, held pages) and perp keeper floor 0.0005 (box-39/40, SSM)

`check_perp_pager.py` replaced with `main`'s `e950653` (sha256 `bf42ee41…4f33`, checked on the box before the swap; it
had been `110bb12`'s, `e6b80875…073c`), and `KEEPER_GAS_FLOOR_ETH=0.0005` appended to `/etc/numo/perp-pager.env`.
Backups: `check_perp_pager.py.bak-202611162007`, `perp-pager.env.bak-202611162007`.

- **Why.** The pager assumed 2 s blocks (43,200 a day); Base's are 0.2 s, so its "last day" was 2.4 h and every burn
  read a tenth of its size (the v3 relayer 0.0003/day against 0.0021 measured over a real day), and the 7-day
  warning could not fire. It now times the chain each run. Separately, any read refused with HTTP 429 dropped its
  condition, which resolved an open page and re-paged it a minute later (the `low-gas-keeper` flapping); a failed read
  now holds its pages. The perp keeper (delisted perp, ~0 burn, 0.000995 ETH) paged under the 0.002 default.
- **Seen after.** The first run on the new script read and held, with no page sent; it finished `ok: 0 active`.
- **Open.** The pager reads `mainnet.base.org` (`/numo/feeds/rpc_url`), which refused about 6 reads a run (2,047 429s
  in the 6 h to 20:10 UTC). Pointing `run-with-ssm-pager.sh` at `/numo/keeper/rpc_url` (Alchemy, the keepers') was
  prepared and not applied: awaiting a decision.

## 2026-11-16 ~15:05 UTC: EURC v3 relayer topped up to 0.02445 ETH from three wallets (laptop, `cast send`)

The owner said to fund it from the market maker's or the relayers' wallets. Each sends what it can spare through the
30 Nov expiry while staying above its own alert floor; keys from SSM into a subshell, each address checked first.

- 0.0077 ETH from the feed signer `0xC9F1…0FDc` (`/numo/feeds/relayer_key`), left 0.00846: ~13 days at its measured
  0.00063 ETH/day, just over `check_signer_balance.py`'s 7-day line (0.0084), which it crosses within a day. Tx
  `0x075cad6437ed9c78a501f7f87e1957eda76a3941442ad132f1eae9c091afc00e`
- 0.0015 ETH from the market maker `0x3448…B47B` (`/numo/exchange/mm_private_key`), left 0.00042. Tx
  `0x38a35ff65a186c2c8be10adc4ef837930fb6b12607e57a5ba67506ca10358cc4`
- 0.0015 ETH from the v2 cNGN forward relayer `0x3ACe…763f` (`forward_relayer_key_v2_cngn`), left 0.00039 at
  ~0.00002 ETH/day, over its 0.0003 pager floor to expiry. Tx
  `0xe378247a8d24401f333854cfe1fb4bdf6ab58af5a066b26c5f38c46dbc3335e3`
- The v3 relayer holds 0.02445 ETH: ~8.4 days at 0.0029 ETH/day, to about 2026-11-24. Expiry needs ~0.015 ETH more,
  which no hot wallet can spare: it must come from outside. Untouched: the vol relayer (needs its 0.0024 to expiry),
  the executor, both keepers.

## 2026-11-16 11:32–14:50 UTC: EURC v3 relayer ran dry, index stale 3 h 18 m; refunded from two relayers (laptop, `cast send`)

- **What happened.** The EURC v3 keeper's relayer `0x0AbA…12e5` (`/numo/feeds/forward_relayer_key_v3_eurc`) was
  funded with 0.002 ETH on 2026-11-15 and posts reports every 20 s: ~2,700 tx and ~0.0029 ETH a day, 20x the feed
  signer. It emptied at nonce 1926; the last stored reports are from 11:31:59 UTC, after which `EurcIndexFeed.getSpot()`
  reverted (`EIF_Stale`), so EURC-30NOV26 fills and marks stopped. Market 2's margin reads the Chainlink push feed and
  kept working. Nothing paged: the relayer was in neither `GAS_WATCH` nor `check_signer_balance.py`.
- **Found** by the OnchainBook proposer's enable dry run on an anvil fork (its index gate), not by any alert.
- **Refunded** by the owner's instruction ("move funds from an existing relayer wallet or market maker wallet"). Keys
  read from SSM into a subshell, never printed; each key's address checked against its wallet before sending.
  - 0.001855952828912066 ETH, all but 0.00002, from the canary relayer `0x35ee…bDD5`
    (`forward_relayer_key_v3_eurc_canary`, idle since the canary's keeper was disabled), tx
    `0x5dc806565da32aaec2bbdd4eff1873333b1b9a78f021eabc16689a6c6e409b76`
  - 0.012 ETH from the feed signer `0xC9F1…0FDc` (`relayer_key`; 0.0282 -> 0.0162, ~25 days at its measured 0.00063
    ETH/day), tx `0x4c1d236bf2bc9ed5cdf7f88f03284fe5c459e799084de0c9836c9a96de2de445`
  - The v3 relayer holds 0.01386 ETH, ~4.8 days. The keeper resumed by itself (nonce 1927 by 14:50 UTC);
    `getSpot()` read 1.10108. The market maker's wallet (0.0019 ETH) was left alone.
- **Watching (`d9101f8`), on the box 14:54 UTC by the owner's go-ahead.** SSM `dc130cab` (box-37), each file backed
  up as `.bak-202611161454` beside it:
  - `/etc/numo/perp-pager.env`: `,eurc-v3-relayer=0x0AbAac33E5ab7E62dED100Be465032A3636b12e5:0.01` appended to
    `GAS_WATCH`, nothing else (as on 2026-11-02, not a copy of the repo's file). The 14:55:06 run reads
    `gas eurc-v3-relayer: 0.01385 ETH ... floor 0.01`.
  - `/home/ec2-user/exchange/contracts/risk-core/scripts/ops/check_signer_balance.py` replaced by `d9101f8`'s (sha256
    `cc752fdf…dc70`), `--self-test` passed on the box's Python first. The box's env sets nothing it reads any more.
  - Proved (SSM `484f1fe7`, box-38): `numo-signer-balance-alert` started by hand posted `NUMO HOT WALLET LOW GAS` for
    the v3 relayer (~4.0 days, under the 7-day threshold) and `ok` for the other five. It repeats every 6 h until the
    relayer holds over ~0.0245 ETH.
  - Seen, not changed: the pager's standing `low-gas-keeper` (the perp keeper `0xdE57…3f18`, 0.00100 ETH against a
    0.002 floor, since it funded the v3 deploy on 2026-11-15; the perp is delisted) and one HTTP 429 on a gas read.
  - **Undo.** `cp -p` each `.bak-202611161454` back over its file.

## 2026-11-15 20:49–21:30 UTC: EURC v3 canary drilled, settled, closed out; canary keeper disabled

- 20:49:03 `systemctl stop numo-future-feeds-v3@eurc-canary`, 20:53:34 `start` (the drill's outage, spec A1.4).
- After settlement and close-out, `systemctl disable --now numo-future-feeds-v3@eurc-canary`. The unit is inactive and
  disabled; `/etc/numo/future-feeds-v3-eurc-canary.env` and the relayer `forward_relayer_key_v3_eurc_canary` stay, so
  nothing reads them. `numo-future-feeds-v3@eurc-30nov26` is still active.
- Laptop, `cast send`: the canary key withdrew 54 and 55 (301.304433 + 298.695566 USDC) to the engine keeper wallet
  `0x753f…f83b`, which re-deposited 599.999999 USDC into #38 (approve `0x36ce40f3…`, deposit `0x315461f4…`).

## 2026-11-15 ~19:00 UTC: EURC futures maker quoting v3

Laptop, terraform 1.13.3: `eurc-v3-mm.plan` from `8649d1c`. The EURC v2 maker's inventory went 9 → 6 and skew-full-at
6 → 4, because the v3 IM is 15% (about $165 a contract) against #40's $1,300 at 0.8 IM usage. The image is unchanged.
`counts.auto.tfvars` (gitignored, the laptop's copy) moved `desired_count_market_maker_future_v2.eurc` from 0 to 1.
The cNGN maker and the matcher were untouched. The maker resolves `EURC-30NOV26` through markets-service to
`0xc350…b227`. It quotes 10 a side from #40; `/book?symbol=EURC-30NOV26` read best 1.09990 / 1.10166, 116 EURC each.

## 2026-11-15 ~18:50 UTC: EURC-30NOV26 v3 open to public trading, before the canary settles

By the owner's decision: the canary's 21:00 expiry would have held the listing until about 21:20, and it now runs
unattended, with the 15 days to Nov 30 to fix anything it finds. Terraform 1.13.3 applied `eurc-v3-open.plan` from
`88e0291` through `with-matcher-mute.sh`. Only `close_only` changed, true to false, on the v3 entry of the markets and
matcher task definitions. The old matcher STOPPED, the new one was matching, and both rollouts COMPLETED. The live
matcher task definition reads `close_only False` for `0xC350…B227`. The EURC futures maker is still at 0 replicas.

## 2026-11-15 17:21–18:05 UTC: EURC v3 setup and enable landed; markets lists it close-only; canary open

- **Setup** (`numo-eurc-v3-setup`, approved by hand in MPCVault). All four actions landed, the last at about 17:45 UTC.
  Market 2's future slot (`assetMap(2, Future=4)`) now holds `0xC350…B227`, replacing the retired v2 series.
  - The first rerun stopped on the deployer-audit parity gate: the box ran `33ad5a2`, which predates `21dc423`'s
    multi-deployer audit.
  - One rerun stopped on the same gate after a stale RPC read, and passed on the next. A missed read counts as
    unaudited, which fails closed.
- **Enable** (`numo-eurc-v3-enable`). Action 0, `setDatedFutureAsset`, landed (tx `0xf254d0d9…0ddf`). The unit then
  stopped: its postconditions were in the pre-`2156c49` order, cap first, so the landed registration read back as
  pending. A rerun from `af343f1` proposed action 0 again (MPCVault request `3f2d8b6c`, **declined**).
  - Fixed in `e4b01d0`: postconditions follow the action order, and the self-test pins each one to its action.
  - Action 1, `setTotalPositionCap(engineV2, uint max)`, landed (tx `0xf0ecf621…e538`). The series is open on chain,
    uncapped.
- **Markets** (laptop, terraform 1.13.3, `eurc-v3.plan` from `4e5302f` via `with-matcher-mute.sh`, run by the owner):
  `FUTURE_SERIES` swaps the retired v2 EURC entry for v3 with `close_only: true`. Only the markets and matcher task
  definitions changed. The old matcher STOPPED and the new one was matching. `/markets` lists EURC-30NOV26 at
  `0xc350…b227` with the fill band enforced (1.0669–1.1329).
- **`/etc/numo/engine-keeper-v2.env`**: `FUTURE` swaps `0x6Ff7…7744` for `0xC350…B227` (backup
  `.bak-20261115-eurcv3`). Restarted; `/health` lists both futures, and its first pass was OK.
- **`/etc/numo/perp-pager.env`**: `FUTURE_V2_ARTIFACTS` dropped `EURC_FUTURE_V2.json` (the retired series is off the
  engine, with no open interest), to cut the pager's RPC load. It now holds MARGIN_ENGINE_V2 and EURC_FUTURE_V3.
- **`exchange-ops`**: moved through `8423748`, `af343f1` and `e4b01d0`, detached.
- **Canary open** (laptop, `canary-eurc-v3.s.sol open()`): accounts #54 (long) and #55 (short) belong to
  `0x1b01…9Ca7`, with 300 USDC each and one contract at 1.09997 on series `1794776400`
  (`EURC_FUTURE_V3_CANARY.json`). The drill stops `numo-future-feeds-v3@eurc-canary` from 20:49:00 to 20:53:30 UTC.

## 2026-11-15 17:01–17:20 UTC: EURC-30NOV26 v3 deployed with its canary; keepers live, pager reads it

Deployed `c208858` from the laptop by the single-use deployer `0xea4B…d693`: future `0xC350243c1d07Ff598770ECe12323799D2EFbB227`,
index feed `0x5658…24D9`, adapter `0x9E9a…FfEB`, forward feed `0x401D…d8e4`. Nominated to the vault, with a cap of 0.
Canary `1794776400` (21:00 UTC) on 15 min / 2 min / 5 min, production `1796050800` on 30 min / 2 min / 1 h, both read
back from the chain. After the deploy the deployer sent 0.0012 ETH to the canary relayer (tx `0xfd9aecc6…7134`), listed
in `DEPLOYER_AUDITED_TXS.json`.

- **`exchange-ops`** moved `c10d1b88` → `62e321e` → `33ad5a2`, detached and clean. The setup dry run on the box matched
  the laptop's digests.
- **`numo-eurc-v3-setup`** (transient unit, `run-with-ssm-mark.sh propose_eurc_future_v3_batch.py eurc-v3-setup
  --propose`): action 0 was proposed at 17:08 UTC (request `6a910e60`) and is awaiting approval.
- **`/home/ec2-user/exchange-future-v3`** (new clone at `eab54d3`, perp-feeds and kms-signer built) runs the new
  `numo-future-feeds-v3@.service`, so `exchange-future-v2` (840526a, the v2 keepers) is untouched.
  - `/etc/numo/future-feeds-v3-eurc-30nov26.env` and `-eurc-canary.env` come from the repo.
  - The first start failed the keeper's cadence check (20 s refresh + 2 × 60 s tick > 60 s index age). The tick is now
    15 s in the repo (`33ad5a2`) and on the box.
  - They ran with `DRY_RUN=true` first, then `false` (backups `.bak-dryrun`). Both instances post Data Streams reports
    through Chainlink's VerifierProxy on mainnet (first tx `0xadc16809…76b4`, about 74k gas, 4.4e-7 ETH). The index
    reads 1.0996.
- **Pager**: `exchange-pager` moved `5cae8100` → `21dc423` (the v3 pager work, `110bb12`). `/etc/numo/perp-pager.env`
  `FUTURE_V2_ARTIFACTS` gained `EURC_FUTURE_V3.json` (backup `.bak-20261115-eurcv3`). The pager's RPC was already
  rate-limited (429) every minute before the keepers started (16:36 onward), so some runs read nothing.

## 2026-11-15: EURC v3 canary funded from keeper wallets (laptop, `cast send`)

The owner said to fund the v3 deploy and canary from the market maker's or keepers' funds. The market maker's accounts
are held by Matching and back live quotes, so they were left alone. Keys were read from SSM into a subshell, never
printed.

- **ETH from the perp liquidation keeper** (`/numo/keeper/keeper_key`, `0xdE57…3f18`; the perp has been delisted since
  2026-10-21). It keeps 0.000995 ETH.
  - 0.0015 to the v3 deployer `0xea4B76158a5463Dd433B5e7caBca3939BeE7d693` (tx `0x805e5839…e239`)
  - 0.002 to the v3 relayer `0x0AbA…12e5` (tx `0xd83c585a…17ea`)
  - 0.001 to the canary relayer `0x35ee…bDD5` (tx `0xf7770019…d85d`)
  - 0.0005 to the canary trader `0x1b01341B8dCaF986247e371a8D5c742F826d9Ca7` (tx `0xf5825d70…72be`)
- **600 USDC lent by the engine keeper** (account #38, owner `0x753f…f83b`): `CashAsset.withdraw(38, 600e6, canary
  trader)`, tx `0x5cc5b3701593667bf882590b195630e67c9f7c2d409ecfbb2cee89f7f56c27a1`. Account #38's cash went from
  $5,000 to $4,400, which still covers cNGN-30NOV26's $2,160 side at its cap. **To be returned:** the canary's
  `closeOut()` runs with `RETURN_TO=0x753f…f83b`, and the keeper re-deposits the USDC to #38.

## 2026-11-15: EURC v3 keeper relayers created in SSM (laptop)

For the v3 pilot's two keeper instances (spec A1.4): EURC-30NOV26 v3 and its mainnet canary each get a relayer of
their own, since two keepers on one relayer race for nonces. Each was piped from `cast wallet new` into SSM as a
SecureString; the key was never printed.

- `/numo/feeds/forward_relayer_key_v3_eurc`: relayer `0x0AbAac33E5ab7E62dED100Be465032A3636b12e5`
- `/numo/feeds/forward_relayer_key_v3_eurc_canary`: relayer `0x35eeBd8E94F9c4a6b13EBa9fD676f7d0fDa8bDD5`

Both are unfunded so far, no keeper reads them yet, and nothing on the box changed.

## 2026-11-15: ops box may read /numo/data-streams (terraform apply of `38c8806`)

- **`terraform apply`** (1.13.3) from `main` at `38c8806`, a saved plan: `1 to add, 1 to change, 0 to destroy`:
  `aws_iam_role_policy.ops_box_ssm_read["data-streams"]` created (read `/numo/data-streams/*`), and
  `ops_box_ssm_deny_outside_paths` gained that path in its `NotResource`. Nothing else changed.
- **Read back from the box** (SSM `443f7f5a`): `/numo/data-streams/username` and `/hmac_secret` readable (lengths 36
  and 128; values not printed); `/numo/exchange/database_url` still `AccessDeniedException`.
- **Used by:** `run-with-ssm-forward.sh` for a unit with `FUTURE_VERSION=v3` only. No such unit exists yet.
- **Undo:** remove `data-streams` from `ops_box_ssm_paths` and apply.

## 2026-11-15 ~04:57–05:00 UTC: EURC depth monitor sampling again, judged against the live cap

- **`exchange-eurc-depth`** moved `8c5e60a6` → `acd87d4` (SSM `b567966d`), clean. `acd87d4`: `depth.py --once` no
  longer refuses after the 7-day window (it had sampled nothing since 2026-10-28), and its stress check reads v2's
  cap on the EURC escrow at each reading instead of the 40,000 constant; a `cap_eurc` column is appended.
- **CSV backed up** to `/home/ec2-user/numo-eurc-depth.csv.bak-20261115` before the first run under the new columns.
- **One run started by hand** (`systemctl start numo-eurc-depth.service`): block 57641858, sell 10,572 EURC, buy
  167,135 USDC within 2%, cap 5,000; stress `unknown`, and `stress_alerted` moved `hold` → `unknown`, which it does
  only once the webhook accepted the alert: the alert path delivered. The timer runs it at 00:00 and 12:00 UTC.
- **Still broken:** the largest-LP read (`eth_getLogs` on the main pool's gauge) fails on the box RPC's 429s even with
  the saved scan state, so the verdict cannot be `pass` until it is fixed.
- **Undo:** `git -C /home/ec2-user/exchange-eurc-depth checkout --detach 8c5e60a6` and restore the CSV backup.

## 2026-11-15 04:53:59 UTC: EURC spot cap on v2 lowered 18,000 → 5,000 EURC

The 2% sell depth on Base had fallen to 10,665 EURC (measurement 1, `docs/eurc-usdc-futures-spec.md` A6.0a), so the
18,000 cap failed its own gate (50% of that depth, about 5,300). 3,281.44 EURC was held (#43, the EURC maker), under 5,000.

- **`exchange-ops`** `e77f336` → `c10d1b8` (SSM `acd75f01`), clean, fast-forward. `c10d1b8` makes `eurc-cap`'s depth
  gate hold a rise only: the largest-LP read was unreadable (RPC 429 on `eth_getLogs`), which held the decrease.
- **Depth reading** (SSM `50971e19`): `depth.py --once` from `exchange-eurc-depth` with the provider RPC, a scratch
  CSV and no webhook, so no alert was sent.
- **`numo-eurc-cap-lower`** (transient unit, `run-with-ssm-mark.sh python3 propose_margin_engine_v2_batch.py eurc-cap
  --eurc 5000 --propose`): custody, cap, depth stress (informational, lowers) and keeper inventory PASS; request
  `db0ecbfd`, digest `0x8c2504ab…c45c24` (recomputed with `cast`), approved by hand in MPCVault; tx `0x0dae9bc1…85fa`,
  block 57640321. Reads back 5,000e18.
- **Not fixed:** the depth timer stopped at its 7-day window on 2026-10-28 and has not sampled since; the largest-LP
  read fails on the box's RPC (429).
- **Undo:** `eurc-cap --eurc 18000` (a rise: held by the depth gate as it should be).

## 2026-11-15 03:53–03:59 UTC: old EURC-30NOV26 (v2) retired: close-only, then off Matching

The v2 series `0x6Ff7…7744` was open (cap 18) with zero open interest and no pending VM on any of accounts 1–53. Its
retirement frees market 2's one future slot for the new FutureAsset series (`docs/eurc-usdc-futures-spec.md`, A1.1).

- **`exchange-ops`** moved `4ef4702` → `efa32ef` → `5431271` → `e77f336`, detached, fast-forward, clean each time (SSM
  `8f257a19`, `064ebce6`, `7cb38a48`). Nothing runs from this checkout: the pager runs from `exchange-pager`, the feeds
  and keeper from `exchange-future-v2` and `exchange-perp`.
- **Dry run on the box** (`propose_eurc_future_v2_batch.py eurc-future-retire`): custody, oi (0) and vm (none) PASS;
  digests `0xa24b6fb0…f008b` and `0x700001b6…0f008b`, the laptop's and `cast`'s. The first dry run died on HTTP 429
  in the per-account VM scan: paced and retried in `5431271`.
- **`numo-eurc-future-retire`** (transient unit, `run-with-ssm-mark.sh python3 propose_eurc_future_v2_batch.py
  eurc-future-retire --propose`), approved by hand in MPCVault:
  - (0) `eurcFuture.setTotalPositionCap(engineV2, 0)` landed in block 57622309, tx `0x2b9f57b3…fb5f`, 03:53:57 UTC. The unit then died
    on HTTP 429 fetching the receipt; the shared `rpc()` in `propose_cngn_spot_batch.py` now retries 429 (`e77f336`).
  - (1) rerun from `e77f336`: (0) skipped as landed, gates re-read (oi 0), request `7daaecbf`;
    `tradeModule.setDatedFutureAsset(eurcFuture, false)` landed in block 57623890, tx `0xd662e005…efe3`, 03:59:13 UTC.
    The unit exited `done`.
- **After:** cap 0, off the TradeModule, open interest 0; still market 2's future until the new series' deploy
  replaces it. The EURC-30NOV26 maker (#40) was still quoting at 04:0x UTC (10 a side); its fills can no longer
  execute.
- **Maker stopped (04:10 UTC):** `counts.auto.tfvars` (gitignored, the laptop's copy) `desired_count_market_maker_future_v2.eurc` 1 → 0, `terraform
  apply` (1.13.3) of a saved plan from `main`: `0 to add, 1 to change, 0 to destroy`, the one change
  `aws_ecs_service.market_maker_future_v2["eurc"].desired_count 1 -> 0`. Task `4e9bae50…` read `lastStatus RUNNING`
  after the apply and STOPPED at 04:10:24 (`wait-for-rollout.sh wait`). Its last 20 quotes were left to expire.
- **Not yet done, deliberately:** markets-service listing, the forward publisher (`numo-future-feeds-v2@eurc-30nov26`),
  and the pager's and keeper's EURC entries stay until the Stage 1 cutover swaps each to the new series in one step.
- **Not swept:** a dozen other ops scripts carry their own `rpc()` without the 429 retry (older proposers and the
  checkers).
- **Undo:** the vault can restore both (`setTotalPositionCap(v2, 18e18)`, `setDatedFutureAsset(future, true)`).

## 2026-11-02 ~03:20–03:45 UTC: options maker account #44 opened and funded from #43; maker started in dry run

Under the MM-key grant (`terraform apply -var ops_box_mm_key_grant=true` from `aab44b8`, which also created
`market-maker-options` at 0 replicas). Each step by SSM from the laptop, as ec2-user in `/home/ec2-user/exchange-perp`
(at `af584bc`, bundle unchanged), through `run-with-ssm-mm.sh`:

- **EURC-USDC spot maker stopped** (counts.auto.tfvars `desired_count_market_maker_eurc` 0, applied with the grant
  kept): its task STOPPED 03:22:59 UTC; its quotes expired and the book was empty at 03:29 before anything moved.
- **`engine-account 50000 --market=cNGN-30NOV26`:** the first `--execute` (SSM `e2f0e6f0`) approved (`0xee79b51d…`,
  block 53400490) and then failed estimating the create on a node that had not yet seen the approval: nothing sent,
  nonce 65 unused, allowance 50,000 confirmed on chain. The rerun (SSM `53045086`) opened **#44** under the v2
  engine, the MM's in Matching (approve `0xfff468c4…`, create `0x603e928e…`, block 53400565), 0.05 USDC.
- **`move-usdc 43 44 1000000000`** (SSM `fcee89e6`): withdraw `0x953afdbe…` (block 53400593), approve `0x87e4bc9c…`,
  deposit `0xa2a744cb…` (block 53400596). Read back: #43 cash 3,326.22, #44 cash 1,000.05 (IM surplus 1,000.05).
- **Closing apply from `6ecbaca`:** grant revoked (from the box, `GetParameter` on `/numo/exchange/mm_private_key`
  is AccessDenied), EURC-USDC maker back at 1 (quoting from #43 again), `market-maker-options` at 1 on #44 with
  `MM_DRY_RUN=true` (td :2; ten strikes priced, quotes logged, no order from #44 on the venue), execution td :40 with
  #44 added to the settlement canary. Execution was down 03:37:55–03:39:27 UTC (stop before start).
- **Found:** the settlement canary had been red since 2026-11-01 00:31 UTC on #32's value floor (#32 retired and
  emptied 2026-10-31), alerting every 30 checks for 27 hours. #32 leaves the canary while its maker is stopped
  (ecs.tf `canary_accounts`), applied separately.
- **Canary fix applied** from `8aa3e81` (execution td :41; down 03:52:39–03:54:04 UTC). From the new task's own stream
  (`b0059627…`): `ok: true`, no failures of any kind, accounts 42,43,39,40,44. **No recovery alert was sent**: the
  failure streak lived in the old process, and the new one only announced its start, so the alert channel's last word
  on this is still "failing" — resolve it there by hand. The same gap CLAUDE.md records ("a recovery message that never
  fired because the fix was a redeploy"); not fixed here.
- **Options maker live** from `7273774` (`mm_options_dry_run` false, td :3; dry-run task gone 04:10:45 UTC). On the
  venue at 04:12: one bid and one ask of 100k cNGN from #44 on each of the ten strikes (ATM put 0.0000289 / 0.0000338).
  First 3.3 min of the live task's own stream: 39 placements (20 initial, 19 replacing quotes that drifted 5 bps),
  19 cancels all `stale_or_wrong`, no warning or error; #44 IM surplus 1,000.05 (no fill yet).

## 2026-11-02 01:49 UTC: cNGN options OPEN (cngn-options-enable landed)

- **`numo-cngn-options-enable`** (transient unit, `run-with-ssm-mark.sh python3 propose_cngn_options_v2_batch.py
  cngn-options-enable --propose`, from `exchange-ops` at `4ef4702`), started by SSM `c9ff51f5` (Robert, from the laptop):
  one MPCVault request, `64028aec`, digest `0x10920ad0…0602`, approved by hand; the unit exited `done`.
- **On chain:** `OptionAsset(0xA6a0…3821).totalPositionCap(engine v2) = 2,000,000e18` from 01:49:07 UTC (block
  ~53397400), read through an Alchemy RPC.
- **After:** `/v1/markets` shows all ten `cNGN-30NOV26-…` strikes `trading_open: true`. The keeper passes clean
  (nothing to settle); the pager's next run read `cap 2,000,000, open 0 cNGN; vol confidence 1.00`, 0 active, so its
  `vol-stale` page is now armed. Nothing on the box changed but the transient unit.
- **To close again:** a vault `setTotalPositionCap(engine v2, 0)` on the option stops new opening risk without trapping
  holders (closing trades reduce |position|).

## 2026-11-02: cngn-options-enable dry run; `exchange-ops` → `4ef4702` after auditing the deployer's wallet swaps

- **The first dry run failed parity** (SSM `5b21aea6`, eleven gates PASS): the deployer `0x971C…2e9c` had sent 3
  unaudited transactions. Found through an Alchemy RPC (the public one and Blockscout refused): Robert's own wallet swaps
  at 01:16 UTC, confirmed by him. Nonce 62 `0x82d5cdee…ab22`, an EIP-7702 type-4 tx that delegated the deployer's account
  to `0x63c0c19a…e32b` (MetaMask's delegator) and swapped 15,000 cNGN for 10.920393 USDC; nonce 63, used by that
  authorization (no transaction of its own); nonce 64 `0x11b03242…bd43`, 20.920393 USDC for 0.009154 ETH. The deployer now
  carries code `0xef0100 63c0c19a…`: it still signs ordinary transactions, so it can still deploy, but it is no longer a
  plain EOA. It owns nothing on chain.
- **`4ef4702`:** the parity gate (`propose_margin_engine_v2_batch.unaudited_deployer_txs`, shared by the v2, EURC and
  options proposers) accepts a nonce used by an EIP-7702 authorization only when an entry flagged `authorization` names a
  type-4 transaction from the deployer whose authorization at exactly that nonce recovers, from its own signature, to the
  deployer. Nonces 62–64 audited. All three gates count 0 on chain; without the flag nonce 63 still counts 1.
- **`exchange-ops`** `0586889` → `4ef4702` by SSM `d4be50a2` (Robert; clean, no proposal unit running, fast-forward),
  then the dry run: all twelve gates PASS (custody, engine, market1, venue, series, vol, sm $109 of the $120 left beside
  both futures, pager, keeper, fills, rfq, parity). One action, `cngnOption.setTotalPositionCap(engineV2, 2,000,000e18)`,
  digest `0x10920ad0…0602`. Nothing proposed.

## 2026-11-02 01:25 UTC: engine keeper v2 settles cNGN options, on its own checkout; pager on `5cae810`

- **Why its own checkout.** `numo-engine-keeper-v2` ran from `/home/ec2-user/exchange-future-v2` at `840526a`, without
  the `OPTION` sweep (exchange `370a063`), and that checkout is also the two v2 forward keepers': moving it and running
  `pnpm install` there would change their code on their next restart. 840526a..5cae810 changes only that commit in
  perp-keeper and nothing in `pnpm-lock.yaml`.
- **SSM `c4bd5c13`** (Robert, from the laptop; refused unless no new checkout, no drop-in, `OPTION` unset, the keeper
  healthy, the pager checkout clean and its move a fast-forward):
  - `/home/ec2-user/exchange-keeper-v2` cloned at `5cae810` (detached); `pnpm install --frozen-lockfile --filter
    perp-keeper...`, `@numo/kms-signer` and `perp-keeper` built.
  - `/etc/numo/engine-keeper-v2.env` (backup `.bak-202611020125`): `OPTION=0xA6a05dC25127CecbC048C7e6CBE35e1c8e503821`
    and `OPTION_SETTLE_WARN_SEC=7200` appended; it equals the repo's settings.
  - Drop-in `numo-engine-keeper-v2.service.d/checkout.conf`: `WorkingDirectory=/home/ec2-user/exchange-keeper-v2/
    services/perp-keeper`; ExecStart unchanged. Restarted.
  - `/home/ec2-user/exchange-pager` `290a4b8` → `5cae810` (detached; 8685b4c and 3587fa1, the options checks). No restart:
    the pager is a timer.
- **After.** Keeper active from the new cwd, 0 restarts, 0 alerts; `/health` `lastPassOk: true`, `options:
  [0xA6a0…3821]`, `optionsSettled: []`, `optionsAwaitingPrice: []`. Pager's first run on the new code: `options
  cNGN-30NOV26: cap 0, open 0 cNGN; vol confidence 1.00`; state `volFeeds: [0xf2dB…C5E0]`, `lastRunOk: true`, 0 active.
  `exchange-future-v2` untouched (the forward keepers still on 840526a).
- **Undo.** `rm /etc/systemd/system/numo-engine-keeper-v2.service.d/checkout.conf; cp -p /etc/numo/engine-keeper-v2.env.bak-202611020125
  /etc/numo/engine-keeper-v2.env; systemctl daemon-reload; systemctl restart numo-engine-keeper-v2`; pager:
  `sudo -u ec2-user git -C /home/ec2-user/exchange-pager checkout --detach 290a4b8`.

## 2026-11-02 01:22 UTC: numo-vol-feeds live; the pager watches its relayer

- **Relayer topped up** by Robert to 0.004090 ETH (+0.0025): ~29 days at the measured ~0.00014 ETH/day, to expiry.
- **SSM `aed770d1`** (Robert, from the laptop), each file backed up as `.bak-202611020122` beside it:
  - `/etc/numo/perp-pager.env`: `,vol-relayer=0xE5b8541dC2558f3db65aF88A2374e464AE4ae6de:0.0003` appended to `GAS_WATCH`,
    nothing else. Not a copy of the repo's file: that had drifted from the box (box-34's `FUTURE_ARTIFACT` and
    `forward-relayer-v1` removal were never written back; fixed in `b4a314e`), and copying it would have revived v1's
    future checks. The box's settings now equal the repo's exactly (compared after).
  - `/etc/numo/vol-feeds.env`: `DRY_RUN=true` → `false`; `numo-vol-feeds` restarted. Refused unless the env was in dry
    run and the v1 keeper still disabled.
- **First publish:** `0xe29593f8…a44f`, block 53396604, from `0xE5b8…ae6de` (nonce 886 → 887), 189,349 gas (the first
  write to the expiry). Read back on chain: `getVol` 40.0% at the forward (strike 0.00072128), 49.2% at 0.8x, confidence
  1.0; the engine prices a 1M cNGN short ATM put at a $243.86 IM requirement ($32.16 of it the mark) with spot at
  0.00072797. The pager's next run read `vol-relayer` (0.00409 ETH), 0 active.
- **Undo.** `cp -p /etc/numo/vol-feeds.env.bak-202611020122 /etc/numo/vol-feeds.env && systemctl restart numo-vol-feeds`
  (back to dry run; the surface then ages out in 30 min, harmless while the option's cap is 0), and the same for the pager
  env.

## 2026-11-02: numo-vol-feeds installed in dry run, on v1's forward relayer

- **Read-only first (laptop):** `/var/lib/numo` writable by ec2-user, `perp-index-status.json` fresh (60 s),
  no step log (no index step ever taken), node 22.23.3, pnpm 8.7.3, no `exchange-vol`, no unit; the instance role
  `numo-feed-publisher-role` holds the vol signer's KMS grant (terraform, 2026-11-01).
- **Relayer.** v1's forward relayer `0xE5b8541dC2558f3db65aF88A2374e464AE4ae6de` (`/numo/feeds/forward_relayer_key`),
  idle since `numo-future-feeds` was stopped and disabled on 2026-11-01 (box-34); 0.00159 ETH at nonce 886, about 11
  days at a publish every 5 min (a vol update is 78,627 gas, ~0.00000047 ETH at 0.006 gwei, measured on a fork with the
  KMS signer: ~0.00014 ETH/day, ~0.0039 ETH to expiry). **Never restart `numo-future-feeds` while numo-vol-feeds runs.** A new key
  `/numo/feeds/vol_relayer_key` (`0x0198eEDf…10bA`, unfunded, never used) was created first and then superseded by the
  reuse; nothing reads it, and it can be deleted.
- **Install (SSM `b4b7017c`, Robert from the laptop):** refused unless no checkout, no unit, and the v1 keeper both
  inactive and disabled. `/home/ec2-user/exchange-vol` cloned at `6466668` (detached); `pnpm install --frozen-lockfile
  --filter perp-feeds...`, `@numo/kms-signer` and `perp-feeds` built; `/etc/numo/vol-feeds.env` from
  `vol-feeds-cngn-30nov26.env` (`DRY_RUN=true`); `numo-vol-feeds.service` installed, enabled and started.
- **After:** active, 0 restarts, 0 alerts. Startup checks passed (heartbeat, the feed accepts the KMS signer, degraded
  confidence under the engine's 0.8, the feed attached to market 1). Log: signer `0x30b9…fbf5` (KMS), relayer
  `0xE5b8…ae6de`, feed `0xf2dB…C5E0`; `DRY RUN: would publish ATM 40.0% conf 1.00 fwd 721368707601761 (normal)`;
  `/var/lib/numo/vol-status.json` mode normal, `dryRun: true`. Nothing published.
- **Not yet:** the relayer's top-up (~0.0025 ETH more covers expiry at today's gas), `/etc/numo/perp-pager.env` with `vol-relayer` in GAS_WATCH,
  and `DRY_RUN=false`.
- **Undo.** `systemctl disable --now numo-vol-feeds; rm /etc/systemd/system/numo-vol-feeds.service /etc/numo/vol-feeds.env;
  systemctl daemon-reload` (the checkout can stay).

## 2026-11-02 00:42–00:45 UTC: cNGN options setup proposed and landed

- **`numo-cngn-options-setup`** (transient unit, `run-with-ssm-mark.sh python3 propose_cngn_options_v2_batch.py
  cngn-options-setup --propose`, as ec2-user, from `exchange-ops` at `0586889`), started by SSM `c4f5045e` (Robert, from
  the laptop) at 00:42:26 and exited 0 at 00:45:20. An earlier start, SSM `86a2ac86`, refused itself before starting
  anything: its guard compared the 7-character `0586889` with the box's 8-character `git rev-parse --short` (`05868896`);
  the second guard compared the full hash. Six requests to MPCVault, one at a time, each approved by hand against the
  dry run's digest, the six gates re-run (all PASS) before each:

  | # | Action | MPCVault request | Digest |
  | --- | --- | --- | --- |
  | 0 | option `acceptOwnership` | `f88c9288` | `0x583b189f…a4d4` |
  | 1 | vol feed `acceptOwnership` | `1c4b769a` | `0x8fe10d65…97a6` |
  | 2 | engine v2 `whitelistAsset(option, 1, Option)` | `4403e826` | `0xa184cfcb…68f9` |
  | 3 | engine v2 `setOptionMarginParams(1, …)` | `0d77daca` | `0xcfb8b17c…6ce` |
  | 4 | engine v2 `setOracleContingencyParams(1, …)` | `3af58a3f` | `0xfddec438…0b0c` |
  | 5 | engine v2 `setOraclesForMarket(1, index, forward, vol)` | `18020595` | `0x11632aab…fa0a` |

  Transaction hashes were not recorded: the public RPC throttled every lookup that night. They are the vault's
  transactions in Base blocks ~53395460–53395525, or each request's in MPCVault.
- **Read back at block 53395499 (laptop):** the vault owns the option and the vol feed (nothing pending); market 1 lists
  the option (whitelisted, market 1, Option); option margin 0.30/0.25/0.15/0.15/0.5/1.2/1.1/1.05; contingency perp 0.55,
  option 0.8, base 0.55, OCFactor 1.0 (perp, base and the factor as before); market 1's feeds the live index
  `0xFaC4…20a5` (unchanged), the cNGN future's forward, the vol feed; the option's cap 0 (closed). Engine accounts
  #39, #40, #42 and #43 margin as normal. Nothing else on the box changed.

## 2026-11-02: `exchange-ops` moved to `0586889` for cNGN options setup; dry run on the box

- **Read-only first (SSM `e8ff048a`):** `exchange-ops` at `4f251e8`, clean, `0586889` its descendant,
  `numo-cngn-options-setup` inactive, Python 3.9.25 (the proposer's mainnet dry run passed under 3.9 off the box first).
- **`exchange-ops`** moved `4f251e8` → `0586889` (the cNGN options deploy record), detached, by SSM `937aed2e`, run by
  Robert from the laptop: it refused unless the checkout was clean, the unit inactive and the old HEAD an ancestor.
- **Dry run in the same command** (`run-with-ssm-mark.sh python3 propose_cngn_options_v2_batch.py cngn-options-setup`,
  as ec2-user, no `--propose`): all six gates PASS (nominated, engine, market1, venue, series, parity); the six digests
  are the laptop dry run's: `0x583b189f…a4d4`, `0x8fe10d65…97a6`, `0xa184cfcb…68f9`, `0xcfb8b17c…6ce`,
  `0xfddec438…0b0c`, `0x11632aab…fa0a`. Nothing proposed, nothing else on the box changed.
- **Undo.** `sudo -u ec2-user git -C /home/ec2-user/exchange-ops checkout --detach 4f251e8`.

## 2026-11-01: the cNGN options vol signer: a KMS key the box's role may sign with (terraform, not on the box)

- **What.** `terraform apply` from main (`infra/aws` ops-box.tf, `var.vol_signer_kms_enabled`), plan "3 to add, 0 to
  change, 0 to destroy", nothing else in the stack moved: `aws_kms_key.vol_signer` (secp256k1, SIGN_VERIFY,
  `prevent_destroy`, key `f8207956-f587-4b40-a0ab-1430e5dd9a47`), `alias/numo-exchange-vol-signer`, and the role policy
  `numo-vol-signer-kms-sign` on `numo-feed-publisher-role` (`kms:Sign`, `kms:GetPublicKey` on that key only).
- **Read back.** `describe-key`: Enabled, ECC_SECG_P256K1. The role policy as above. Address
  `0x30b9c910777a0B08fCfD645bca4121bDDC12fbf5` (`cast wallet address --aws`), and a test signature from KMS recovers to it.
- **Why.** The options' vol feed takes its signer at deploy (deploy-cngn-options-v2.s.sol `VOL_SIGNER`), and the vol
  publisher refuses a raw key on mainnet. Nothing on the box changed: numo-vol-feeds is not installed, and the key
  authorises nothing until the deploy names it.

## 2026-11-01 ~21:49 UTC: the vault's v1-pool cNGN deposited into the v2 spot maker #42

- **`exchange-ops`** moved to `4f251e8` (#307, #308).
- **box-36 (SSM `3ec75cf2`):** transient unit `numo-vault-cngn-to-mm`, `propose_vault_cngn_to_mm.py --propose`; two
  MPCVault requests approved by hand: `cNGN.approve(cNGN escrow, 6,229.150178)` (`b4c42029`, tx `0x789034c6…`, block
  53390218) and `escrow.deposit(#42, 6,229.150178)` (`811624f4`, tx `0x507eeb83…`, block 53390224). Artifact
  `deployments/8453/VAULT_CNGN_TO_MM_VAULT_ACTIONS.json`.
- **After:** #42 382,412.965849 cNGN; the vault 0 cNGN. Nothing else on the box changed.

## 2026-11-01 21:27 UTC: numo-perp-feeds on its own checkout, with the two-of-three index fallback (#305)

- **Why.** Textile's 502s since 2026-10-26 left the 3-of-3 index refusing samples; four gaps in seven days ran past the
  engine cNGN feed's 1200 s heartbeat (10-26 18:20 25 min, 10-27 18:39 32, 10-28 05:14 32, 11-01 10:05 21), and in each
  v2's margin reads reverted `BLF_DataTooOld` (keeper `margin-unreadable` / `collateral-unpriced-cNGN`). The pager did not
  page. #305: with one source down, a sample is taken from the two left within 50 bps of each other, alerting
  `index-sample-fallback`.
- **box-35 (SSM `3949fbc1`).** `/home/ec2-user/exchange-feeds` cloned at `1c7c838` (origin/main, with #305); `pnpm install
  --frozen-lockfile --filter perp-feeds...`, `@numo/kms-signer` and `perp-feeds` built (tsc only). `--probe-sources` from
  the new build: 3 of 3 answered (quidax 1373.87, textile 1372.75, bybit-p2p 1372.00). Drop-in
  `numo-perp-feeds.service.d/checkout.conf` sets `WorkingDirectory` to its `services/perp-feeds`; ExecStart (exchange-perp's
  `run-with-ssm.sh`, then the relative `dist/main.js`) and `/etc/numo/perp-feeds.env` unchanged. Restarted at 21:27:15.
- **exchange-perp not moved:** still `af584bc` with its 2026-10-03 perp-feeds dist (kept, unused now) and the MM bundle;
  `numo-perp-keeper` runs from it as before.
- **After.** New PID's cwd is the new checkout, 0 restarts; first sample 21:27:20 from all three sources; first publish
  read on chain at 21:28:23 (`getSpot` 0.000728462). The index state (`/var/lib/numo/perp-index-state.json`) carried the
  TWAP window across the restart. box-35's own "OK" line matched the old process's last publish (21:27:15, same second
  as the stop); the new process was confirmed separately.
- **Undo.** `rm /etc/systemd/system/numo-perp-feeds.service.d/checkout.conf; systemctl daemon-reload; systemctl restart
  numo-perp-feeds` (back to exchange-perp's dist, 3-of-3).

## 2026-11-01 ~00:25–00:46 UTC: v1 emptied and retired on the box

v1 held only #32 (the stopped v1 future maker) and pool #31; both are dust now. Every other v1 account was dust
before.

- **box-32 (SSM `e0e038e4`; `e3ee0082` before it was refused the MM key while IAM propagated, nothing sent):** under
  the MM-key grant (`mm-grant-v1sweep.plan`, revoked by `mm-revoke-v1sweep.plan` after). `exchange-perp/scripts/
  local-venue/dist` → `ops/migrate-spot-mm-dist` at `fcecc6c` (from `51cd7e1`). #32's whole balance to the MM wallet:
  4.614333 USDC (`0xcc645c4a…`, block 53351851) and 151,230.535055 cNGN (`0x72b0b6d3…`); `deposit-cngn 42`;
  `move-usdc 32 42 4614333 --deposit-only` (approve `0x42e01090…`, deposit `0x27131301…`, block 53351860). #42 after:
  499.519438 USDC, 376,183.815671 cNGN.
- **`exchange-ops`** moved to `53ad327` (#302, #303: the proposer ran on the box's Python 3.9 only after #303).
- **box-33 (SSM `f2bd8fc4`; `788189d5` first refused, `zip(strict=)` on 3.9):** transient unit
  `numo-v1-pool-close`, `propose_v1_pool_close.py --propose`, after 4.85 USDC was sent to the vault. Three MPCVault
  requests, each approved by hand and confirmed before the next: `USDC.approve(CashAsset, 4.85)` (`0x63d334f6…`),
  `CashAsset.deposit(#31, 4.85)` (`0xa2f3210a…`), `v1.withdrawFromPool(cNGN escrow, 6,229.150178, vault)`
  (`0xa897a673…`, block 53352129). Pool #31 after: 0.034116 USDC, 0.000000786 cNGN; the vault holds the 6,229.150178
  cNGN. Artifact `deployments/8453/V1_POOL_CLOSE_VAULT_ACTIONS.json`.
- **box-34 (SSM `1ed412ba`):**
  - `numo-future-feeds` (the v1 USDC-cNGN-30NOV26 keeper) stopped and disabled. Nothing pages on it.
  - `/etc/numo/perp-pager.env` (kept as `.bak-<stamp>` beside it): `FUTURE_ARTIFACT=/var/lib/numo/v1-future-retired.json`,
    a path that must not exist, so the pager reports `future: not deployed` for v1 and reads v2 from
    `FUTURE_V2_ARTIFACTS` as before; `forward-relayer-v1` removed from `GAS_WATCH`.
  - Drop-in `numo-settlement-canary.service.d/v2-accounts.conf`: `CANARY_ACCOUNTS=42,43`, `OTHER_MANAGERS=<v1>,<v2>`
    (32 and 34 held dust and failed the $10 floor every 5 min).
  - Drop-in `numo-rebalance-check.service.d/v2-accounts.conf`: `MM_SUBACCOUNT_ID=42` (the default, 34, is the emptied
    v1 account and failed on its manager).
  - After: pager ok, canary ok on #42/#43. The rebalance check then failed on HyperFX alone (`the orderbook cannot
    fill 1000000 USDC units (max 0)`): the solvers' USDC-cNGN bids on Base lapse for 8–16 h most days since
    2026-10-25 and come back; left as is.
  - Undo: `systemctl enable --now numo-future-feeds`; restore the `.bak` pager env; remove both `v2-accounts.conf`;
    `systemctl daemon-reload`.

## 2026-10-31 ~15:45–16:26 UTC: MarginEngine v2 enabled; cNGN-30NOV26 and EURC-30NOV26 open

Brought forward from the 9 Nov target. `MarginEngineV2EnableRehearsalFork` passed at head first (4/4).

- **`exchange-ops`** moved `23e5037` → `54f510c` (box-30, SSM `2f39b909`), then → `fb2b9d5` (box-31). Clean both
  times; nothing that runs from it was restarted.
- **Gate dry run (box-30):** both enables passed every gate but `parity`. Its deployer-nonce check counted 14
  transactions since v2's deploy and 1 since EURC's: the EURC-30NOV26 deploy (nonces 38–50) and the 0.00025 ETH relayer
  top-up (nonce 51). Every other parity setting held. #299 (`fb2b9d5`) lets the gate accept a later transaction only
  when `deployments/8453/DEPLOYER_AUDITED_TXS.json` lists it and the chain shows that hash at that nonce.
- **Proposed (box-31, SSM `ff25036f`):** transient unit `numo-v2-enable`, `propose_margin_engine_v2_batch.py enable
  --propose`, then `propose_eurc_future_v2_batch.py eurc-future-enable --propose`; exit 0. Approved by hand in
  MPCVault, landing 16:25–16:26: cNGN-30NOV26 `setTotalPositionCap(v2, 30)` and `setDatedFutureAsset(…, true)`,
  then EURC-30NOV26 `setTotalPositionCap(v2, 18)` and `setDatedFutureAsset(…, true)`. Gates re-read before each:
  SecurityModule $3,250 covers a 15% step on both at their caps ($1,621 + $1,508); informational gaps: cNGN's 30 is
  not covered at a 50% gap, EURC's 18 not at 15%.
- **After:** `/v1/markets` lists both `trading_open: true`; the app's `/` opens `/trade/cngn-30nov26` (trading-app
  `59a5454`); the v2 makers (#39, #40) quote 10 a side; the pager, the v2 keeper and the settlement canary (#298) cover
  both.

## 2026-10-31 ~20:30–22:20 UTC: MarginEngine v2 steps 4–6; spot makers moved to v2 (#42, #43)

- **Step 4 (ECS, no box change):** `spot_margin_manager_address` / `deposit_manager_address` → v2, `cngn_future_close_only`
  (f3abc50; also in the operator's counts.auto.tfvars, which overrode both). markets td :48, matcher :47, execution :38;
  trading-app d208815 live with Vercel's `NEXT_PUBLIC_USDCCNGN_MANAGER_ADDRESS` removed.
- **Spot makers stopped** (counts: both 0) under an MM-key grant. `exchange-perp/scripts/local-venue/dist` →
  `ops/migrate-spot-mm-dist` at `96d33ff` then `fcecc6c` (from `51cd7e1`: v1 engine accounts, EURC withdraw,
  deposit-eurc, deposit-cngn without the delisted perp).
- **#34 (v1) → #42 (v2):** withdraw 484.905526 USDC (`0xdce551ff…`) + 238,672.280616 cNGN (`0xab567951…`);
  `engine-account` opened #42 (`0xaef85899…`, first try reverted at estimate on a lagging node, nothing sent);
  `deposit-cngn 42`.
- **#36 (v1) → #43 (v2):** withdraw 4,316.186093 USDC (`0xa9b8a467…`) + 3,281.439616 EURC (`0x4a927470…`);
  `engine-account` opened #43 (`0x029e3983…`; post-check read failed on RPC lag, account confirmed on chain).
- **Makers repointed** (1e1287f: `mm_subaccount_id` 42, `mm_eurc_subaccount_id` 43, v1-close-only gate's makers 42,43);
  cNGN-USDC maker restarted on #42, grant revoked.
- **`exchange-ops`** `fb2b9d5` → `bea3cce` (eurc-cap reads v2's engine keeper on 9466).
- **Step 5 (`numo-v2-close-only`):** v1 caps = open interest: cNGN escrow 157,459.685234, EURC escrow 0, v1 future 0.
  Approved in MPCVault.
- **Step 6 (`numo-v2-eurc-cap`):** `eurcEscrow.setTotalPositionCap(v2, 18,000)`, digest `0xdc9d2cfb…6dab`; depth gate
  22,808 EURC, keeper MAX_EURC_INVENTORY 40,000. Approved in MPCVault.
- **EURC maker:** second grant; `deposit-eurc 43` (3,281.439616 EURC; the first try was denied the key while IAM
  propagated, nothing sent); maker started on #43, grant revoked. Both books quote from v2 (#42, #43).

## 2026-10-31 ~14:00–14:40 UTC: #32's USDC moved to the v2 makers #39 and #40; v1 future maker stopped

Under a second MM-key grant (`mm-move.plan`, which also stopped `market-maker-future`, the v1 USDC-cNGN-30NOV26 maker
on #32: `desired_count_market_maker_future = 0` in counts.auto.tfvars; the v1 series' total position was 0).

- **box-27 (SSM `a8da0629`), bundle `8b93d47` from `0f4e0bc` (#294, `move-usdc`):** 2,800 USDC withdrawn from #32 to
  the MM wallet (`0x283d9ac9…`, block 53333160) and approved (`0x2c1826c3…`); the deposit into #39 was refused at gas
  estimation ("exceeds allowance"), estimated on a node behind the approve.
- **box-28 (SSM `2c4cd642`), bundle `74bd597` from `39c6490` (#295, lag retries, `--deposit-only`):** the 2,800 into
  #39 (`0xfef7f119…`, block 53333339). Its post-check failed on the cash interest the deposit also credits
  (fixed in #296).
- **box-29 (SSM `fb32d2d4`), same bundle:** 1,300 USDC #32 → #40 (withdraw `0x951a3a37…`, deposit `0x3d59d5e4…`,
  block 53333410); the same false post-check.
- **After, on chain:** #39 2,800.10 USDC, #40 1,300.10, #32 4.61 (and its 151,230 cNGN); MM wallet 0.10 USDC.
- **Grant revoked** by the apply that started both v2 makers in dry run; from the box, the key read is refused.
  `exchange-perp/scripts/local-venue/dist` stays at `74bd597` (from `39c6490`, before #296); rebuild before the next
  grant.

## 2026-10-31 ~13:50 UTC: v2 maker accounts #39 (cNGN-30NOV26) and #40 (EURC-30NOV26) opened

Under the MM-key grant (`terraform apply -var ops_box_mm_key_grant=true` from `1207934`, which also created the two
v2 maker services at 0 replicas), by SSM command `4e4195b7`.

- **`/home/ec2-user/exchange-perp/scripts/local-venue/dist`** replaced by `ops/migrate-spot-mm-dist` at `389debe`: the
  bundle built off-box from `1207934c72fa` (#291, `engine-account --market`). Nothing else in exchange-perp changed;
  nothing that runs from it was restarted. Rollback: `git checkout e96ecc0 -- scripts/local-venue/dist`, as ec2-user.
- **`engine-account 100000 --market=cNGN-30NOV26`:** #39 under the v2 engine `0x0705…0950`, the MM's in Matching,
  0.10 USDC (approve `0xc4b36d26…`, create `0xedd6a18f…`, block 53332502).
- **`engine-account 100000 --market=EURC-30NOV26`:** #40, likewise (approve `0xe608a754…`, create `0x33d03f75…`,
  block 53332505). Its post-check failed with "unsupported block number" (the RPC behind the receipt), so the SSM
  command reports Failed; manager, Matching owner and cash were confirmed on chain afterwards.
- **Grant revoked** by an apply from `main` (1 changed, 1 destroyed); from the box, the read of
  `/numo/exchange/mm_private_key` is refused with an explicit deny.

## 2026-10-30 ~21:00 UTC: gas watch for the forward relayers and the v2 engine keeper; one false page

From #288 (`cfbece9`), installed by SSM command `44c669f0`.

- **Pager checkout.** `exchange-pager` moved from `e7a6137` to `cfbece9`, clean.
- **`/etc/numo/perp-pager.env`.** #288's `GAS_WATCH` line was appended, with backup `perp-pager.env.bak-<stamp>`. It
  watches the executor, the perp relayer, `forward-relayer-v1` `0xE5b8…e6de`, `forward-relayer-v2-cngn` `0x3ACe…763f`,
  `forward-relayer-v2-eurc` `0xEEa4…5321` (floors 0.0003 ETH) and `engine-keeper-v2` `0x753f…f83b` (floor 0.002).
  `KEEPER_EOA` still adds the perp keeper.
- **False page.** The first run paged `low-gas-forward-relayer-v2-cngn`. The pager read burn as the 24h balance drop,
  and that window held the morning's 0.001 ETH send to the EURC relayer, so it read 0.00103 ETH/day against a
  balance of 0.00195.
- **Cleared by a top-up.** The operator sent 0.00025 ETH to `0x3ACe…763f` from deployer `jason` `0x971C…2e9c` (tx
  `0x07971b17cf14cd04a128b89c3bbc732815d0287b8500568b669c732fcdbc75cb`). The relayer then held 0.00220. The pager read
  `ok: 0 active` from 21:16 UTC.
- **The fix.** The follow-up PR changes how burn is measured, to the median of four 6h drops. It is not on the box
  until the pager checkout moves to it.
- **Rollback.** Restore the `.bak`, then `git -C /home/ec2-user/exchange-pager checkout --detach e7a6137`.

## 2026-10-30 05:30–12:52 UTC: EURC-30NOV26 setup proposed; its publisher, keeper and pager wiring

EURC-30NOV26 on MarginEngine v2 (#282, deployed 05:11 UTC; #285, #286). The series stays closed (cap 0): the only vault
actions are its setup's four, approved by hand in MPCVault.

- **`/home/ec2-user/exchange-ops`** moved from `fc6ef0a` to `23e5037` (#285, the EURC artifacts), detached, by `box-21`
  (SSM `08fbaac2-…`). Transient unit `numo-eurc-future-setup` (`propose_eurc_future_v2_batch.py eurc-future-setup
  --propose`) proposed the four actions one at a time; all landed 05:34–05:35 UTC and the unit exited 0.
- **Key (laptop).** `/numo/feeds/forward_relayer_key_v2_eurc` (relayer `0xEEa45ea4f68cb62b5eDe84E1d9F82F6d253C5321`),
  piped from `cast wallet new` into SSM as before. The unused `/numo/keeper/engine_v2_keeper_key` was deleted 2026-10-29.
- **`box-22`** (SSM `699c578f-…`, 05:54 UTC):
  - `/home/ec2-user/exchange-pager` moved from `840526a` to `e7a6137` (#286: the pager labels a series by its artifact's
    `symbol`; before, EURC read as `cNGN-30NOV26`). `/etc/numo/perp-pager.env` gained `FUTURE_V2_ARTIFACTS` (both
    series). The run after: `futures` lists v1's, cNGN-30NOV26 and EURC-30NOV26; SM $3,250 against $382.
  - **EURC relayer funded from v2 cNGN's**: 0.001 ETH from `0x3ACe…763f` to `0xEEa4…5321` (tx
    `0xcf633383eae5510b11706d798554f6a58efdf221e03a01608b6fc9cad96a8c85`, block 53275169), with
    `numo-future-feeds-v2@cngn-30nov26` stopped for the send and restarted after. cNGN's relayer keeps 0.00196 ETH.
  - **`numo-future-feeds-v2@eurc-30nov26`**: `/etc/numo/future-feeds-v2-eurc-30nov26.env` from the repo's template plus
    `DRY_RUN=true`, on the existing `numo-future-feeds-v2@.service` and `/home/ec2-user/exchange-future-v2` at `840526a`
    (no build). Dry-run marks were carry: 1.12082 on index 1.11939 (+0.128%, -1.5% over 31 days).
  - `/etc/numo/engine-keeper-v2.env`: `FUTURE` gained `0x6Ff7…7744` (backup `.bak-<stamp>`); `numo-engine-keeper-v2`
    restarted, `/health` lists both futures.
- **markets-service (05:57 UTC)**: terraform apply of #286's `future_series` through `with-matcher-mute.sh` (markets and
  matcher task definitions only, image unchanged). `/v1/markets` lists `EURC-30NOV26`, `trading_open` false.
- **Live (`box-23`, SSM `2e4d3dc3-…`, 12:50 UTC)**: `DRY_RUN=false` (backup `.bak-<stamp>`). First mark tx
  `0x00051390e4d829c1c82124cc2f4a90d8c1d944eb76df6d3c959dd7f7b47e1663` (12:51:32), 1.119695 on index 1.118263. Until
  then, `forward-mark-late` fired each minute: the deploy's mark (05:11) was the only one. The first tick after the
  restart also raised `expiry-tick-error` and `pool-deficit-error` ("Missing or invalid parameters", the box RPC), once.
- **Not watched:** neither v2 relayer is in `check_signer_balance.py` (that timer runs from the pinned checkout).
- **Undo.** `systemctl disable --now numo-future-feeds-v2@eurc-30nov26`; restore the two env backups and restart
  `numo-engine-keeper-v2`; pager `checkout --detach 840526a`; exchange-ops `checkout --detach fc6ef0a`.

## 2026-10-28 18:56–19:08 UTC: v2 keepers on the box; the engine keeper moved from v1 to v2

MarginEngine v2's forward publisher, liquidation keeper and pager watch (#258), for `enable`. v2 stays closed: nothing
here is a vault action. Run from the laptop's admin session and SSM scripts (`box-17` to `box-20`), each refusing to
overwrite what it would install.

- **Keys (laptop, 18:56 UTC).** Two fresh keys piped from `cast wallet new` into SSM (SecureString, `--no-overwrite`,
  never printed or written to disk): `/numo/feeds/forward_relayer_key_v2_cngn` (relayer `0x3ACeFDe146161D1b9ca2fdB8a3B38122818d763f`)
  and `/numo/keeper/engine_v2_keeper_key` (`0x2d9C…9aFd`). The second is **unused**: the keeper moved instead (below);
  it holds nothing and is to be deleted. Both paths are under the box's existing grants.
- **`/home/ec2-user/exchange-future-v2`** cloned at `840526a` (#281) by `box-17` (SSM `621f3270-…`); `pnpm install
  --frozen-lockfile` for perp-feeds and perp-keeper, `@numo/kms-signer`, `perp-feeds` and `perp-keeper` built (tsc only).
  No other checkout moved by it.
- **v2 relayer funded from v1's forward relayer**, on the box: 0.003 ETH from `0xE5b8…e6de` to `0x3ACe…763f`
  (tx `0x963cc9b03a919de9b341aa9ddb4f08b8988603b482638b36118ab386eb544efb`, block 53212235, 18:56:57), with
  `numo-future-feeds` stopped for the send and restarted straight after. v1's relayer keeps 0.00167 ETH (~0.00002/day).
- **`numo-future-feeds-v2@cngn-30nov26`**: `/etc/numo/future-feeds-v2-cngn-30nov26.env` from the repo's template plus
  `DRY_RUN`, and the repo's `numo-future-feeds-v2@.service`. Dry run first (mark 0.00071530 from carry; one real
  `forward-mark-late` alert, v2 unmarked since its deploy), then `DRY_RUN=false` by `box-19` (SSM `b7bac295-…`): first
  mark tx `0x9fbc6cbb48fc6ac99f625a6cf835283d622f353ca6f4b8048f7e4381f3d803bf` (block 53212483, 19:05:13), 0.00071531
  from carry. markets-service does not list the series yet, so the book read returns 400 and the mark is carry.
- **The engine keeper moved v1 → v2** (`box-18`, SSM `51682451-…`, `adfc1bc7-…`, `e3e14bc8-…`), the operator's decision:
  one keeper, one EOA, one balance. **v1's USDC-cNGN-30NOV26 (22.696 contracts open) has no liquidator until it settles
  on 30 Nov.**
  - `numo-engine-keeper` (v1, port 9465) stopped and disabled first: its last health, nothing liquidatable, no auctions.
  - From its EOA `0x753fCC2342F180e1B9B0BfFFEb21f4E00741f83b`: `CashAsset.withdraw(#33, …)` (txs `0x4a4559e3…586f`,
    18:59:53, and `0x876c0dc8…1aeb` for 0.0052 of interest, 19:01:59); `SubAccounts.createAccount(EOA, v2)` → **#38**
    (tx `0x7238bbea…74c0`, 18:59:55); `USDC.approve` + `CashAsset.deposit(#38, 5,000.005198)` (txs `0x5e13a4c1…b221`,
    `0x7dc19445…32be`, 19:03:35–37). After: #38 holds 5,000.005198 USDC cash under v2, #33 0.0000003, the EOA 0.00299 ETH.
  - `numo-engine-keeper-v2`: `/etc/numo/engine-keeper-v2.env` (`KEEPER_ACCOUNT=38`), the repo's unit, and a drop-in
    `numo-engine-keeper-v2.service.d/key.conf` pointing its key at `/numo/keeper/engine_keeper_key` (the box cannot
    write SSM, so v1's key was not copied). Dry run, then `DRY_RUN=false` by `box-19`. This branch's unit names that key,
    so the drop-in can go when the unit is next copied.
  - Two failed runs first, both the box RPC answering a block behind: #38's manager read `0x0` right after its
    `createAccount`, then a lagging node gave the approve the withdraw's nonce ("replacement transaction underpriced").
    Nothing was lost; the script now retries reads and nonce rejections.
- **Pager.** `/home/ec2-user/exchange-pager` moved from `4cbb7e77` to `840526a` (`box-19`); `ENGINE_V2_KEEPER_HEALTH_URL=
  http://127.0.0.1:9466/health` appended to `/etc/numo/perp-pager.env` (backup `.bak-<stamp>`) by `box-20` (SSM
  `dfb7f130-…`). `box-19` stopped at `--self-test`, which needs forge's `out/` (`abi_selectors`): this box never builds
  with forge, so the self-test runs on a laptop. The run by hand after: ok, reads both engines (`futureManagers` v1 + v2,
  `futures` v1's + cNGN-30NOV26), v2 one side $0, pool #37 $0, `v2 keeper: ok`, SM $3,250 against $1,858.
- **Not watched:** neither forward relayer is in `check_signer_balance.py`'s single `SIGNER_ADDRESS`, and that timer runs
  from the pinned `/home/ec2-user/exchange`, so a change here does not reach it.
- **Undo.** `systemctl disable --now numo-future-feeds-v2@cngn-30nov26 numo-engine-keeper-v2`; to give v1 its keeper back,
  move #38's cash to #33 from the EOA and `systemctl enable --now numo-engine-keeper` (stop v2's first: one EOA). Pager:
  restore the env backup and `checkout --detach 4cbb7e77`.

## 2026-10-27 20:19–20:28 UTC: `exchange-ops` moved to `fc6ef0a`; MarginEngine v2 setup proposed and landed

- **`/home/ec2-user/exchange-ops`** moved from `539ae00` (#268) to `fc6ef0a` (#277, the v2 artifacts), detached, by
  `/root/box-16.sh` (SSM `26d0f727-…`): it refused unless the checkout was clean, `numo-v2-setup` inactive and the old
  HEAD an ancestor of `fc6ef0a`. Read-only check before it: SSM `dd36632a-…`. `/root/box-16.sh` was removed the same day (SSM `7f0db571-…`).
- **`numo-v2-setup`** (transient unit, `run-with-ssm-mark.sh python3 propose_margin_engine_v2_batch.py setup --propose`,
  as ec2-user) started 20:20:20 and exited 0 at 20:28:13. It posted 9 requests to MPCVault one at a time, each approved
  by hand against the dry run's digests, waiting for each to land and re-running the gates (nominated, reused,
  markets) before the next. Action 8 (EURC escrow cap 0 under v2) was skipped: a cap never set reads 0.

  | # | Action | Tx |
  | --- | --- | --- |
  | 0 | engine `acceptOwnership` | `0xe6bf1a40…6d39` |
  | 1 | viewer `acceptOwnership` | `0xd9d8c3b5…0834` |
  | 2 | future cNGN-30NOV26 `acceptOwnership` | `0x80d76c8d…9dff` |
  | 3 | forward feed `acceptOwnership` | `0xc050963e…6fe2` |
  | 4 | cash `setWhitelistManager(v2, true)` | `0x8443ccf9…cdde` |
  | 5 | cNGN escrow `setWhitelistManager(v2, true)` | `0x2f46e68d…ed2b` |
  | 6 | cNGN escrow `setTotalPositionCap(v2, 1e26)` | `0xd5e3fe17…1e06` |
  | 7 | EURC escrow `setWhitelistManager(v2, true)` | `0x43e31d01…f882` |
  | 9 | auction `setWhitelistManager(v2, true)` | `0x69799810…397e` |
  | 10 | engine `setGuardian(0xDb71…3C31)` | `0x85ddbfb7…c650` |

  The run's last gate, parity, passed: all 63 settings as deployed, the deployer `0x971C…2e9c` holding nothing (nonce
  still 38). Journal read back with SSM `df6f8b67-…`.
- **Read back from the laptop**: the vault owns all four v2 contracts; v2's guardian is `0xDb71…3C31`; cash, both
  escrows and the auction (`managerWhitelisted`) whitelist v2 **and still v1**. Fork of block 53172401: a new v1
  account deposits and withdraws 100 USDC through the cash asset, and a new v2 account deposits.
- **Undo.** None needed for v1. v2 stays closed (future cap 0, EURC cap 0) until `enable`.

## 2026-10-25 12:40 – 2026-10-26 14:58 UTC: EURC maker account #36 opened, funded and quoting

- **MM-key grant, applied then revoked.** `ops_box_mm_key_read` (a one-off Allow on `/numo/exchange/mm_private_key` for
  the box role, with the key carved out of `ops_box_ssm_deny_outside_paths`) was applied from the laptop on 2026-10-25 so
  the box could open the maker's account. The 2026-10-26 apply from main removed both (4 added, 2 changed, 2 destroyed).
- **Account #36** opened 2026-10-25 12:46 UTC by `run-with-ssm-mm.sh engine-account 5000000 --execute` from
  `exchange-perp` (bundle `66da52db3cca`): approve then `createAndDepositSubAccount` (block 53071521), 5 USDC, manager
  the MarginEngine, held by Matching for the MM wallet `0x3448…B47B`. SSM `784b9a87-…` failed on IAM propagation
  (AccessDenied, nothing ran), `f81d75ea-…` dry run, `17b424d2-…` execute.
- **Funding**, 2026-10-26, from MPCVault wallet "Market-Maker EURC-USDC" `0x8f4951f57Fcc4A7dcF99cF066FD35b1AB63D1B7a`,
  entered by hand in the MPCVault app: EURC approve `0x704925c3…` (14:47:03), EURC deposit(36, 3,291.439616)
  `0x1c096230…` (14:49:19), USDC approve `0xcc932167…` (14:51:55), USDC deposit(36, 4,300) `0xeb7520e7…` (14:56:21).
  A first USDC deposit `0x2d4bd6fb…` (14:52:53) reverted, wrongly encoded for 4,700 USDC against a 4,300 allowance;
  nothing moved. #36 then held 3,291.44 EURC and 4,305 USDC.
- **Box: two failed proposer runs.** `numo-mm36-fund` (transient unit, `run-with-ssm-mark.sh python3
  /home/ec2-user/fund_mm36.py --propose`) tried to post the four calls for approval. MPCVault refused both
  (`createSigningRequest` HTTP 403, `code 7 Permission denied`): the box's token has no access to the vault holding
  `0x8f49…`. Nothing was posted; the unit exited and is gone. SSM `101f3a8f-…`, `f8bd6495-…`.
  `/home/ec2-user/fund_mm36.py` was deleted afterwards (SSM `61abd8b7-…`, Success); nothing is left on the box.
- **ECS**, 2026-10-26 14:58 UTC: `market-maker-eurc` created (image `market-maker:54d7ae630278`, 1 replica, account 36)
  and the execution task def replaced to add 36 to `SETTLEMENT_CANARY_ACCOUNTS` (`34,32,36`). Applied with `-var`;
  these are the defaults in `market-maker-eurc.tf` from this change.
- **Undo.** `desired_count_market_maker_eurc = 0` in `counts.auto.tfvars` and apply: the maker's orders expire within
  300 s. #36's balances withdraw by the MM wallet.

## 2026-10-25 12:13–12:33 UTC: engine keeper moved to `exchange-engine-keeper` (EURC); EURC step 4 proposed

- **`/home/ec2-user/exchange-engine-keeper`**: a new clone of numofx/exchange, detached at `76a3ec0` (#269), owned by
  ec2-user; `pnpm install --frozen-lockfile --filter perp-keeper...` and `pnpm --filter perp-keeper build` (`tsc` only;
  no forge). Its own checkout so the build could not touch `exchange-future`, which still runs `numo-future-feeds`.
- **Proof before the switch** (SSM `a96bd6d0-…`, and again inside `c34e170c-…`): the new build ran 45 s with the live
  env plus the EURC lines, `DRY_RUN=true` on port 9475, beside the live keeper: two clean passes, health reporting the
  EURC escrow, feed, 200 bps and `maxEurcInventory` 4e22.
- **`numo-engine-keeper`** (SSM `c34e170c-…`, 12:21 UTC): `/etc/numo/engine-keeper.env` backed up to
  `engine-keeper.env.bak-202610251221` and given the four EURC lines of the repo's `engine-keeper.env` (#269); drop-in
  `/etc/systemd/system/numo-engine-keeper.service.d/checkout.conf` sets `WorkingDirectory` to the new checkout's
  `services/perp-keeper`; `daemon-reload`, restart. Live on 9465: first pass ok, not dry run, EURC reported.
- **EURC step 4** (SSM `0eda4936-…` read-only gates, then `6c986435-…`): `propose_eurc_spot_batch.py --batch enable
  --rehearsed --propose` from `exchange-ops` at `539ae00`; approved in MPCVault, landed 12:32:07 UTC (block 53071090).
- **Undo, keeper.** `rm /etc/systemd/system/numo-engine-keeper.service.d/checkout.conf`; `cp -p
  /etc/numo/engine-keeper.env.bak-202610251221 /etc/numo/engine-keeper.env`; `systemctl daemon-reload`; `systemctl
  restart numo-engine-keeper`. Not while anyone holds EURC: the old build bids those accounts without a EURC haircut.

## 2026-10-25 11:36–11:53 UTC: EURC step 2 (configure) proposed from `exchange-ops` at `539ae00`

- **`/home/ec2-user/exchange-ops`** fetched and detached at `539ae00edca8a912660c57472e396fc3578cfe57` (#268, the EURC
  step-1 artifacts; was `223b8292`), clean before and after. `EURC_SPOT.json`, both `EURC_SPOT_*VAULT_ACTIONS.json` and
  `propose_eurc_spot_batch.py` matched the laptop's sha256; the proposer's self-test passed with the ABI-name step
  skipped (no forge build on the box; it passed in CI on this commit); the dry run's gates all passed and its 7 digests
  were the deploy-day rehearsal's. SSM `635ba670-…`, Success.
- **`numo-eurc-configure`**, a transient unit (`systemd-run --uid=ec2-user`, nothing written under `/etc`), ran
  `run-with-ssm-mark.sh python3 propose_eurc_spot_batch.py --propose` from 11:41 UTC so the SSM command's timeout could
  not end it mid-batch. All 7 actions were approved in MPCVault and landed 11:51:18–11:52:27; the unit exited 0 and is
  gone. SSM `c01ed919-…`. (A first attempt, `81a34e58-…`, failed before starting: `systemd-run` needs an absolute
  path. Nothing ran.)
- **Undo.** None on chain: the vault owns what landed. The checkout: `git -C /home/ec2-user/exchange-ops checkout --detach
  223b8292775d7cf872f66a7d690bde2dfb7f14d8`.

## 2026-10-25 00:08 UTC: HOLD alert test, from a throwaway checkout (nothing left on the box)

The stress check's state-change alert had only ever posted its first evaluation (PASS, 00:00 UTC). To see a HOLD reach
the channel without touching the live timer: a clone of `exchange-eurc-depth` at `8c5e60a` in
`/home/ec2-user/eurc-depth-holdtest`, with copies of the CSV and state file, ran `depth.once()` through
`run-with-ssm-readonly.sh` with the cap forced to 1,000,000 EURC and every message prefixed
`[TEST, ignore: forced HOLD …]`. A real reading (block 53048776, 95,410 EURC without the largest LP), judged against the
forced cap: the copy's last delivered state was PASS, so PASS -> HOLD posted at 00:08:33 UTC, the webhook accepted it, and it
arrived in the channel (confirmed by eye). The live CSV and state file hash the same before and after (`45c37859…`, `bb0bc570…`); the
timer did not run (next 12:00 UTC); the directory was deleted. SSM `7b0c8973-…`, Success.

## 2026-10-24 23:51 UTC: depth checkout `exchange-eurc-depth` moved to `8c5e60a` (#263 1h feed, #264 cap 40,000)

`/home/ec2-user/exchange-eurc-depth` fetched `origin/main` and detached at `8c5e60a6089d07d26b987cfe5977db30ba4c6c61`
(was `0dd20509…`), clean before and after. The units are unchanged (`ca4faac4…`, `e6373f03…`, the same as the repo's), so
no copy and no `daemon-reload`. `depth.py` imports on the box with cap 40,000, 31 columns. SSM `f59f7d7b-…`, Success.

- **What it changes.** The stress check's bar drops from 100,000 to 80,000 EURC of 2% sell depth without the largest
  LP, because `depth.py` takes the cap from the proposer's `MAX_CAP`. The 00:00 UTC 2026-10-25 reading is still the
  stress check's first evaluation, so it alerts whichever state it finds, judged against 40,000 rather than the 50,000
  the entry below expected (the last reading, 86,202, would pass).
- **Undo.** `git -C /home/ec2-user/exchange-eurc-depth checkout --detach 0dd205096cfe8e9ea6f0d9e9bf1de9f906146164`.

## 2026-10-24 18:40 UTC: depth checkout `exchange-eurc-depth` moved to `0dd2050` (#261: stress check and its alert)

`/home/ec2-user/exchange-eurc-depth` fetched `origin/main` and detached at `0dd205096cfe8e9ea6f0d9e9bf1de9f906146164`
(was `a2e48721…`), clean before and after. The units are unchanged: the installed `numo-eurc-depth.service` and `.timer`
hash the same as the repo's (`ca4faac4…`, `e6373f03…`), so no copy and no `daemon-reload`. `depth.py` imports on the box
(cap 50,000, 31 columns). SSM `bf4319bb-…`, Success.

- **What it changes.** From the 00:00 UTC 2026-10-25 reading, each reading also computes the 2% sell depth without the
  main pool's largest LP and the stress check (50% of it against the cap), and posts to `ALERT_WEBHOOK_URL` on the
  first evaluation and on every change of state. The first reading rewrites `/home/ec2-user/numo-eurc-depth.csv` in
  place with five new columns, empty for the earlier rows. Expected first alert: `first evaluation -> HOLD`.
- **Before this, one trial reading** (SSM `0db9ddda-…`, 18:1x UTC) ran the branch at `084c788` from a throwaway
  checkout with copies of the CSV and state file and the webhook blanked; all three were removed afterwards. Block
  53037169: 107,498 EURC total, 86,202 without the largest LP, stress hold; nothing posted.
- **Undo.** `git -C /home/ec2-user/exchange-eurc-depth checkout --detach a2e48721758d21c3fd69e818913126fee5b9a075`. The
  rewritten CSV still reads under the old code only after dropping the five trailing columns.

## 2026-10-21 19:50–20:10 UTC: proposer checkout `exchange-ops` at `223b829` (#254, #255: perp-cap refusals)

New checkout `/home/ec2-user/exchange-ops`, owned by ec2-user, cloned from GitHub, detached at
`223b8292775d7cf872f66a7d690bde2dfb7f14d8`, clean; sha256 of `perp_cap_guard.py` (`dc761c78…`),
`propose_perp_enable_batch.py` (`38cd01b6…`), `propose_margin_engine_batch.py` (`ba0245c9…`) and
`CNGN_PERP_ENABLE_VAULT_ACTIONS.json` (`ea7fda2d…`) matched the repo. Proposers run from here from now on; the pinned
`/home/ec2-user/exchange` (`bf9da89`, three tracked scripts edited in place, ~20 untracked copies, seven units) and
every unit are unchanged, nothing stashed. Inspection `cb1c4cc4-…` (read-only; "Failed" only on the final `ls` of the
not-yet-created checkout), checkout `c75cf36c-…`, verification `28f6a812-…` (read-only). Self-tests (enable, engine,
perp_cap_guard) passed with the ABI-name step skipped (no forge build on the box; it passed in CI on this commit). The
enable dry run, via `run-with-ssm-readonly.sh`, listed action 0 `[REFUSED]`: custody FAIL (module allowed, cap 0),
keeper FAIL (perp funding account #23 at 0 cash), quoter FAIL (no perp book), feeds, sm and pager PASS; nothing
written or proposed, checkout still clean after.

## 2026-10-21 14:06–14:09 UTC: the delisted perp's open-interest cap set to 0

Run from the box over SSM through `run-with-ssm-mark.sh`. `propose_perp_oi_cap_zero.py`, its import
`resolve_cngn_action6.py` and `deployments/8453/PERP_OI_CAP_ZERO_VAULT_ACTIONS.json` were sparse-cloned from
`main` at `06d35e1` (#251) into `/tmp/perp-oi-cap`, outside the box's pinned checkout; nothing in
`/home/ec2-user/exchange` changed. `/tmp/perp-oi-cap` was removed afterwards (SSM `f899d254-…`, Success); the
`--confirm` run was not needed, the read-back below did its job.

- **What.** MPCVault signing request `5fe66b24-9f8f-429d-aa37-7cc20a278491`: from the vault `0x1dcA…F435` to the
  PerpAsset `0xC74E…5b8E`, `setTotalPositionCap(address,uint256)` (`0x40a557bd`) with the perp SRM `0xDE04…35D4`
  and 0. Artifact digest `0x6748a90e3ae19e4051f2c88f238a92b7539be2460495d354e0d39f5ff8922f68`.
- **Why.** The perp was delisted from the venue at 13:59 UTC (#251), but `SubAccounts.submitTransfer` lets the owner
  of two accounts under the perp SRM open a perp position without Matching, bounded only by this cap (was 50M). At
  zero no transfer can raise open interest; closing is unaffected.
- **Checked first, on the box.** Dry run (SSM `036c5c86-…`, 14:06:05) and the proposing run (SSM `b0b92b48-…`,
  14:07:11) both passed: PerpAsset owned by the vault, cap 50,000,000, open interest 0, the vault's call simulates.
- **Landed.** Approved in the MPCVault app, executed in tx
  `0x77efbb8498b77e0e4fa9371d6c7044ea4e6f5e7b85052bb4a399ecbdbdc57ec7` (block 52901207, 14:09:21 UTC, status 1).
- **Read back independently.** From a laptop on a different RPC: the tx is from the vault to the PerpAsset with the
  artifact's calldata exactly; `totalPositionCap(perp SRM)` 0 and `totalPosition(perp SRM)` 0 at block 52901218.
- **Side effect.** `propose_collateral_cap.py` refuses a cNGN collateral cap above this one, so the perp SRM's cNGN
  escrow cap (50M, 5,000 held by #27) can no longer be raised. Spot and the future are margined under the
  MarginEngine, whose caps are separate (escrow 100M, future 30 contracts).

## 2026-10-21 12:06–12:07 UTC: EURC/USDC depth readings, twice a day for 7 days

Repo change #247 (`a2e4872`). One SSM run as root, command `12f42a6c-4fa8-4cf2-ab09-da60c86578e4` (stamp
`20261021T120609Z`), after a read-only inspection (`39c1969e-…`).

- **What.**
  - `/home/ec2-user/exchange-eurc-depth`: a new checkout, owned by ec2-user. Cloned from `exchange-pager`, origin
    set to GitHub, detached at `a2e48721758d21c3fd69e818913126fee5b9a075`, clean. The sha256 of `eurc_depth/depth.py`
    (`2e733a85…`), `pools.py` (`43e0ee23…`) and both units matched the repo at `a2e4872`.
  - `/etc/systemd/system/numo-eurc-depth.service` and `.timer`, copied from that checkout; `daemon-reload`;
    `systemctl enable --now numo-eurc-depth.timer`. Next runs 00:00 and 12:00 UTC.
  - The first reading started by hand, through the unit (`systemctl start numo-eurc-depth.service`).
  - New files: `/home/ec2-user/numo-eurc-depth.csv` (one row per reading) and `numo-eurc-depth-state.json` (the main
    pool's gauge scan; it resumes from there).
  - `--self-test` was NOT run on the box: it checks selectors against compiled ABIs and the box has no forge build
    (as `check_settlement_canary.py`, #238). It passed in CI on this commit.
  - Nothing else touched.
- **Why.** The EURC deposit cap is to be set at ~50% of the median 2% sell depth over 7 days of readings, and the
  engine keeper's `MAX_EURC_INVENTORY` at or below it (#247, open item 2).
- **How it was checked.** The unit exited 0 at 12:06:54. The row at block 52897513:
  - 2% depth: sell 590,051 EURC, buy 696,514 USDC; 484,445 EURC of the sell depth is in the Slipstream ts50 pool.
  - Main pool LPs: 184 staked, 82 in range; largest `0xc6bf059aabef5668c32ebeef3dae82e59d4ebc4a` at 28.8% of in-range
    liquidity; 13.5% unattributed (unstaked); `lp_check=ok`. The staked in-range positions summed exactly to the
    pool's `stakedLiquidity()`.
  - The gauge history (from block 17827325) backfilled through the provider RPC in 40 s.
  - `systemctl list-timers` shows the next run at 2026-10-22 00:00 UTC.
- **Undo.** `systemctl disable --now numo-eurc-depth.timer`; remove both units and `daemon-reload`. The CSV and the
  state file can stay. After 7 days the script samples nothing and says so; disable the timer then and run
  `--summary`.

## 2026-10-19 18:25–18:28 UTC: alert cleanup: canaries on the MarginEngine, rebalance on #34, feed-alert retired, pager mute

Every red monitor had gone stale at the MarginEngine cutover (2026-10-13/14) rather than found a fault, and one
green one checked nothing. With that much permanently red, a real alert gets ignored: the ECS canary had logged
7,471 false backing errors. Repo changes #236, #237, #238, #240 (`4cbb7e77`, and #240 for the unit's accounts). Two
SSM runs as root: the first at 18:25:39 (stamp `20261019T182539Z`), the canary unit at 18:27:42 (`…T182742Z`).

- **What.**
  - `/home/ec2-user/exchange-pager`: `386b5d98` -> `4cbb7e77` (detached, clean). Brings #236: the pager honours
    `/numo/pager/mute_matcher_dead_until` (written by `infra/aws/with-matcher-mute.sh` during a deploy, capped at
    900s, never hiding a matcher-dead already paging). Unit unchanged.
  - `/home/ec2-user/exchange/contracts/risk-core/scripts/ops/check_settlement_canary.py` (pinned checkout):
    `d34f4c73…` (= repo `6246835`) -> `6f0b6e9f…` (= `4cbb7e77`), sha256 checked before the copy. Backup
    `….bak-pre4cbb7e7-20261019T182539Z`. Sums wrapper backing across the SRM and the MarginEngine (#237), probes
    each account through its own manager, and skips the compiled-ABI check on live runs (#238: the box has no
    forge build, so every repo version since `4308573`, 2026-10-12, would have died on `abi_selectors`).
  - `/etc/systemd/system/numo-settlement-canary.service`: `CANARY_ACCOUNTS` `26,24` -> `32,34`, and
    `OTHER_MANAGERS=0xA19E…0758` (the MarginEngine) added after `SRM_ADDRESS`; the same as #240. Backup
    `….service.bak-20261019T182742Z`.
  - `/home/ec2-user/exchange-rebalance`: `aa2a49ca` -> `4cbb7e77` (detached, clean). `MM_SUBACCOUNT_ID`
    defaults to 34 (#237); 26 was refused every run since the spot maker moved on 2026-10-14. No install
    needed (the only lockfile change between the two is for `services/perp-feeds`).
  - `/etc/systemd/system/numo-heartbeats.service`: `feed-alert` removed from `HEARTBEAT_EXPECTED`, as in the
    repo's unit. Backup `….service.bak-20261019T182539Z`.
  - `feed-alert` retired: `systemctl disable --now numo-feed-alert.timer`; `numo-feed-alert.service` and
    `.timer` moved to `/root/retired-units-20261019T182539Z/` (`numo-feed-alert-ssm.service` was not installed);
    `daemon-reload`. SSM `/numo/pager/heartbeats/feed-alert` deleted at 18:28:30. The healthchecks.io check
    was deleted in the dashboard by hand (the key in SSM is read-only: the API refused, HTTP 405).
    `check_feed_staleness.py` stays: the pager and the batch proposers import it.
- **Why.** The box canary and the ECS canary read `totalPosition` for the SRM alone; the cNGN escrow's
  401,131.965850 cNGN is 5,000 under the SRM plus 396,131.965850 under the engine, exactly. They also watched
  26 and 24, both $0 since the makers moved. rebalance-check refused account 26. feed-alert watched only SRM
  market feeds, which the live markets no longer use, so it was green while checking nothing; the index it should
  have watched is paged by the pager's feed-halt, and the canary calls getSpot on it and on the stable feed.
- **Checked.** One run of each through systemd after the change: settlement-canary `success` ("ok": 32 and 34
  under the engine, $4,014.03 and $659.74; wrapper backed 1:1, 401,131.965850; cash backing, borrowers, settled
  cash, feeds); rebalance-check `success` (sub 34, cNGN 41.7%, action none); heartbeats `success` (7 checks, all
  armed); the pager's next runs `ok: 0 active` on `4cbb7e77`. healthchecks.io afterwards: heartbeats, perp pager,
  rebalance-check, settlement-canary, settlement-canary-ecs, signer-balance-alert all `up`; feed-alert gone. The
  ECS canary (execution `a74cec2c6bb5`, applied 18:14:57) reported `ok=true` from its first check.
- **Undo.** Pager / rebalance: `git checkout --detach 386b5d98` / `aa2a49ca` in each checkout. Canary: move the
  `.bak-pre4cbb7e7-20261019T182539Z` file back, and `….service.bak-20261019T182742Z` over the unit. Heartbeats:
  `….service.bak-20261019T182539Z`. feed-alert: move the units back from `/root/retired-units-20261019T182539Z/`,
  `daemon-reload`, `systemctl enable --now numo-feed-alert.timer`, and recreate its check and SSM URL.
  `daemon-reload` after any unit change.

## 2026-10-14 15:50 UTC: numo-future-feeds and the pager on `386b5d9` (#220: settle losers only while the VM pool's net is below zero)

Both moved together, so the keeper and the pager judge the same net (pool #31's USDC cash plus its cNGN at the
engine's spot feed, within $1) from the first tick.

- **What.**
  - `/home/ec2-user/exchange-future`: `95270de4` -> `386b5d98` (detached, clean). `pnpm install --frozen-lockfile
    --filter perp-feeds...` (no lockfile change), `@numo/kms-signer` and `perp-feeds` built (`tsc` only; no forge on
    the box). `dist/expiry-keeper.js` has `coverPoolDeficit`.
  - `/etc/numo/future-feeds.env`: replaced by the repo's at `386b5d9`, byte for byte (`cmp`; sha256 `9d117935…`).
    The only difference from the previous file, which was the repo's at `95270de4` byte for byte, is two lines:
    `FUTURE_MANAGER=0xA19E296021c9DF25b90D96C2A0793CC3D0800758` (required by the new config: the pool, its cash, the
    cNGN escrow and the spot feed are read through it) and `SETTLE_PER_TICK=10`. Old file kept as
    `future-feeds.env.bak-20261014`. Unit unchanged (byte-identical to the checkout's).
  - `/home/ec2-user/exchange-pager`: `292e5236` -> `386b5d98` (detached, clean). Only `check_perp_pager.py` differs
    in between; `numo-perp-pager.service`, its timer and `/etc/numo/perp-pager.env` unchanged.
  - `systemctl restart numo-future-feeds` at 15:50:34, and one pager run by hand (`systemctl start
    numo-perp-pager.service`) right after; the timer carries on every minute.
- **Why.** The hourly VM sweep settled every holder after each mark (~1,100 settlements a position over a series).
  Settlement on touch, liquidation's own settle, close-out and margin views' pending VM keep everything correct;
  what is left is timing, a winner paid from the pool before its losers pay in. #220 settles losers only while the
  pool's net is below zero, at most 10 a tick, and alerts `future-pool-deficit-stranded` once per episode if none is
  left. The pager's `future-pool-borrowing` and `future-pool-deficit-stuck` now judge the same net.
- **Checked.** Before: both checkouts clean, the env and both units byte-identical to the repo at their commits.
  After: `numo-future-feeds` active, 0 restarts, `[forward] signer 0xd65F…3650 (KMS), relayer 0xE5b8…e6de`, no
  `pool-deficit-error` (the engine reads work; with nothing owed the cover logs nothing). Pager: `ok: 0 active`, and
  its future line now reads `$0.00 cash, net $0.00`. The first mark under the new build landed on schedule at 16:12:47
  (`0x54992d11…`, book-mid, block 52602510; the three before it at 13:11:57, 14:12:12 and 15:12:25), 0 restarts. Before merge: the full `rehearse-future-fork.ts` passed, and on a
  2 s-block Base fork one capped tick (10 settlements) took 48.8 s, so a due mark waits at most ~1 min 50 s.
- **Undo.** `cp /etc/numo/future-feeds.env.bak-20261014 /etc/numo/future-feeds.env`; in exchange-future
  `git checkout --detach 95270de4` and rebuild `perp-feeds`; `systemctl restart numo-future-feeds`; in exchange-pager
  `git checkout --detach 292e5236`.

## 2026-10-14 10:50–11:55 UTC: spot market maker moved from #26 (perp SRM) to #34 (MarginEngine)

- **MM-key grant, applied and revoked.** `terraform apply -var ops_box_mm_key_grant=true` from `main` (`66da52d`,
  #219) at ~10:50 (1 add, 1 change); revoked by the apply that restarted the bot at ~11:52 (the grant's policy
  destroyed, the Deny's exception removed).
- **`/home/ec2-user/exchange-perp/scripts/local-venue/dist`** replaced by `ops/migrate-spot-mm-dist` at `e96ecc0`
  (`git fetch origin ops/migrate-spot-mm-dist && git checkout FETCH_HEAD -- scripts/local-venue/dist`, as
  ec2-user): the `migrate-spot-mm` bundle built off-box from `66da52d` (its `BUILD` says so). The previous bundle
  (`53e3d478a5a4`, 2026-10-04) predated `engine-account` and read #26's balances from the wrong escrows. Nothing else
  in exchange-perp changed; the perp keeper and feeds that run from it were not restarted.
- **Run through `run-with-ssm-mm.sh`** with the spot bot stopped (`desired_count_market_maker = 0` at 10:58):
  `withdraw` from #26 (379.658991 USDC, 381,450.280616 cNGN to the MM wallet; blocks 52594214/16), `engine-account
  379658991` (#34 under the engine, block 52594423; the first attempt's create was refused at gas estimation
  against a node behind the approve, so nothing was opened), `deposit-cngn 34`. Each phase's own post-check failed
  with "Unknown block" (the RPC lagging its receipt); every result was confirmed on chain instead.
- **After.** #34 holds 379.658991 USDC and 381,450.280616 cNGN; `mm_subaccount_id = "34"` in the operator-local
  tfvars; market-maker-spot td :35 quoting 8 levels a side from #34 since 11:55, execution td :31 with canary accounts
  "34,24". Not on the box: the venue's `SPOT_MARGIN_MANAGER_ADDRESS` / `DEPOSIT_MANAGER_ADDRESS` moved to the engine
  at ~12:15 with the trading-app deploy of `43b9368`.

## 2026-10-13 19:00–19:01 UTC: MarginEngine enable batch landed; USDC-cNGN-30NOV26 open

Run from the box over SSM: `run-with-ssm-mark.sh python3 scripts/ops/propose_margin_engine_batch.py enable --propose`
from `/home/ec2-user/exchange-pager` (`292e5236`; the proposer and artifacts are identical at main `2cf7cfd5`), with
`PAGER_STATE_FILE=/var/lib/numo/perp-pager-state.json`. Nothing on the box changed. Launched without waiting for the
outside review (decided 2026-10-13). Before it: the real-fills fork test 7/7 at `2cf7cfd5`, and a dry run with all 11
gates passing (custody, feeds, marks, reserve none, escrow, sm, pager watching the engine, keeper live, fills, rfq,
parity: 62 settings).

- **Landed** (both status 1, from the vault `0x1dcA…F435`):

  | # | Action | MPCVault | Tx | Block |
  |---|---|---|---|---|
  | 1 | `future.setTotalPositionCap(engine, 30e18)` | `4e5a6877…` | `0x2fe14fdb…203e` | 52564343 |
  | 2 | `tradeModule.setDatedFutureAsset(future, true)` | `5c96145c…` | `0xd49982bd…f675` | 52564362 |

- **Not proposed:** action 0, the perp's cap under the engine (#210): it still reads 0, deferred to the perp's cutover.
- **Between the two,** every gate re-read and passed but custody (expected: the cap was open).
- **After.** `/v1/markets` lists USDC-cNGN-30NOV26 with `fill_band_enforced` (1,229.02–1,502.14 cNGN per USDC); the
  futures market maker #32 rests three bids and three asks of 1 contract inside it.

## 2026-10-13 18:48 UTC: numo-engine-keeper out of DRY_RUN

- **What.** `/etc/numo/engine-keeper.env` replaced by main's `engine-keeper.env` (#216, `DRY_RUN=false`; the script
  refused unless the two differed only in comments and that line), old one kept as `engine-keeper.env.bak-20261013`;
  `numo-engine-keeper` restarted. The file on the box is byte-identical to main's (sha256 `591d04f1…`).
- **Why.** The MarginEngine enable batch's `keeper` gate requires a live engine keeper. It had run in DRY_RUN since
  17:39 with every pass OK and nothing liquidatable.
- **After.** Active; /health: passes OK, `dryRun: false`, manager the engine, account 33, EOA `0x753f…f83b`, no
  liquidatable or insolvent accounts, no auctions. The enable batch's `keeper` gate against that health and the chain:
  PASS ("live, not dry-run; account #33 5,000.00 cash; 0.0030 ETH").
- **Undo.** `cp /etc/numo/engine-keeper.env.bak-20261013 /etc/numo/engine-keeper.env && systemctl restart numo-engine-keeper`.

## 2026-10-13 18:37–18:38 UTC: the pager moved to its own checkout at `main`

- **What.** New checkout `/home/ec2-user/exchange-pager` at `292e5236` (main, after #212–#214), cloned from
  exchange-future with origin set to GitHub. `/etc/systemd/system/numo-perp-pager.service` replaced by #214's
  (backup `numo-perp-pager.service.bak-20261013`), `systemctl daemon-reload`. `/etc/numo/perp-pager.env`, the state
  file `/var/lib/numo/perp-pager-state.json` and the timer unchanged. `exchange-perp` (`af584bc`, the live perp
  keeper's) untouched.
- **Why.** The pager ran from exchange-perp at `af584bc`, which predates the MarginEngine: no artifact, no futures
  code, so it would page on nothing under the engine. #213's enable gate refused it on exactly that ("read the
  future under no manager").
- **How it was checked.** A preflight run of the new code against a copy of the live state, with no provider, webhook
  or heartbeat (could not page, post or ping): read the future under the engine; the only failed page was its own
  deliberate `pager-unwatched`. (The first two attempts stopped there on my check's own bugs, a pass condition that
  required an OK run and a regex that kept the colon; nothing was swapped.) The first real run after the swap: OK, via
  pushover, dead-man's switch set, `futureManager` the engine, nothing active. The deployed unit is byte-identical to
  the checkout's; the engine enable batch's `pager` gate now passes against the live state.
- **Undo.** Copy the `.bak-20261013` unit back, `systemctl daemon-reload`.

## 2026-10-13 16:43–17:05 UTC: forward publisher on `main`; #24's perp closed; MM key grant applied and revoked

- **`/home/ec2-user/exchange-future` moved to `95270de`** (main, after #207–#209), `pnpm --filter perp-feeds`
  rebuilt, `numo-future-feeds` restarted at 16:44. Unit and `/etc/numo/future-feeds.env` byte-identical to
  the repo's. Why: #207's pinned reads (the VM sweep and close-out read after their own transactions).
- **The MM key grant, applied and revoked from `main`.** `terraform apply -var ops_box_mm_key_grant=true`
  (1 add, 1 change) at ~16:51; revoked by a plain apply from `main` (0 add, 1 change, 1 destroy) at ~17:04.
  After the revoke the box's role lists no `numo-mm-key-ssm-read-one-off`, and three reads of
  `/numo/exchange/mm_private_key` from the box were each refused with an explicit deny. The first
  `--execute` after the grant was itself refused the read (IAM propagation, seconds after the apply);
  nothing was sent, and the retry two dry runs later went through.
- **#24's perp short closed against #27.** `perp-close 0.0007322 --against=27 --execute`: #24 bought
  2,502 cNGN-PERP at 0.0007322 from #27's reduce-only ask of 2,521 (tx `0xe7f9a486…3e0d`, 16:53:28). Both
  accounts read 0 perp after; the perp's total position under the SRM reads 0; the venue cancelled #27's
  remaining 19 and the book is empty. #27 is left at −0.012338 USDC cash (its fee and P&L).
- **#24 withdrawn.** `perp-withdraw --execute`: 5.297749 USDC to the MM wallet `0x3448…B47B`; #24 holds
  0.000001.
- **Why.** Perp open interest to 0 (the perp is close-only, no market maker), which frees #23's cash
  to fund the engine keeper.
- **The engine keeper's key, 17:00.** A fresh key generated straight into SSM `/numo/keeper/engine_keeper_key`
  (SecureString, `alias/aws/ssm`), never printed or written outside a 0600 temp file deleted in the same
  step; EOA `0x753fCC2342F180e1B9B0BfFFEb21f4E00741f83b`. The box reads it under its existing
  `/numo/keeper/*` grant and derives that address. Nothing installed yet.
- **Its funding account, #33.** 0.003 ETH sent to the EOA (by hand); then, from the box with that key,
  `SubAccounts.createAccount(0x753f…f83b, MarginEngine)` (tx `0x48cdd972…96aa`, block 52561572): #33, owned by
  the EOA directly (not Matching), manager the engine.
- **The perp keeper's cash floor to 0, ~17:34.** `/etc/numo/perp-keeper.env` backed up to
  `perp-keeper.env.bak-20261013`, `MIN_KEEPER_CASH_USD=0` added after `MIN_KEEPER_ETH`, `numo-perp-keeper`
  restarted: active, first pass ok, not dry run (its build reads the variable). Why: its $5,000 moves to the
  engine keeper next, and with perp OI 0 and the perp close-only it has nothing to liquidate; without this it
  alerts on low cash. Restore the default (1000) with its funding when the perp reopens. Template updated.
- **#23's cash to #33.** From the box: the perp keeper's key `CashAsset.withdraw(23, 5000 USDC, 0x753f…f83b)`
  (tx `0x40adb7e9…61f0`, block 52561837); the engine keeper's key `USDC.approve(CashAsset, 5000)` (block
  52561848) and `CashAsset.deposit(33, 5000)` (tx `0x6eab5e82…5b82`, block 52561849). After: #33 holds
  5,000 cash and nothing else; #23 holds 0.0000023 (interest); the EOA 0 USDC, 0.002997 ETH.
- **`numo-engine-keeper` installed, DRY_RUN, ~17:39.** In `/home/ec2-user/exchange-future` (`95270de`):
  `pnpm --filter perp-keeper` built; `/etc/numo/engine-keeper.env` and
  `/etc/systemd/system/numo-engine-keeper.service` written from this branch's `engine-keeper.env` and
  `numo-engine-keeper.service`; enabled and started. /health on 127.0.0.1:9465: passes ok, `dryRun: true`,
  manager the engine, account 33, EOA `0x753f…f83b`, nothing liquidatable. The enable batch's `keeper` gate
  against that health and the chain: FAIL "keeper is in DRY_RUN", and PASS with only `dryRun` false (#33
  5,000.00 cash, 0.0030 ETH). Undo: `systemctl disable --now numo-engine-keeper`.

## 2026-10-13 13:56–14:45 UTC: perp maker stopped; #24's cash moved to the futures maker's engine account #32

Signed on the box with the MM key from SSM, through `run-with-ssm-mm.sh` and `scripts/local-venue/migrate-spot-mm.ts`
in `/home/ec2-user/exchange-future` (moved to `04397223` (#196), then `98e9c9ae` (#197); `pnpm install
--filter @numo/local-venue` there). The operator's plan, with #27's owner's sell for #24's short still to come.

- **Perp maker stopped.** `desired_count_market_maker_perp = 0` in the operator-local `counts.auto.tfvars`
  (comment says why), applied with the grant below; task `5a90356b…` STOPPED 13:57:37 UTC
  (`wait-for-rollout.sh`). mm-bot does not cancel on SIGTERM; `perp-cancel` found its 20 orders, which had
  expired (300 s) by the execute run. The perp book has been empty since; spot (#26) untouched.
- **MM-key grant, one parameter, temporary.** Applied from `main` with `-var ops_box_mm_key_grant=true`
  (#196): `numo-mm-key-ssm-read-one-off` (ssm:GetParameter on `/numo/exchange/mm_private_key` only) and that
  ARN excluded from the explicit Deny. **Removed ~14:44 UTC** by an apply from `main` (0 add, 1 change,
  1 destroy); from the box the read is refused (`AccessDeniedException … explicit deny`), `/numo/feeds/*`
  still reads. Re-add the same way, briefly, for #24's close.
- **Withdrawal.** `perp-withdraw 4002000000` (#197: refused if under \$4 of IM surplus would remain):
  tx `0xa2556f5b4f70656bdd844e468b08d89318d3ae496b8a7b059832fa6dc12d9048`, block 52555595, 4,002 USDC to the MM
  wallet `0x3448…B47B`. #24 keeps \$5.30 of cash and its -2,502 cNGN short (IM surplus \$4.69, MM \$4.94).
- **Engine account.** `engine-account 4002000000`: approve `0xc8b8e879f95c7ee6f826ee9549512f594cb7bb9f75c4e6650fbaf38274b61faa`
  (block 52555669), `createAndDepositSubAccount(perp cash, 4,002 USDC, MarginEngine)`
  `0x9c8d73a1660474baa75ab647465be1ca877f1cd366e563bee054acf8adfe04ea` (block 52555670): **#32**, under
  `0xA19E…0758`, the MM's in Matching, 4,002 cash and IM surplus. The script's own read-back saw `0x0` from a
  node a block behind and exited non-zero; read from the chain directly the account is right. Fixed in #198.
- **Still open.** #24's short closes against #27 (`perp-close <price> --against=27`), then `perp-withdraw`
  takes the last \$5.30. Perp close-only (#199) before the futures maker starts (#200).

## 2026-10-13 13:05 UTC: numo-future-feeds installed and started (the cNGN future's forward publisher)

New on the box; nothing existing was changed. numo-perp-feeds, numo-perp-keeper and the exchange-perp
checkout they run from (`af584bc`) are untouched.

- **What.**
  - `/home/ec2-user/exchange-future`: a new clone of numofx/exchange at `main` `ac79698` (#193), owned
    by ec2-user; `pnpm install --frozen-lockfile --filter perp-feeds...`, then `@numo/kms-signer` and
    `perp-feeds` built. Its own checkout, so building it could not replace the dist the perp services
    load.
  - `/etc/numo/future-feeds.env`: `contracts/risk-core/scripts/ops/future-feeds.env` at `ac79698`,
    byte for byte (`cmp`). No secret.
  - `/etc/systemd/system/numo-future-feeds.service`: the repo's unit at `ac79698`, byte for byte;
    `systemctl enable --now`.
  - Not on the box, but for it: SSM `/numo/feeds/forward_relayer_key` (SecureString, alias/aws/ssm,
    created 13:00 UTC with `--no-overwrite`), relayer `0xE5b8541dC2558f3db65aF88A2374e464AE4ae6de`,
    funded with 0.005 ETH. The signer is the KMS key `alias/numo-exchange-forward-signer`
    (`0xd65F…3650`, 2026-10-13, #185/#186).
- **Why.** The future sat at the deploy's initial mark; the enable batch's `marks` gate needs it marked
  within 2 h, and the futures market maker is not to start before marks are landing.
- **Checked first.** Locally and then on the box with the box's own role, `DRY_RUN=true`: KMS signer
  `0xd65F…3650`, relayer from SSM, mark 1387.01 from carry (index 1365.8, CARRY 0.118), unclamped,
  nothing sent. The dry run on the box sent one real `forward-mark-late` alert (last mark 7442 s old),
  which is the alert path working.
- **Landed.** The first mark at 13:06:11 UTC: tx `0xd9baae1b61a30aeb988ba86d5da61e1e17359eccd81de9619f4894e01fd779c4`
  (block 52553712, status 1, from the relayer). `futureContracts(1796047200)` reads markPrice
  1387.013149315333732004 (was 1386.044666769033003345) and lastMarkTime 1791896771. Two
  transactions cost the relayer ~0.0000013 ETH.
- **Not done.** The relayer is not in the signer-balance alert (it watches one address and each needs
  its own heartbeat); `forward-mark-late` pages within 2 h if it runs dry.

## 2026-10-13 11:26–11:50 UTC: MarginEngine setup batch landed

Run from the box over SSM through `run-with-ssm-mark.sh`. `propose_margin_engine_batch.py`, its six
imports and the artifacts it reads were copied from `main` into `/tmp/me-setup` (first run `5ee56d2`,
the resumed run `34b8bb7`), deleted after the run, so nothing on the box changed.

- **What.** `MARGIN_ENGINE_VAULT_ACTIONS.json`, ten actions from the vault `0x1dcA…F435`: accept the
  engine, viewer, future and forward feed the deployer nominated; whitelist the engine on the perp cash,
  the cNGN escrow (cap 100M), the perp and the auction; set the engine's guardian to the SRM's
  `0xDb71…3C31`. Opens nothing.
- **Why.** The MarginEngine stack deployed closed on 2026-10-13 (#187); this hands it to the vault and
  wires it into the perp stack, ahead of the enable batch.
- **The first run stopped after action 0.** `acceptOwnership()` on the engine mined in block 52550709 and
  the engine was the vault's from that block, but the proposer read `owner()` at `latest` from a node a
  block behind and stopped on "postcondition does not hold". Fixed in #188 (every post-mining read retries
  through `await_postcondition`); the resumed run skipped action 0 as landed.
- **Landed** (all status 1, all from the vault):

  | # | Action | Tx | Block |
  |---|---|---|---|
  | 0 | engine `acceptOwnership()` | `0x840c5951…7601` | 52550709 |
  | 1 | viewer `acceptOwnership()` | `0x64b23715…c971` | 52551289 |
  | 2 | future `acceptOwnership()` | `0x17173dc7…52b5` | 52551374 |
  | 3 | forward feed `acceptOwnership()` | `0xf2bf9cd2…3d2a` | 52551383 |
  | 4 | `cash.setWhitelistManager(engine, true)` | `0xc72fb4b7…5233` | 52551389 |
  | 5 | `escrow.setWhitelistManager(engine, true)` | `0x750d670c…fa08` | 52551394 |
  | 6 | `escrow.setTotalPositionCap(engine, 100M)` | `0x2a819fb4…f08a` | 52551410 |
  | 7 | `perp.setWhitelistManager(engine, true)` | `0xd4f4b4d7…992f` | 52551417 |
  | 8 | `auction.setWhitelistManager(engine, true)` | `0xbdd63727…c7c2` | 52551430 |
  | 9 | `engine.setGuardian(0xDb71…3C31)` | `0x6e9c673d…ee26` | 52551437 |

  The proposer's post-setup parity passed: all 62 settings as deployed, the deployer holds nothing.
- **Read back independently.** From a laptop on a different RPC: the four contracts owned by the vault
  with no pending owner; cash, escrow, perp and auction take the engine; escrow cap 100M; guardian set;
  still closed (perp and future caps under the engine 0, the future not on the TradeModule); deployer
  `0x67DB…F737` nonce still 38; the SRM's perp cap untouched at 50M.

## 2026-10-12 20:15 UTC: RfqModule retired on Matching

Run from the box over SSM through `run-with-ssm-mark.sh`. `propose_retire_rfq_module.py`, its
import `resolve_cngn_action6.py` and `deployments/8453/RFQ_MODULE_RETIRE_VAULT_ACTIONS.json` were
copied from `main` at `b9b70d5` (#182) into `/tmp/rfq-retire`, deleted after the run, so nothing on
the box changed.

- **What.** MPCVault signing request `64d0928d-89f9-491a-87b3-4e6e61717fda`, PENDING: from the vault
  `0x1dcA…F435` to Matching `0x9E90…F191`, `setAllowedModule(address,bool)` (`0xb1b62825`) with the
  RfqModule `0x8399…62D3` and `false`. The calldata read back from MPCVault recomputes to the
  artifact's digest `0x41d668ad…4d0f`.
- **Why.** RFQ is not supported. The module had been allowed on Matching since its deploy, quoting
  in the frozen DFXM cash, and would price a dated-future leg as an option premium.
- **Checked first, on the box.** The dry run and the proposing run both passed: Matching owned by
  the vault, `allowedModules(RfqModule)` true, the vault's call simulates, and blocks
  48833365–52523401 hold 3 logs from the module, all ownership. Nothing has ever been sent
  through it.
- **Landed.** Approved in the MPCVault app, executed in tx
  `0x5ab98ed1f84680ce46f4c5a3c1f892a262411250a4d8db3166274617f1a474db` (block 52523521, status 1).
  `--confirm` from the box at 20:20 UTC read `allowedModules(RfqModule)` back as false.
- **Read back independently.** From a laptop on a different RPC: `allowedModules(RfqModule)` false;
  the tx is from the vault to Matching with the proposed calldata; `allowedModules` of the cNGN
  TradeModule `0xDea9…699f` still true. The margin-engine enable batch's `rfq` gate now passes.

## 2026-10-11 11:20 UTC: 35 stale `setMarkPrice` signing requests rejected in MPCVault

Run from the box over SSM through `run-with-ssm-mark.sh`. The script was a throwaway in `/tmp`,
deleted after the run, so nothing on the box changed. The change is in the vault's queue.

- **What.** `rejectSigningRequest` on the 35 requests that were still PENDING. Each was a
  `setMarkPrice(uint96,uint64,uint256)` (`0x272e3661`) from the mark keeper to the SEP-16-2026 future
  `0xDd9c…A1F9`, subId 1789567201, created 2026-08-16 to 2026-09-01. Before rejecting, each request
  was read back and rejected only if it was still PENDING, to that future, with that selector. All
  35 passed and were rejected.
- **Why.** The series has expired. Executed now, each would revert in `setMarkPrice` (mark time not
  after the last mark, settlement price already set, stale mark). Left in the queue, they made an
  approve in the app easy to get wrong. Rejection is permanent.
- **Read back.** `getSigningRequestList` afterwards: 965 SUCCEEDED, 35 FAILED, 0 PENDING. The API
  reports a rejected request as FAILED.
- **Also established.** The same listing, back to 2026-08-15, holds no request for the stage (B)
  leverage batch (`setPerpMarginRequirements`, or `setBaseAssetMarginFactor(1, 0.35e18, …)`), so
  that batch was never proposed. Every request to the perp SRM `0xDE04…35D4` in the window succeeded.

## 2026-10-09 14:58 UTC: low-priority Pushover drill

Ran the real `check_signer_balance.py` with `WARN_RUNWAY_DAYS=100` (forcing a finding) through
`run-with-heartbeat.sh`'s low-priority path, as `[TEST]`, under a throwaway name. The webhook was
empty so nothing went to Slack, and the real checks were not touched. The wrapper wrote its
"sent" state, which it does only after Pushover's API accepts the message. **Pending:**
confirmation that a *silent* `[TEST] numo test-drill (low priority)` notification arrived.

## 2026-10-09 14:56:35 UTC: $10 account floor, and the priority split

From #145 (`aa2a49c`). Backups are `*.bak-preaa2a49c-20261009T145635Z`.

- **Canary floor.** `check_settlement_canary.py` (`a310ea6e…`): each watched account must be worth at
  least `CANARY_MIN_ACCOUNT_USD` (default $10) by the manager's own `getMarginAndMarkToMarket`, in
  place of the non-zero test. Proved live: under its old configuration (old SRM, account 15) the
  canary fails with `subaccount 15 is worth $0.000781, under the $10 floor`. Under the current one,
  26 ($660.19) and 24 ($4,000.32) pass.
- **Priority split.**
  - *High*: canary findings, missed runs, monitors that could not run, and the arming job, all
    through healthchecks.io's Pushover integration.
  - *Low* (priority -1, silent): a stale feed, low signer gas, a due rebalance. The wrapper sends
    these to Pushover itself, using `/numo/pager/pushover_*`, once when a finding starts and at most
    every 6 h while it lasts, and pings the check as a success because the monitor ran.
  - To tell the two apart, the monitors now exit 1 for a finding and 2 for "could not run":
    - `check_feed_staleness.py` (`d227ec4b…`) is `main`'s version plus that change. It replaces the
      box's hand-edited 2026-09-22 copy (blob `86d9b42`), so this file now matches the repo. The perp
      section it adds skips on this checkout, which lacks `CNGN_PERP_STACK.json`; the perp pager
      covers those feeds.
    - `check_signer_balance.py` (`5ace796c…`).
    - The rebalance CLI gains `check --exit-code`.
  - Units `numo-feed-alert` (`aaaeb8a2…`), `numo-signer-balance-alert` (`54c1ee75…`) and
    `numo-rebalance-check` (`f9532a50…`) set `HEARTBEAT_FINDING_EXIT=1`. The rebalance unit now
    runs `node --import tsx` directly: `pnpm` reports any failing script as exit 1, which would have
    turned a failed run into a low-priority "due".
  - `~/exchange-rebalance` moved to `aa2a49c`, clean; dependencies unchanged.
- **Verified.** All four monitors ran through systemd with exit 0 at 14:57, and every check is `up`.
- **Not verifiable by API.** The healthchecks.io Pushover integration's own priority, which sets
  the level of every *high* page. It must be set to High in the dashboard.

## 2026-10-09 14:50 UTC: high-priority phone drill

Created a throwaway check `[TEST] drill` (Pushover and email), pinged it up at 14:50:31 and failed
it at 14:50:36. The healthchecks.io flip log shows up, then down at 14:50:37, so the down
notification was sent. The check was deleted afterwards. **Pending:** confirmation of the phone
alert.

## 2026-10-09 11:12–11:24 UTC: heartbeats for every ops-box monitor, and a rebalance-check timer

From #145 (`90b08b7`, then the fix `61f2ff4`), not yet merged at install time.

**healthchecks.io** (the project that already holds the perp pager's check; Pushover and email
integrations on every new check, as on the pager's):

| check | timeout | grace | pinged by |
|---|---|---|---|
| `settlement-canary` | 5 min | 5 min | `numo-settlement-canary.service` |
| `feed-alert` | 1 min | 3 min | `numo-feed-alert.service` |
| `signer-balance-alert` | 6 h | 1 h | `numo-signer-balance-alert.service` |
| `rebalance-check` | 15 min | 15 min | `numo-rebalance-check.service` (new) |
| `heartbeats` | 1 day | 2 h | `numo-heartbeats.service` (new) |

Deleted the signup sample check "My First Check" (status new, 0 pings, nothing behind it): the
arming job would have paged about it every day.

**SSM** (under `/numo/pager`, the one new-to-the-box path its role may read; no IAM change):
`healthchecks_api_key` (read-only; a write was tested and refused with 401) and
`healthchecks_api_key_rw` (used to create the checks, not read by the box), both written by the
operator. The checks' ping URLs are at `heartbeats/<check name>`. **`healthchecks_api_key_rw` was deleted on
2026-10-10** after confirming nothing in the repo or on the box reads it; creating a new check now needs a write key
issued afresh in Healthchecks and removed again afterwards.

**On the box:**

- New checkout `~/exchange-rebalance` at `90b08b7`, clean; `pnpm install --frozen-lockfile --filter
  cngn-rebalance...` and `@numo/kms-signer` built. It is the rebalance timer's working directory.
  A third checkout, which is what #143 is for.
- Copied into `~/exchange/contracts/risk-core/scripts/ops/` (untracked there):
  `run-with-heartbeat.sh` (`7eccb26b…`), `run-with-ssm-readonly.sh` (`7c49116c…`),
  `check_heartbeats.py` (`f57c21a8…`, then `33e773ba…` from `61f2ff4`).
- Units into `/etc/systemd/system/`, with backups `*.bak-pre145-20261009T111946Z` where one existed:
  `numo-settlement-canary.service` (`d2988f7a…`), `numo-feed-alert.service` (`ecbd2db1…`), and
  `numo-signer-balance-alert.service` (`679bac91…`), each now wrapped in `run-with-heartbeat.sh`;
  new `numo-rebalance-check.service`/`.timer` (`0cdfa180…`/`fcc62173…`) and
  `numo-heartbeats.service`/`.timer` (`e00f02ab…`, then `170a4969…` from `61f2ff4`/`ab980b63…`).
  Then `daemon-reload`, and `enable --now` for both new timers. Every file was sha256-verified on
  the box before any was moved into place.

**The fix at 11:22:41.** On its first run the arming job's own check is still "new" (the success
ping is sent after it exits), so it flagged itself. It now skips its own check (`HEARTBEAT_SELF`).
Caught before it ran.

**Verified (a first ping from every check).** By 11:24 every check read `up` on the healthchecks.io
API: settlement-canary, feed-alert, signer-balance-alert (started by hand rather than waiting for
13:08), rebalance-check (account 26, rate 1357.32, action none), and heartbeats (`ok: 6 checks, all
armed`).

**Behaviour change.** A monitor that exits non-zero now pages Pushover through healthchecks.io as
well as posting to Slack: a stale live feed, feed-signer gas under 7 days (it was at 8.8 at
install), a canary finding, or a rebalance that is due or failed to run.

**Not yet.** `settlement-canary-ecs` (the execution-service canary's own heartbeat) is created at
the #138 apply: its SSM parameter must exist before that apply, and the check would sit in "new"
until the image that pings it runs.

**Rollback.** Move each `.bak-pre145-*`/`.bak-pre61f2ff4-*` back; `systemctl disable --now
numo-rebalance-check.timer numo-heartbeats.timer`; remove the two new units and `daemon-reload`;
pause the five checks in healthchecks.io so they do not page.

## 2026-10-09 11:06–11:08 UTC: [TEST] alert drill to the ops channel

**What.** Proved canary alert delivery end to end, after a heads-up in the channel:

1. 11:06:43, heads-up posted to the ops webhook (HTTP 200).
2. 11:07:43, the deployed canary run through `run-with-ssm.sh` (the real webhook from SSM), with
   the installed unit's environment plus `EXPECTED_NET_SETTLED_CASH=1` and `--test`. It printed
   `[TEST] NUMO COLLATERAL BACKING FAILURE` and exited 1.
3. 11:07:52, all-clear posted (HTTP 200).

Nothing on the box changed. **Pending:** confirmation that all three messages appeared in the
channel, in order. The canary posts with its own `urllib` call, and its delivery result was not
captured.

## 2026-10-09 11:05:31 UTC: settlement canary config assertions and --test

**What.** Replaced `contracts/risk-core/scripts/ops/check_settlement_canary.py` with the version
from `90b08b7` (#145, not yet merged), sha256 `25f06d30…a6a2e2`. The previous version (`d52f1da`,
deployed at 10:45:13 below) is kept as `….bak-pre145-20261009T110531Z`. The unit file is unchanged.
Checksum verified on the box before the move, and the selector self-test passed in place.

**Why.** `getMargin` passes on an account that does not exist or holds nothing, which is how this
canary watched an emptied account 15 for five days. The canary now fails, under the headline
`NUMO SETTLEMENT CANARY MISCONFIGURED`, if a configured account does not exist, sits under another
manager, or holds nothing. `--test` prefixes `[TEST] ` to a drill's alert.

**Verified.** Green through systemd at 11:05: `subaccount 26 under the SRM, 2 non-zero balance(s)`,
the same for 24, then the usual checks.

**Rollback.** Move `check_settlement_canary.py.bak-pre145-20261009T110531Z` back.

## 2026-10-09 10:45:13 UTC: settlement canary moved to the unified stack

**What.** Replaced two files, copied from `d52f1da` (#139, not yet merged at deploy time). No
`git pull`; nothing else on the box was touched.

| file on the box | sha256 deployed | previous version kept as |
|---|---|---|
| `contracts/risk-core/scripts/ops/check_settlement_canary.py` | `629b6a65…c419c3` | `….bak-pre139-20261009T104513Z` |
| `/etc/systemd/system/numo-settlement-canary.service` | `529aa64b…e83dd4` | `….bak-pre139-20261009T104513Z` |

Then `systemctl daemon-reload`. Checksums were verified on the box before the files were moved
into place, and the script's selector self-test passed in place.

**Why.** The box's canary still watched the retired spot stack: `CANARY_ACCOUNTS=15` under the
old SRM `0x3195Bd7e…`. Account 15 has been empty since the 2026-10-04 unified cutover, so the
canary reported `ok: getMargin(15) = 0.000781` every five minutes while proving nothing. It now
checks accounts 26 and 24 under the perp SRM `0xDE0423D0…`, pins `EXPECTED_NET_SETTLED_CASH=0`
(the perp CashAsset's value), and checks fee account 22 (`FEE_*`, mirroring `infra/aws/ecs.tf`).

**Verified after the change.**

- Green, through systemd (the real unit, `run-with-ssm.sh` and the webhook), at 10:45:40 and again
  on the timer at 10:50:47: `getMargin(26) = 490.33`, `getMargin(24) = 3997.79`, cash 12580.04
  fully backed, wrapper `0x37c976…` 1:1, fee account 22 accrued 0.419273.
- Red: the deployed script, run with the installed unit's environment plus
  `EXPECTED_NET_SETTLED_CASH=1` and an empty webhook (so the ops channel was not paged), exited 1
  with `netSettledCash MOVED`. Webhook delivery was not exercised by this test.

**Rollback.** Move the two `.bak-pre139-20261009T104513Z` files back, then `systemctl daemon-reload`.

**Found on the box at the same time, left as is.**

- `contracts/risk-core/scripts/ops/check_feed_staleness.py` is modified against the box's HEAD. It
  is not lost work: it hashes to blob `86d9b42`, which this repo already has from commit `7756a5f`
  (2026-09-29). The file on the box is dated 2026-09-22, so it was edited there first and committed
  identically a week later. The box's diff is saved as
  `ops-box-records/2026-10-09-check_feed_staleness.box.diff`; applied to `bf9da89` it reproduces
  `86d9b42` exactly. `main` has moved on since (blob `d08137f`), so the box runs an older version.
- `check_mark_staleness.py` and `check_signer_balance.py` are modified against the box's HEAD but
  equal `main`'s current versions.
- `check_settlement_canary.py` was untracked in the box's checkout (it was hand-copied there; the
  version it replaced dated from 2026-09-10).

## 2026-11-04: services moved off the markets API's /v1 paths

The public `/v1` routes were deleted from markets-service, so everything on this box that called them was moved first.
Each checkout stays on its pinned commit: `main` carries the same path change (`065211e`), so a later move to `main`
needs nothing from here, except that the `spot.ts` edit below must be discarded first or `git checkout` will refuse.

- `exchange-feeds`, `exchange-future-v2`, `exchange-vol`: `services/perp-feeds/dist/book.js` now calls `/book`. `dist` is
  gitignored, so the checkouts stay clean, and a rebuild from a pinned commit would restore `/v1/book` and fail with 404.
  Backups are `book.js.bak-20261104` beside each. `numo-perp-feeds`, `numo-vol-feeds` and both
  `numo-future-feeds-v2@` instances were restarted one at a time at 16:48-16:49 UTC.
- `exchange-rebalance`: `services/rebalance/src/spot.ts` calls `/markets`. This leaves the checkout's tree dirty by one
  file. Backup is `/home/ec2-user/spot.ts.bak-20261104`. No restart: the timer runs it from source.
- `/etc/numo/perp-pager.env`: added `MATCHER_HEALTH_URL=https://api.numofx.com/health`, because the pinned
  `check_perp_pager.py` defaults to `/v1/health`. Backup is `perp-pager.env.bak-20261104`.

Not changed: `INDEX_STATUS_PUSH_URL` keeps `/v1/internal/index-status`, which is still served. `exchange-perp`'s
`dist/book.js` still says `/v1/book`, because no running service uses that checkout's feeds.
