# Deployed Addresses

## Base (8453) — LIVE (deployed 2026-07-19, MPC-vault-owned)

Matching/RFQ/Trade stack redeployed under the MPC vault
`0x1dcA42ab54Bd3862853A821F84B29BF65245F435`, wired to the vault-owned risk-core
(subAccounts `0x7019…2843`). Ownership is `Ownable2Step`: transfer to the vault is
**initiated** (deployer is `pendingOwner` → vault); the vault must `acceptOwnership()`
on all 7 contracts to finalize. Deployer: `0x2D724867d3AeD4A9F09c096B87F939285DD3AE2D`.

See [deployments/8453/matching.json](deployments/8453/matching.json).

- `matching`: `0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191`
- `trade`: `0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c`
- `rfq`: `0x8399328AC53a279A3564E49c2cbC82Ce95ee62D3`
- `deposit`: `0x6540f8d9Eb599b045C05E45cb6a5B1730a806658`
- `withdrawal`: `0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB`
- `transfer`: `0xEd8f114982FDBb03B70D4AC427bec7A355Cb78e4`
- `liquidate`: `0x25CF912A21e25226F1Bd99E2ADA959cC80dC4338`
- `subAccountCreator`: `0x568890A8D63Ba8a03b6eCbEedA1bD9f6ea014D5D`
- `auctionUtil`: `0x0A75514f342b8b10F403e18161009061bFE9F330`
- `settlementUtil`: `0xEa7B231A0CE393440BeE15FB16Dfc0B5e52f2009`
- `atomicSigningExecutor`: `0xdaC8e5663389B20910e3305d71F2F06F48c9B3D9`
- `tsaShareHandler`: `0x5f78F6646EEb68D9050161aCf9509008909e9Ea1`

Config verified on-chain: SEP-16 future `0xDd9c2Ddf…A1F9` registered as a dated future on
trade + rfq; relayer `0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA` authorized as trade
executor; legacy Lyra keeper NOT authorized.

**Remaining to fully go live:** (1) vault `acceptOwnership()` on the 7 contracts;
(2) execution-service `PRIVATE_KEY` set to the relayer key; (3) one settlement test fill.

## Base (8453) — superseded / abandoned (Feb 2026)

The prior Matching `0xe4c2a55401F73A540CA6e1C43067Aa7164f89088` is abandoned (owner is the
lost key `0xC7bE60b…9310`, EIP-7702-delegated; no relayer can be authorized). Replaced by
the live deployment above. Do not use.

## Base Sepolia (84532)

Active testnet deployment — see [deployments/84532/matching.json](deployments/84532/matching.json).
