# Mark keeper — automated `setMarkPrice` for the deliverable FX future

Design for unattended periodic mark updates on the SEP-16 cNGN/USDC deliverable future.
Status: proposal (investigation complete; MPCVault confirmed able to auto-sign). Scope: a new
ops service alongside the price publisher on the EC2 host.

## Why this exists

`DeliverableFXFutureAsset.setMarkPrice(subId, markTime, markPrice)` is `onlyOwner`, the owner is
the MPCVault-custodied vault EOA `0x1dcA42…`, and the contract is immutable with **no** keeper
role. VM (variation margin) only accrues when the mark moves, and physical settlement on
2026-09-16 must land within **5%** of the final mark (`setSettlementPrice` enforces the same
deviation bound). So the mark must be updated on a regular cadence that tracks spot into the
close — today nothing does this automatically.

On-chain constraints the keeper lives inside (verified live):
- `maxMarkDeviation` = **5%** — each mark ≤5% from the previous stored mark (mark-to-prev-mark).
- `maxMarkDelay` = **600s** — submitted `markTime` must be within 600s of chain time.
- `markTime` strictly increasing, ≤ expiry; series must be listed and not settled.
- Mark update is accrue-only (O(1), no cash moves); margin sees pending VM live.

## Mark policy: one pipeline, three config-selectable `targetMark()` modes

The mark the keeper *wants* to set comes from a pluggable `targetMark()` selected by
`MARK_MODE`. Everything downstream — step clamp, trigger, cadence, signing, guardrails — is
identical across modes. The three modes are a **liquidity progression**, not alternatives:

| `MARK_MODE` | `targetMark()` | When |
|---|---|---|
| `spot` | on-chain `LyraSpotFeed.getSpot()` (cNGN/USDC, 1e18) | **launch** — thin book, simplest, zero maintenance |
| `forward` | `spot × (1 + r · (T − t))`, `r` a governance param | when the cNGN→NGN→MMF carry becomes real money and you want to stop leaking it |
| `book` | manipulation-resistant VWAP/mid of the SEP-16 orderbook, **fallback to `forward`** | the CME end-state — once the book has genuine two-sided/arb flow that prices the carry itself |

`forward` with `r = 0` is exactly `spot`, so launch = `MARK_MODE=forward, r=0` and turning on
carry is a one-value config change, no code change. `book` layers on top (falls back to the
`forward`/`spot` number whenever the book isn't trustworthy), so all three ship together and you
advance by config as liquidity grows.

### Mode 1 — `spot` (launch)
`targetMark = getSpot()`. Reads the **same on-chain feed the manager uses for margin**, so mark
and margin-spot never diverge. Converges to the settlement fixing with zero basis. The carry
leak is immaterial at near-zero OI and the switch to `forward` is one config value — so spot is
the right *launch* mark even though `forward` is the correct *steady-state* one.

### Mode 2 — `forward` (when carry is real money)
`targetMark = spot × (1 + r·(T − t))`, `T` = expiry, `t` = now, `r` = NGN−USD rate differential
net of cNGN⇄NGN friction (a **governance param**, not a feed — anchor to published NGN
T-bill/OMO yields minus the on-chain USDC supply rate, reset every few weeks). Decays to spot at
expiry → settlement still lands on a clean spot fixing. Defends the physically-delivered carry
arb (short the future, carry cNGN→NGN→MMF, deliver into it). `r=0` ⇒ collapses to `spot`.

### Mode 3 — `book` (CME-style, once liquid)
Mark to the SEP-16 contract's **own traded price** — the way CME marks 6E (daily settlement =
VWAP of actual trades in a window; the market, via arbitrageurs, makes that price the forward).
`targetMark` = a manipulation-resistant reference off the numo orderbook/trades
(markets-service `/v1/book`, `/v1/trades`): a **time-VWAP of recent fills** (not an instantaneous
mid). This is the destination that retires the spot-vs-forward question entirely — the arb flow
prices the carry for you.

**Manipulation resistance is the whole game here** (a thin book lets one order drag the mark):
- **Quality gate:** only use the book if it clears minimums — depth at top-of-book ≥ `MIN_DEPTH`,
  ≥ `MIN_TRADES` fills in the VWAP window, spread ≤ `MAX_SPREAD`. Otherwise **fall back to the
  `forward` number** for this cycle. Thin/quiet book ⇒ never trusted.
- **Time-VWAP, not last/mid:** average over a window (e.g. 15–30 min of fills), so a single
  print can't move it.
- **Sanity band vs the manufactured mark:** clamp the book reference to within a band of the
  `forward`/`spot` value (e.g. ±X%); a book that implies something wildly off spot is rejected,
  not followed. The on-chain 5%/step wall is a backstop, but this band is tighter and intentional.
- Net: `book` = "trust the market's price when the market is real; otherwise fall back to the
  formula." Same posture CME's thin-market settlement rules take.

### Step clamping and cadence (shared by all modes)

```
last     = on-chain series.markPrice
target   = targetMark()                              # per MARK_MODE above
step_cap = last * 0.05 * SAFETY (e.g. 0.045 to stay inside the 5% wall)
target   = clamp(target, last - step_cap, last + step_cap)
markTime = now()                                     # < 600s old, > lastMarkTime
```
- **Trigger:** submit when `|target - last| / last ≥ THRESHOLD` (e.g. 0.3%) OR a max interval has
  elapsed (heartbeat, e.g. 30 min) — whichever first. Avoids spamming marks on noise while never
  letting the mark drift far from target.
- **Ratchet:** if `target` has moved >5% since the last mark (rare), the clamp advances the mark
  in ≤5% steps over consecutive cycles until it catches up.
- **Close tightening:** in the final days before 2026-09-16, drop THRESHOLD and the heartbeat so
  the mark hugs `target` going into the settlement fixing (settlement must be within 5% of final
  mark). Near the close, prefer `book` if liquid (real price discovery), else `forward`.
- Use a `SAFETY < 5%` step cap so a mark never reverts on-chain for grazing the exact bound.

## Signing path — MPCVault Client Signer (unattended)

Confirmed: the vault can be configured as an **API wallet** whose **Client Signer** alone
satisfies quorum for transactions to an allowlisted address, while everything else keeps full
human quorum. Two processes run on the EC2 host:

1. **MPCVault Client Signer** (their Docker image): authenticates with an Ed25519 key (no
   passphrase), holds one MPC share, and on each `ExecuteSigningRequests` calls back **our**
   callback server to approve/reject.
2. **Mark keeper** (ours): the loop + the callback server.

Per cycle the keeper:
1. Reads on-chain `series.markPrice` / `lastMarkTime` and `LyraSpotFeed.getSpot()`; computes the
   clamped target (above). Skips if no trigger.
2. `CreateSigningRequest` with a **custom payload** = ABI-encoded
   `setMarkPrice(subId, markTime, target)` to the future contract on Base.
3. `ExecuteSigningRequests({uuid})`. MPCVault → **callback** (see guardrail) → on approval the
   client signer completes quorum → response `STATUS_SUCCEEDED` + `txHash`.
4. Confirm the `MarkPriceSet` event / receipt; record; on error branch (below) alert.

## Guardrails — defense in depth (3 independent layers)

1. **On-chain (immutable):** `onlyOwner` + ≤5% deviation + 600s staleness + monotonic markTime.
   A fully-compromised keeper can at most nudge the mark ≤5%/step and **cannot** call
   `setSettlementPrice`, `createSeries`, or any other owner power that the callback rejects.
2. **MPCVault policy:** allowlist **only** the future contract address `0xDd9c2Ddf…A1F9` (Base)
   for client-signer-alone approval; every other destination keeps full human quorum. Bounds the
   **destination**. (MPCVault policies are address+amount only — they cannot see the function.)
3. **Client-signer callback (ours):** the function/parameter layer MPCVault can't enforce —
   validate `to == future`, selector == `setMarkPrice`, `subId == SEP16`, and
   `|target - lastOnChainMark| ≤ 5% AND target within a sane band of spot` → approve; **reject
   everything else**, including `setSettlementPrice`. Settlement stays a deliberate human action.

## Operations

- **Host:** the existing publisher EC2 (`i-0aea04c89a0e69368`). Secrets via SSM like the publisher
  (MPCVault API key, Ed25519 client-signer key, callback shared secret) — never on disk.
- **Gas:** the vault EOA pays gas for `setMarkPrice`. Keeper checks vault ETH balance each cycle;
  low-balance → alert (mirrors the feed-staleness alert). `INSUFFICIENT_FUNDS` from
  `ExecuteSigningRequests` also pages.
- **Monitoring / alerts** (reuse the Slack webhook + systemd timer pattern from the publisher):
  - **mark staleness** — last successful `MarkPriceSet` older than N× heartbeat.
  - **quorum/policy denied** — `ExecuteSigningRequests` returns `ALREADY_DENIED` (policy or a
    human rejected) → the auto-approve path is broken; page.
  - **deviation-wall hit** — a submit reverts `DFXF_MarkDeviationExceeded` (spot gapped >5% and
    the clamp math is off) or `DFXF_StaleMark`.
  - **spot feed stale** — getSpot() reverts (`BLF_DataTooOld`): the mark source is down; the
    publisher's own alert already covers this, but the keeper should also refuse to mark on a
    stale spot rather than mark to a frozen value.
- **Systemd units** mirroring `numo-feeds*` (`mark-keeper.service` + the client-signer container).
- **Settlement (`setSettlementPrice`) is NOT automated** — it's one-shot, final, and the highest
  consequence. A human runs it at/after expiry (2026-09-16 14:00:01 UTC) with the final fixing,
  within 5% of the last mark (which the keeper will have kept close to spot).

## Failure modes → behavior

| Failure | Keeper behavior |
|---|---|
| spot feed stale (`getSpot` reverts) | do NOT submit a mark; alert; retry next cycle |
| spot gapped >5% since last mark | ratchet in ≤5% steps over cycles; alert if it persists |
| `ExecuteSigningRequests` `ALREADY_DENIED` | stop, page (auto-approve policy broken) |
| `INSUFFICIENT_FUNDS` | page; do not spin |
| tx reverts on-chain | log revert selector, alert, retry with fresh markTime/clamp |
| keeper process dies | systemd `Restart=always`; staleness alert fires if marks stop |

## Build plan (once this is approved)

1. Mark keeper skeleton: on-chain reads (mark/spot), pluggable `targetMark()` with all three
   modes (`spot` / `forward` / `book`), clamp+trigger logic, `--dry-run` (logs the mark it
   *would* submit — fully testable with no MPCVault, no signing).
2. MPCVault client: `CreateSigningRequest` (custom payload) + `ExecuteSigningRequests` + poll.
3. Callback server: strict `setMarkPrice`-only validation.
4. `book` mode data path: read markets-service `/v1/book` + `/v1/trades`, time-VWAP + quality
   gate + sanity band + fallback to `forward`.
5. Ops: SSM secrets, systemd units, alerts/timer, gas-balance check; deploy to the EC2 host.
6. Rehearse on a throwaway series / small deviation before letting it run into the close.

Launch config: `MARK_MODE=forward, r=0` (≡ spot). Advance by config as liquidity grows —
set `r` to turn on carry; `MARK_MODE=book` once the SEP-16 book has real two-sided flow.

## Open items to confirm
- `r` seed value for when carry is turned on (NGN T-bill/OMO yield − on-chain USDC yield −
  friction). Launch runs `r=0`, so not blocking.
- `book`-mode thresholds: VWAP window, `MIN_DEPTH`, `MIN_TRADES`, `MAX_SPREAD`, sanity band.
  Not blocking launch (mode stays off until the book is liquid).
- Cadence numbers: THRESHOLD (0.3%?), heartbeat (30m?), close-tightening schedule.
- MPCVault address-allowlist policy created + client-signer added to the vault (console).
