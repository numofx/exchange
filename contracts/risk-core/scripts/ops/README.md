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
cp ~/exchange/contracts/risk-core/scripts/ops/numo-feed-alert.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now numo-feeds numo-feed-alert.timer
```

## Verify

```bash
journalctl -u numo-feeds -f          # one cngn tx/min, stable every 20 min
systemctl list-timers numo-feed-alert.timer
```

Kill `numo-feeds` for ~2 minutes to confirm the alert fires, then restart it.

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
