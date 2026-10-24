# Feed publisher ops

Everything the always-on host needs to keep the Base FX market alive.
A stale cNGN feed (>180s) freezes all trading, deposits-with-risk, and
liquidations — treat the publisher as tier-1 infrastructure.

## Host setup (Ubuntu/Debian, once)

```bash
# as the service user (assumed: numo, home /home/numo)
curl -L https://foundry.sh | bash && ~/.foundry/bin/foundryup   # provides cast
git clone --depth 1 https://github.com/numofx/exchange.git ~/exchange

umask 077
cat > ~/.numo-feeds.env <<'EOF'
RPC_URL=<Base mainnet RPC (dedicated endpoint recommended)>
FEED_SIGNER_KEY=0x<feed signer private key>
RELAYER_KEY=0x<funded relayer private key>
ALERT_WEBHOOK_URL=<Slack/Discord webhook, optional>
EOF

# smoke test before installing units
cd ~/exchange/contracts/risk-core
python3 scripts/publish_fx_feeds.py --once --dry-run
python3 scripts/publish_fx_feeds.py --once
python3 scripts/ops/check_feed_staleness.py
```

## Install units (as root; edit User=/paths first if not numo)

```bash
cp ~/exchange/contracts/risk-core/scripts/ops/numo-feeds.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now numo-feeds
```

## Verify

```bash
journalctl -u numo-feeds -f          # one cngn tx/min, stable every 20 min
```

Feed staleness pages through the perp pager (`check_perp_pager.py`, `feed-halt`: the index past 960s
of its 1200s heartbeat). The standalone feed alert (`numo-feed-alert`) was retired on 2026-10-19: it
watched only SRM market feeds, which the live markets no longer use. `check_feed_staleness.py` stays,
as a library the pager and the batch proposers import. To prove the page fires, stop `numo-feeds`
past the warn age, confirm the page, then restart it.

## EURC depth readings (evidence for the EURC deposit cap)

`eurc_depth/depth.py --once` measures EURC/USDC depth within 2% on Base (every pool, both directions, one block) and
the main pool's LP concentration, and appends one row to a CSV. The EURC cap was set on 2026-10-24 at 50% of the
latest 2% sell depth: 50,000 EURC from 112,052, not 50% of the 205,411 median, because depth fell 590k -> 112k over
the first 7 readings (overall; it rose once, 205k -> 264k, between the third and fourth). It was lowered to 40,000 on
2026-10-25 to pass the stress check below: 50% of the depth without the largest LP was 43,101. The engine keeper's `MAX_EURC_INVENTORY` is at or below it (the EURC enable gate refuses a larger
or unset limit). `--summary` prints both the median and the latest; the timer keeps sampling to its 7 days. Read-only, through `run-with-ssm-readonly.sh` for the provider RPC.
Twice a day, from its own checkout (the box's `~/exchange` is pinned at `bf9da89` and has no `eurc_depth/`):

```bash
# as ec2-user: a checkout at the commit that carries eurc_depth/, then one reading by hand (backfills the gauge)
git clone https://github.com/numofx/exchange.git ~/exchange-eurc-depth
git -C ~/exchange-eurc-depth checkout --detach <commit>
cd ~/exchange-eurc-depth/contracts/risk-core   # no --self-test here: it needs compiled ABIs, and the box has no forge build
EURC_DEPTH_CSV=~/numo-eurc-depth.csv EURC_DEPTH_STATE=~/numo-eurc-depth-state.json \
  scripts/ops/run-with-ssm-readonly.sh python3 scripts/ops/eurc_depth/depth.py --once
# as root
cp /home/ec2-user/exchange-eurc-depth/contracts/risk-core/scripts/ops/numo-eurc-depth.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now numo-eurc-depth.timer
systemctl list-timers numo-eurc-depth.timer   # next run 00:00 or 12:00 UTC
# after 7 days (the script samples nothing past them, and says so)
python3 scripts/ops/eurc_depth/depth.py --summary
systemctl disable --now numo-eurc-depth.timer
```

Each reading also runs the **stress check** that gates the EURC enable: 50% of the 2% sell depth without the main
pool's largest LP (simulated: that LP's staked positions withdrawn from the pool's ticks and the swap replayed, after
the replay with nothing withdrawn has matched the pool's quoter) must be at least the cap. It alerts
`ALERT_WEBHOOK_URL` on the first evaluation and on every change of state (pass / hold / unknown); an alert the webhook
did not accept exits 1 and is retried at the next reading. A CSV from before these columns is rewritten in place with
them empty. The enable proposer takes its own reading rather than trusting the last row.

Record the checkout, the units and the CSV path in `OPS_BOX_CHANGES.md` the same day.

## EURC batch rehearsal (anvil only)

`rehearse_eurc_batch.py` runs `propose_eurc_spot_batch.py`'s own propose loop on an anvil fork of Base. It is the same
gates, the same createMarket market-id rule and the same landed-checks, with each MPCVault signing request replaced by a
transaction from the impersonated vault. It refuses any RPC that does not answer `anvil_nodeInfo`. The commands are in
its docstring: fork, broadcast `deploy-eurc-spot.s.sol` to the fork, rehearse `configure` then `enable`, and delete the
fork's `deployments/8453/EURC_SPOT*.json` and broadcast records afterwards. Rehearsed 2026-10-21 at block 52898297:
all 7 configure actions landed (heaviest 103k gas, against the proposer's 400k); market 1 untouched; the enable gate
refused on markets-service and the keeper, as it should before step 3.

**On deploy day, rerun it with the real cap, at that morning's deployer nonce,** immediately before step 1. The escrow
and feed are CREATE addresses of the deployer (`0x2D72…E2D`), so they, every action digest and the batch hash all follow
from its nonce and the cap. The rehearsal's sheet is the reference: MPCVault approvers check each request's digest
against that run's sheet, and a digest that matches no line of it is not approved.

## Basis logger (evidence for the Sep-16 fixing)

`log_cngn_basis.py` samples the competing cNGN reference prices into a CSV so the
settlement fixing (physical-delivery-runbook.md item 5) gets decided on data. It is
read-only, signs nothing, and never alerts — so it runs without `run-with-ssm.sh`.

```bash
cp ~/exchange/contracts/risk-core/scripts/ops/numo-cngn-basis.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now numo-cngn-basis.timer
python3 scripts/ops/log_cngn_basis.py --summary   # divergence report
```

Start it early — the dataset's value is its span, and the deadline is fixed.
As of 2026-08-02 the two free FX sources disagree by ~27bps (about the mark keeper's
30bps trigger), and all three cNGN/USDC pools on Base hold dust, so there is no
on-chain market to fix against. The pool columns exist to catch that changing.

## Notes

- The relayer wallet pays ~0.00042 ETH/day (measured 2026-08-02: 1512 tx/day at
  ~0.00000028 ETH each); top it up before it empties — the alert will fire on
  staleness if it runs dry.
- **Two wallets need gas, not one.** The relayer above submits `acceptData`; the MPC
  vault `0x1dcA42ab…F435` pays for `setMarkPrice` itself (~48 tx/day, onlyOwner, so it
  cannot be delegated to the relayer). `check_signer_balance.py` takes one
  `SIGNER_ADDRESS` — run a second instance against the vault, or a dry vault freezes
  the mark exactly as a dry relayer freezes the feed.
- The signer key never needs ETH and must never set an EIP-7702 delegation.
- The staleness monitor reads the feeds' packed `spotDetail` storage word
  (slot 6) directly, so it works even while `getSpot()` is reverting.
- Alert thresholds: cNGN 120s (heartbeat 180s), stable 3000s (heartbeat 3600s).
