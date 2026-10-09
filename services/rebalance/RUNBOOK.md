# Runbook — `cNGN rebalance due`

What to do when `pnpm rebalance check --alert` posts to the ops channel. Background and thresholds
are in [README.md](./README.md); this is the procedure.

**The loop has four steps and the first one is manual**, because a withdrawal pays only to the
subaccount owner and cannot be delegated to this service (README, *Not done yet*).

```
sub 26 ──[ 1. withdraw ]──▶ MM wallet ──[ 2. transfer ]──▶ rebalance signer ──[ 3. swap ]──▶ cNGN ──[ 4. deposit ]──▶ sub 26
        owner-signed,                  plain ERC-20                        pnpm rebalance      pnpm rebalance
        MM key                                                             approve + swap      deposit
```

## The addresses

| What | Address |
| --- | --- |
| Subaccount (unified, under the perp SRM since 2026-10-04) | `26` |
| Owner of sub 26 — **withdrawals pay here** | `0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B` |
| Rebalance signer (KMS `alias/numo-exchange-rebalance`) | `0x1661AA54fA390cd916722F971e4A9Fe4c01889fB` |
| USDC token (6 dp) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| USDC on sub 26: perp CashAsset | `0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272` |
| cNGN on sub 26: cNGN escrow | `0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98` |
| Margin manager (perp SRM) | `0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` |
| WithdrawalModule | `0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB` |
| Matching | `0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191` |

`SubAccounts.ownerOf(26)` returns **Matching**, not the owner — the account is deposited. The owner
is `Matching.subAccountToOwner(26)`. Read the mapping, not the ERC-721.

The CLI does not hard-code the escrow, cash or manager: it reads the cNGN spot market from the
venue's `/v1/markets` and refuses to run unless `SubAccounts.manager(MM_SUBACCOUNT_ID)` is that
market's manager, the escrow is whitelisted on it and the quote asset is its cash. Account 15, on
the retired spot stack, is refused by name. Before 2026-10-04 this runbook used sub 15 and the
wrapped USDC escrow `0x364058aF…`; both are retired.

## 0. Confirm it is real

```bash
pnpm rebalance check
```

Re-read the book before acting on a message that may be minutes old. If it now says `healthy`,
stop — the market maker may have rebalanced itself by trading. Only `rebalance` or `urgent`
justifies the steps below.

## 1. Withdraw from sub 26 → MM wallet

Signed by the **market maker's key**, for `action.owner == action.signer ==`
`0x3448ac0A…`. Two routes, both proven on this escrow:

- **Through Matching** (what a deposited subaccount uses): an owner-signed action on the
  WithdrawalModule, submitted via `Matching.verifyAndMatch` (`0x74d906c3`). Precedent: sub 19's
  owner withdrew 1.999575 USDC this way in
  [`0xffff17a9…5e0175`](https://basescan.org/tx/0xffff17a9814e32bedd2bcdeffb214dc1293bac59d634560af73200293a5e0175)
  (block 51301502). That precedent is on the retired wrapped USDC escrow; sub 26's USDC is perp
  cash (`0xA74E49b4…`), which this runbook has not yet withdrawn. Withdraw a small amount first.
- **Directly on the escrow** (`0x0ad58d2f`), only for a subaccount *not* deposited in Matching.
  Sub 26 **is** deposited, so this route does not apply to it.

`action.data` is `abi.encode(address asset, uint256 amount)` — exactly 64 bytes, **no recipient
field**. The amount is in the token's native decimals (**6**), while subaccount balances read back
in 18. Do not copy a ledger figure into the amount.

## 2. Transfer USDC → rebalance signer

A plain ERC-20 `transfer` from `0x3448ac0A…` to `0x1661AA54…`. Nothing venue-specific.

This step exists only because step 1 cannot name a recipient. It is the step most likely to be
forgotten, because the alert fires about sub 26 and this touches neither the subaccount nor the CLI.

## 3. Swap USDC → cNGN

```bash
export BASE_RPC_URL=...                   # keyed Alchemy; the public endpoint rate-limits the SDK
pnpm rebalance quote 200                  # sanity-check the rate first
pnpm rebalance approve 200 --execute
pnpm rebalance swap 200 --execute
```

`swap` places the intent, runs the auction and waits for the fill. If it does not fill,
`pnpm rebalance cancel --execute` reclaims everything but the 5 bps gateway fee.

## 4. Deposit cNGN → sub 26

```bash
pnpm rebalance deposit --execute          # whole cNGN balance
pnpm rebalance check                      # confirm the share moved
```

## Traps

**A successful operation can report as failed.** Base RPC replicas lag, so a balance read straight
after a write may show the old value. `waitFor()` covers the paths the CLI uses, but if a step
reports failure, **check the chain before retrying** — retrying a completed swap or deposit spends
real money twice.

**Both wallets need ETH on Base.** A full cycle is about $0.02, but a wallet at zero fails at the
worst moment. Check `0x3448ac0A…` and `0x1661AA54…` before starting.

**Never grant the rebalance role `kms:Sign` on the market maker's key.** KMS grants are not
partial: it would confer authority to cancel every order and withdraw everything, undoing the
separation this split exists to create.

**Do not route funds to the legacy CashAsset `0x6B232A21…6fc6`.** It holds ~2 USDC against ~69 of
claims. The perp CashAsset in this runbook (`0xA74E49b4…`) is a different contract and is fully backed.
