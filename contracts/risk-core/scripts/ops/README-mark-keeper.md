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
