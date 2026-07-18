# Deployed Addresses

## Base (8453) — ABANDONED, do not use

The mainnet Matching/RFQ/Trade stack in
[deployments/8453/matching.json](deployments/8453/matching.json) is the
**February 2026 deployment and is abandoned.**

- `matching`: `0xe4c2a55401F73A540CA6e1C43067Aa7164f89088`
- Owner: `0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310` — the abandoned/lost key
  (the same owner marked abandoned in risk-core's `DEPLOYED_ADDRESSES.md`). On-chain
  this address now carries an **EIP-7702 delegation** (`cast code` → `0xef0100…`).

Because `setTradeExecutor` is `onlyOwner` and the owner key is lost, **no relayer can
ever be authorized** on this Matching contract (`tradeExecutors(addr)` is `false` for
every address), so `verifyAndMatch` will always revert. This layer cannot settle trades.

### Required to enable mainnet trading

Redeploy the Matching / RFQ / Trade / util stack on Base mainnet **owned by the MPC vault
`0x1dcA42ab54Bd3862853A821F84B29BF65245F435`** (the same vault that owns the July-2026
risk-core FX stack — SEP-16 manager `0xcE01f3D74400caE39bd7608cd2d286C2e3874d49`, verified
`owner()` = the vault). Then:

1. Regenerate `deployments/8453/matching.json` from the deploy broadcast.
2. Update the vendored copy in `execution-service/execution-contracts/deployments/8453/matching.json`.
3. Repoint `markets-prod` Railway vars `MATCHING_ADDRESS` / `TRADE_MODULE_ADDRESS` on the
   `matcher` and `execution-service` services.
4. Vault calls `setTradeExecutor(relayer, true)` to authorize the execution-service relayer.

Until then the `matcher` and `execution-service` production services are pointed at this
abandoned Matching and **cannot settle**.

## Base Sepolia (84532)

Active testnet deployment — see [deployments/84532/matching.json](deployments/84532/matching.json).
