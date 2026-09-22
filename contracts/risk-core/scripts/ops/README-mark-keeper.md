# Mark keeper ops

Automates `setMarkPrice` on the SEP-16 deliverable FX future, signed unattended by the
MPCVault Client Signer. Design: `../../docs/mark-keeper-design.md`. Runs on the publisher EC2.

## Components
- `../mark_keeper.py` — loop: read spot + on-chain mark, clamp (≤4.5% step), submit setMarkPrice
  via MPCVault `createSigningRequest` → `executeSigningRequests`. `--dry-run` prints the calldata.
- `../mark_callback.py` — the MPCVault client-signer callback: approves ONLY setMarkPrice to the
  future with bounded params; rejects everything else. Fail-closed.
- `check_mark_staleness.py` (+ `numo-mark-alert.*`) — alerts if the mark goes >45m stale or
  drifts >150bps from spot. **This is safe to run today and is the safety net for manual marks.**
- `render-signer-config.sh` — builds the client-signer `config.yml` from the on-host ed25519 key
  + the vault uuid in SSM.
- `numo-mark-callback.service`, `numo-mark-signer.service`, `numo-mark-keeper.service` — the
  unattended stack (callback → client-signer container → keeper).

## Before unattended: rehearse the callback (protobuf handled via the REST lookup)
The callback body is a raw `SigningRequest` protobuf and MPCVault doesn't publish the `.proto`
— so instead of decoding it, `mark_callback.py` pulls the request UUID out of the body (regex)
and fetches the tx via REST `getSigningRequestDetails` (returns `{to, input, value}` as JSON),
then validates with `check()`. No `.proto` needed. UUID-extraction / input-normalization /
validation are unit-tested; the only unverified bit is the live `getSigningRequestDetails`
response nesting + `input` encoding (hex vs base64) — **rehearse ONE setMarkPrice on a throwaway
series** to confirm, then enable the signer + keeper services. (proto ref if ever needed:
github.com/mpcvault/mpcvaultapis)

Until rehearsed + enabled, **DO NOT** `enable` `numo-mark-signer` / `numo-mark-keeper` — set marks
**manually**: `python3 ../mark_keeper.py --once --dry-run` → paste the calldata into an MPCVault
custom tx to `0xDd9c2Ddf97a2Dc9B9d348DcD0ef776aF5291A1F9` (Base) → approve. Margin/liquidation
runs off the (already automated) spot feed, so a manually-updated mark is safe; the staleness
alert catches lag.

## SSM params to set (SecureString, prefix /numo/mark-keeper)
```
aws ssm put-parameter --type SecureString --name /numo/mark-keeper/mpcvault_token --value '<x-mtoken>'
aws ssm put-parameter --type SecureString --name /numo/mark-keeper/mpcvault_vault --value '<vault-uuid>'
aws ssm put-parameter --type SecureString --name /numo/mark-keeper/vault_address  --value '0x1dcA42ab54Bd3862853A821F84B29BF65245F435'
aws ssm put-parameter --type SecureString --name /numo/mark-keeper/callback_secret --value '<random>'   # optional
# rpc_url / alert_webhook_url fall back to /numo/feeds/* if unset
```
The ed25519 signer private key stays on the host at `~/.mpcvault/client-signer-key` (never in SSM
or git). The instance role needs `ssm:GetParameter` on `/numo/mark-keeper/*`.

## Install
```
# safety net — do this for launch:
cp numo-mark-alert-ssm.service /etc/systemd/system/numo-mark-alert.service
cp numo-mark-alert.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now numo-mark-alert.timer

# unattended stack — ONLY after the callback .proto blocker is resolved + rehearsed:
cp numo-mark-callback.service numo-mark-signer.service numo-mark-keeper.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now numo-mark-callback numo-mark-signer numo-mark-keeper
```

## RETIRED 2026-09-22 — the cNGN feed signer is not being refunded

`0xc9f1ffDE…20fdc`, the EOA that pushed prices into the cNGN spot feed
`0x41512C6a2af5AcD219EbCcfaF34f7088A2999ABC`, ran out of gas on **2026-09-11** (balance
0.0000017 ETH, nonce 65,466) and is deliberately **not** being refunded. The mark keeper is a
downstream casualty: it reads that feed, the read reverts `BLF_DataTooOld()`, and it fails closed
rather than marking to a frozen price — which is correct behaviour.

**Nothing that trades depends on either feed this signer wrote to.** Verified 2026-09-22:

| feed | why it is dead |
| --- | --- |
| `0x41512C6a` cNGN spot | spot moved to the static feeds at the SRM cutover, 2026-09-10 |
| `0xDAe566ad` market 1 USDC | deliberately moved off in the market-1-inert batch, 2026-09-09, `marginFactor 0` |

Those were the signer's **only** two destinations (95 and 5 of its last 100 transactions).

Supporting evidence, all read off chain rather than assumed:

- `totalPosition`, `totalLongPosition`, `totalShortPosition` on the SEP16 future are **0**, under
  both the DFXM and the SRM.
- The SEP16 manager `0xcE01f3D7…4d49` is `allowedModules = false` on Matching, so its accounts
  cannot settle a trade whatever any feed says.
- Spot's static feeds answer (`0xec4ad7B2` -> 743376685636834), while the live feed reverts. A real
  spot settlement landed on 2026-09-20 (tx `0xb3df1d1d…`) with this feed already 9 days stale.

### The alert retires itself, rather than being switched off

`check_mark_staleness.py` now returns early when open interest is zero, in the same shape as its
existing settled-series exit. The premise is re-checked on **every run**, so if anyone ever opens a
position on this future the alert resumes on its own. A retirement that depends on a human
remembering to undo it is how a venue ends up with an unmonitored market.

If the open-interest read itself fails, it alerts and exits 1 — it will not infer "safe to skip"
from a failure to check. Both paths were exercised before this was written.

### To un-retire

Fund `0xc9f1ffDE…20fdc` (it burns ~0.01 ETH/month at ~1 update/min; 0.05 ETH is ~5 months), and
restart `numo-mark-keeper.service`. The alert needs no change. Do this **before** re-pointing any
market at a live feed, not after.

### Still to do on the ops box (not done from here)

`numo-mark-keeper.service` and `numo-mark-alert-ssm.service` are still enabled. The keeper is
harmless — it fails closed every cycle — but it is noise in the journal, and the alert timer is now
a no-op that still costs an RPC round trip a minute. Stopping and disabling both is the tidy-up.
