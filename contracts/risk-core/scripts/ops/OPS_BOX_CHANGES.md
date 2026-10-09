# Ops box changes

Every change made to the ops box (`i-06107393582d770e3`) by hand, recorded the same day. The box
is not provisioned from this repo: its checkout at `/home/ec2-user/exchange` is pinned at
`bf9da89` (2026-07-22) and individual files are copied over it. Until that is fixed, this file is
the only place the box's real state is written down. Newest first.

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
