# Ops box changes

Every change made to the ops box (`i-06107393582d770e3`) by hand, recorded the same day. The box
is not provisioned from this repo: its checkout at `/home/ec2-user/exchange` is pinned at
`bf9da89` (2026-07-22) and individual files are copied over it. Until that is fixed, this file is
the only place the box's real state is written down. Newest first.

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
