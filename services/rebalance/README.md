# cNGN rebalance

Buys cNGN back for the market maker by swapping USDC on the HyperFX IntentGateway on Base.

The market maker's flow is one-directional — it sells cNGN for USDC — so without a routine that
buys cNGN back, the bid side eventually goes dark. This is that routine.

## Why HyperFX

Same chain, same token, no bridge. The gateway settles against
`0x46C85152bFe9f96829aA94755D9f915F9B10EF5F`, which is the identical cNGN the venue itself settles,
and both legs are `EVM-8453`. A $20 test filled at **₦1,369.96** against a rate-picker mid of about
₦1,372 — roughly **15 bps** to rebalance, cheaper and far faster than a CEX round trip.

## Commands

Everything is a dry run unless `--execute` is passed.

```bash
export BASE_RPC_URL=...            # keyed endpoint, see below
pnpm rebalance quote 20            # what the live feed prices it at
pnpm rebalance approve 20 --execute
pnpm rebalance swap 20 --execute   # place, auction, fill
pnpm rebalance deposit --execute   # whole cNGN balance -> subaccount 15
pnpm rebalance cancel --execute    # reclaim an unfilled order
```

## Things that are not obvious

**Never use the SDK's quote for this pair.** `@hyperbridge/sdk` 2.8.13 prices phantom pairs off the
V1 `phantomOrderPriceSnapshots` table, which froze on 2026-08-08 at 1393.0 — 1,617 identical rows —
and its only validation is that the timestamp parses. The live feed is
`phantomOrderPriceSnapshotV2s`, which the SDK never mentions. `quote.ts` reads V2 and refuses
anything older than `MAX_SNAPSHOT_AGE_SECONDS`.

**It is an RFQ, not an order book.** `low == median == high` on every snapshot and `bidCount` is 2,
so there is no depth to walk. What the auction adds is competition: solvers may bid *above* the
required output and the surplus is split 40% to us, 60% to the gateway — so fills come in slightly
better than the quote, never worse.

**A bundler is required.** `executeBest` submits the winning bid as an ERC-4337 UserOperation.
Without a bundler URL it places the order, fails instantly with `Bundler URL not configured`, and
leaves the input escrowed until the deadline. Alchemy serves its Rundler bundler on the same URL as
the RPC — check `eth_supportedEntryPoints` before assuming that of another provider.

**Placement is not fire-and-forget.** `session` is an ephemeral keypair the SDK generates per
order, and its holder selects the winning bid. Killing the process mid-auction forfeits the fill.

**The gateway rewrites the order.** It assigns the nonce (we send 0) and deducts the 5bps protocol
fee from the input. The commitment hashes the *canonical* struct, so `cancel` rebuilds from the
indexer and verifies the hash before sending anything.

**Recovery is cheap and complete.** `cancelOrder` takes a second `CancelOptions` argument; a
one-argument call reverts with no reason. Same-chain needs no destination proof
(`{relayerFee: 0, height: 0}`, one transaction). It refunds the escrow *and* the solver fee — only
the 5bps protocol fee is kept, about a cent on a $20 order.

**Read replicas lag in both directions.** A read straight after a receipt can be served pre-block,
and a read pinned to the receipt's own block can answer "Unknown block". This produced three wrong
conclusions in one session: a 19.92 USDC refund printed as `+0`, an approve that had succeeded made
the next simulate revert `ERC20: insufficient allowance`, and a landed deposit reported an error.
Use `waitFor` from `clients.ts` after any write; never read `latest` and believe it.

**The public RPC is unusable here.** `https://mainnet.base.org` rate-limits the SDK's own
initialisation — it dies on `decimals()` before an order exists. `BASE_RPC_URL` is required and has
no default; use the keyed endpoint in SSM `/numo/exchange/rpc_url`.

## Keys

Signs with KMS `alias/numo-exchange-rebalance` → `0x1661AA54fA390cd916722F971e4A9Fe4c01889fB`.

Deliberately **not** the executor key. The executor is authorised on `Matching` and settles every
trade and withdrawal; this one only holds working capital. A compromise here costs the float, not
the venue's settlement authority. The key carries `prevent_destroy`, so retiring it means sweeping
the balance first (see `infra/aws/secrets.tf`).

The signer needs ETH for gas — a whole three-leg cycle costs about $0.02 at current Base prices.

## Not done yet

The **withdrawal leg**: sub 15 → this signer. Sub 15 is owned by the market maker's wallet, so
either this signer is authorised to withdraw from it or the loop goes through `POST /v1/withdrawals`
with an MM-signed request. Until then the loop is manual on that one step.
