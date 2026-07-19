# exchange

Numo Base-EVM exchange: onchain contracts + offchain services, in one monorepo.

## Layout

| Path | What | Origin (archived) |
|------|------|-------------------|
| `contracts/risk-core` | Risk engine & deliverable FX-futures contracts | [`numofx/risk-core`](https://github.com/numofx/risk-core) |
| `contracts/execution` | Matching / TradeModule / RFQ | [`numofx/execution-contracts`](https://github.com/numofx/execution-contracts) |
| `services/markets` | Markets service (Go) | [`numofx/markets-service`](https://github.com/numofx/markets-service) |
| `services/execution` | `matching-executor` signing bot | [`numofx/execution-service`](https://github.com/numofx/execution-service) |
| `packages/abis` | `@numo/abis` — generated ABIs + deployment addresses | — |

The four origin repos were consolidated here on 2026-07-19 (git-subtree merge, history
preserved) and are now **archived / read-only**. `numofx/exchange` is the canonical repo —
push here, not to the archived originals.

`services/execution` imports contract ABIs and addresses from `@numo/abis` rather than
reading a sibling contracts directory; the package's generated output is committed so the
service builds without a Solidity toolchain and every ABI change is visible in the diff.

## Build

pnpm workspace (`pnpm@8.7.3`), Foundry pinned to `1.7.1`. CI is path-filtered per subtree.

```bash
pnpm install
pnpm --filter @numo/abis build          # compile @numo/abis before the service
pnpm --filter matching-executor build   # services/execution
forge test --root contracts/risk-core   # or contracts/execution
```
