# Ops box changes

Every change made to the ops box (`i-06107393582d770e3`) by hand, recorded the same day. The box
is not provisioned from this repo: its checkout at `/home/ec2-user/exchange` is pinned at
`bf9da89` (2026-07-22) and individual files are copied over it. Until that is fixed, this file is
the only place the box's real state is written down. Newest first.

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
