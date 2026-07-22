# Deployed Addresses

## Base (8453) — current deployment

Deployed: 2026-07-15
Owner (all contracts): MPC vault **Numo-Manager-Admin** `0x1dcA42ab54Bd3862853A821F84B29BF65245F435`
Feed signer (cNGN spot + stable feed, 1-of-1): `0xdA1976E83D54B76D0c794B35262228960a1a918f`

Core + future contracts verified on Basescan and Base Blockscout (2026-07-22).
Dune decoding submitted for the same set (project `numo` → `numo_base.*` tables).

### Core

Artifact: [deployments/8453/core.json](deployments/8453/core.json)

- `subAccounts`: `0x7019244E25FA416e6Ca2ed2F3cA25277aef72843`
- `cash`: `0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6`
- `securityModule`: `0x7d646B55Ae73fFdF44A4D37b77925f0e69550e7c`
- `auction`: `0x0EfAe56b2b583b1E84c6E4269236163C1E8050E1`
- `srm`: `0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b`
- `srmViewer`: `0x1c08f30c204EE18EbBDc161c0f0864AFb826934b`
- `stableFeed`: `0xDAe566adc61086535986AfBd80093B1DD8686797`

### USDC/cNGN SEP-16-2026 deliverable FX future

Artifact: [deployments/8453/CNGN_SEP16_2026_FUTURE.json](deployments/8453/CNGN_SEP16_2026_FUTURE.json)

Redeployed 2026-07-17 with the VM-denomination fix and mark-price bounds
(5% max deviation per update, 600s staleness cap). Initial mark 1379.64.

- `manager` (DeliverableFXManager): `0xcE01f3D74400caE39bd7608cd2d286C2e3874d49`
- `viewer`: `0xB0B4A877Ee72E00f677411AB828149431E659a56`
- `future` (DeliverableFXFutureAsset): `0xDd9c2Ddf97a2Dc9B9d348DcD0ef776aF5291A1F9`
- `baseAsset` (wrapped USDC): `0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84` (wraps native USDC `0x8335…2913`, 6 dec)
- `quoteAsset` (wrapped cNGN): `0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493` (wraps cNGN `0x46C8…EF5F`, 6 dec)
- `spotFeed` (cNGN): `0x41512C6a2af5AcD219EbCcfaF34f7088A2999ABC`
- Series subId: `1789567201` — last trade 2026-09-16 14:00:00 UTC, delivery 14:00:01 UTC
- Margin: 20% IM / 15% MM (5x max leverage); 3-day lifecycle ramp to full collateral

## Base — ABANDONED deployment (pre-2026-07)

The original deployment (owner `0xc7Be60b228B997C23094dDFdD71e22e2De6c9310`) is
**abandoned**: the owner key is lost, the contracts cannot be administered, and the
listed series have expired. Do not integrate against these addresses. This includes
the NGN/BTC perps and the APR-30-2026 future previously listed here (manager
`0x0777C37C3925666474C77f5907E3805177705543`, future `0x7528…E679`, and related feeds).

Also abandoned (2026-07-17, VM denomination bug — accrued VM in cNGN but credited
it 1:1 as USDC): the first SEP-16-2026 stack — manager `0x66E3D42cE93DEb0675F56216f15c6592298B2E28`,
viewer `0x6bdD52484cd2d26eDA0bf1357B74Acda8C37AA81`, future `0x9725e4b6ae24d8Bd76F3AcfDa6E90fC9284e82ef`.
Vault-owned but disused; never held positions.
