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

## Notes

- The relayer wallet pays ~0.0003 ETH/day; top it up before it empties —
  the alert will fire on staleness if it runs dry.
- The signer key never needs ETH and must never set an EIP-7702 delegation.
- The staleness monitor reads the feeds' packed `spotDetail` storage word
  (slot 6) directly, so it works even while `getSpot()` is reverting.
- Alert thresholds: cNGN 120s (heartbeat 180s), stable 3000s (heartbeat 3600s).
