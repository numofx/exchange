# Mark keeper — unattended cutover runbook

Turn the mark keeper from **manual** (you paste calldata into MPCVault) to **unattended** (the
MPCVault Client Signer auto-signs `setMarkPrice`). Do this post-launch, at your leisure — manual
marks + the `mark-alert` timer cover you until it's done.

Prereqs already in place: MPCVault client signer `mark-keeper` created + key-grants approved;
Custom policy scopes `0xDd9c…`→signer-alone; ed25519 private key on the host at
`~/.mpcvault/client-signer-key`; `mark-alert` running. All commands run **on the publisher host**
(`ssh -i ~/.ssh/numo-feed-publisher.pem ec2-user@34.201.241.45`) unless noted.

---

## Phase 0 — one-time setup

**a. Generate the API token** (MPCVault console → Settings → API → new token). Copy the `x-mtoken`.

**b. Set SSM params** (SecureString; `rpc_url`/`alert_webhook_url` fall back to `/numo/feeds/*`):
```bash
R="--type SecureString --region us-east-1 --name"
aws ssm put-parameter $R /numo/mark-keeper/mpcvault_token --value '<x-mtoken>'
aws ssm put-parameter $R /numo/mark-keeper/mpcvault_vault --value '<vault-uuid>'
aws ssm put-parameter $R /numo/mark-keeper/vault_address  --value '0x1dcA42ab54Bd3862853A821F84B29BF65245F435'
```
(vault-uuid is in the MPCVault vault settings page; vault_address is the vault EOA that owns the future.)

**c. Confirm the instance role can read them** (should print the token):
```bash
aws ssm get-parameter --name /numo/mark-keeper/mpcvault_token --with-decryption \
  --query Parameter.Value --output text --region us-east-1
```
If it errors with AccessDenied, add `ssm:GetParameter` on `arn:aws:ssm:us-east-1:*:parameter/numo/mark-keeper/*` to the instance role.

**d. Docker present + usable by ec2-user** (the signer runs as a container):
```bash
docker ps >/dev/null 2>&1 || { sudo yum install -y docker && sudo systemctl enable --now docker; }
sudo usermod -aG docker ec2-user   # then re-login so the group applies: exit && ssh back in
```

**e. Pull latest code:** `cd /home/ec2-user/exchange && git pull && cd contracts/risk-core`

---

## Phase 1 — validate the format WITHOUT signing (`--rehearse`)

This is the key de-risk: it creates a real `setMarkPrice` signing request, fetches its details via
`getSigningRequestDetails`, shows whether the callback would APPROVE, then **rejects it — nothing is
ever signed.** Safe against the live subId.
```bash
scripts/ops/run-with-ssm-mark.sh /usr/bin/python3 scripts/mark_keeper.py --rehearse
```
**Expect:** `created signing request …` → a `getSigningRequestDetails -> {…}` dump → `resolved tx: {…}`
→ `CALLBACK VERDICT: ✅ APPROVE` → `rejected … never executed/signed ✅`.

- ✅ **APPROVE** → the response shape + `input` encoding match; the callback validates correctly. Proceed.
- ❌ **could not resolve tx** / **REJECT** → look at the printed `getSigningRequestDetails` JSON and
  adjust `resolve_tx` / `normalize_input` in `mark_callback.py` to the real field names/encoding
  (the one thing that couldn't be verified offline). Re-run until it's ✅. (Nothing was signed — the
  request was rejected — so iterate freely.)

Also confirm in the MPCVault console that the request shows up **rejected**, not pending.

---

## Phase 2 — bring up the callback + client-signer container
```bash
sudo cp scripts/ops/numo-mark-callback.service /etc/systemd/system/
sudo cp scripts/ops/numo-mark-signer.service   /etc/systemd/system/
sudo systemctl daemon-reload

# callback first (the signer calls it)
sudo systemctl enable --now numo-mark-callback
journalctl -u numo-mark-callback -n 5 --no-pager        # "callback listening :8799"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8799/ --data-binary 'nouuid'
#   -> 403  (no uuid in body -> reject; confirms it's up + fail-closed)

# then the signer container
sudo systemctl enable --now numo-mark-signer
docker ps | grep mpcvault-signer                        # running
journalctl -u numo-mark-signer -n 30 --no-pager         # connected to MPCVault, key grant active, no errors
```

---

## Phase 3 — first live unattended mark (watched)

Run ONE real cycle by hand and watch it flow end-to-end. The mark it sets = current spot (correct
value, ≤5%-clamped), so this is safe; if any hop breaks it fails closed (no mark) and you fall back
to manual.
```bash
# from a second shell, tail the callback while it runs:
journalctl -u numo-mark-callback -f &

scripts/ops/run-with-ssm-mark.sh /usr/bin/python3 scripts/mark_keeper.py --once
#   expect: "setMarkPrice <old>-><new> (…bps) tx=0x…"
#   callback log should show: "APPROVE ok: …"
```
**Verify it landed:**
```bash
scripts/ops/run-with-ssm.sh /usr/bin/python3 scripts/ops/check_mark_staleness.py
#   -> "ok: mark age <60s, drift 0bps"  (fresh mark, just set by the pipeline)
```
Check the tx on Basescan for a `MarkPriceSet` event. If it didn't sign (callback REJECT / no
STATUS_SUCCEEDED), read both logs, fix, re-run — no bad mark can land (worst case = no mark).

---

## Phase 4 — enable continuous, retire manual
```bash
sudo cp scripts/ops/numo-mark-keeper.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now numo-mark-keeper
journalctl -u numo-mark-keeper -f        # marks when spot drifts ≥30bps or every 30m
```
Now stop setting marks by hand. Keep `mark-alert` running — it still backstops the automated keeper.

---

## Rollback (any time)
```bash
sudo systemctl disable --now numo-mark-keeper numo-mark-signer numo-mark-callback
```
The keeper stops; nothing else is affected. Resume manual marks (`mark_keeper.py --once --dry-run`
→ paste into MPCVault). To kill signing authority entirely, disable the Client Signer / remove the
Custom policy in the MPCVault console.
