# Working in this repo

## Write back hand changes the same day

Anything applied by hand — over SSM to the ops box, with `cast send`, through the MPCVault app,
or with a `terraform apply` from a branch — must land in the repo the same day, in a commit that
says what changed on the machine and why.

This is not tidiness. Config that exists only on a box is silently reverted by the next routine
action, and the reversion looks like nothing happening:

- `EXPECTED_NET_SETTLED_CASH` was applied to the ops box over SSM and not written back. A
  `git pull` there would have restored a permanently-red canary, by doing something ordinary.
- `MM_SUBACCOUNT_ID` was repointed from the frozen DFXM account 10 to 15 on `main`, then a
  `terraform apply` from a feature branch that predated it put it back to 10. Caught only by
  checking the market maker's config before unpausing it, not by anything automatic.

Two habits that follow:

- **Applying infra from a branch reverts anything merged to `main` since that branch last
  synced.** Merge `main` in first, then read the plan's env deltas and confirm every one is
  intended. A plan that touches more than you expect is the warning.
- **After any hand change, re-read the deployed state** rather than the file you edited. They are
  different claims.

## Verify by breaking it

`./scripts/verify.sh` runs exactly what CI runs; a check that lives in only one place is how
"green" comes to mean two different things.

For anything that alerts, guards or asserts: prove it fires. Every unexercised alert path checked
in this repo has turned out not to work — a canary that was reported as "watching" twice while
reaching nobody, a recovery message that never fired because the fix was a redeploy, a test whose
comment claimed a protection it did not implement. Break it, watch it go red, put it back.

## Measure a deploy after the rollout, never across it

ECS keeps the old task running until the new one is healthy, and both write to the same log group.
A window that contains the cutover therefore measures two versions at once, and the old one's
behaviour is attributed to the new.

This produced a full afternoon of wrong conclusions. A fix that removed 99% of the market maker's
order churn (13.57 -> 0.14 size_mismatch per minute) was measured across its own rollout, read as
a 16% improvement, declared broken, and chased through two further hypotheses and a diagnostic
deploy. Splitting the same logs by stream showed the draining container had produced nearly every
event being counted — its last cancel landed 35 seconds after the new task started.

Two habits that follow:

- **Wait for the old task to stop, not for the new one to report COMPLETED**, before the window
  opens. `rolloutState: COMPLETED` says the new task is healthy; it does not say the old one is
  gone.
- **When a log group is shared, attribute by `logStreamName` before drawing any conclusion.**
  One stream is one task is one image. A per-stream count is evidence; a per-group count across a
  rollout is not.

The general form: when a number disagrees with a result you can derive another way, suspect the
measurement before rewriting the code. Each wrong turn here came from inferring a quantity rather
than isolating it.

## Chain state moves under tests

Fork tests that describe a world before a transaction must pin an explicit block, and the world
after it is asserted at head. Repointing a transition test at current state makes it pass while
deleting the coverage. This has happened four times: the market-1 batch, the cNGN batch, a cap
test that assumed an empty venue, and the DFXM cash freeze.

## Vault actions

`onlyOwner` calls come from the vault (`Numo-Manager-Admin`), never from a funds wallet. MPCVault
defaults to whichever wallet was last used, and three actions failed this way in one day. Prefer
proposing through `scripts/ops/propose_*.py`, which sets `from` to the recorded vault and refuses
otherwise — every action proposed that way landed first time.

`Send <token>` builds `transfer(to, amount)` and cannot carry calldata. A contract call is always
a **Custom transaction**. Sending a deposit through the Send flow puts the tokens somewhere with
no ledger credit and, for a `WrappedERC20Asset`, no way to get them back.

Digest conventions differ between batch scripts: `cngn-spot-batch.sol` hashes
`keccak(to ‖ keccak(data))`, `deploy-wrapped-quote-trade-module.s.sol` hashes `keccak(to ‖ data)`.
Recompute with the formula belonging to the script that emitted the artifact.

## Selectors

Derive them with `cast sig`, never by hand. The self-tests in `scripts/ops/*.py` exist because
hand-written selectors were wrong four separate times, and a wrong selector fails silently — the
call reverts or reads empty space, and the surrounding code treats that as "not done yet".
