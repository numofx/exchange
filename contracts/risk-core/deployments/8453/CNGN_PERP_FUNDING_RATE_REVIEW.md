# USDCcNGN-PERP funding sign: review before signing

One action, `PerpAsset.setStaticInterestRate(int256)` on the perp `0xC74EfC8B4808803dBCF439E76Fde076d56625b8E`,
owner the vault `0x1dcA42ab54Bd3862853A821F84B29BF65245F435`. Proposed only by
`scripts/ops/propose_perp_funding_rate.py --propose --expect-digest <digest>` from the ops box, after its
dry run passes. Moves no funds; changes only the hourly funding rate every open position accrues from
the next touch of the contract.

## Why

`_getFundingRate = premium / convergencePeriod + staticInterestRate`, clamped to ±0.4%/h. With mark ≈ index
the premium is zero and the whole rate is the static term, which deploy left at Lyra's generic
`+0.0000125e18` (+0.00125%/h, +10.95% APR, "borrow the base asset"). A positive rate is paid by on-chain
longs, which are long cNGN. On a cNGN perp quoted in USDC the carry longs should pay is r_USD − r_NGN, which
is negative: long cNGN should receive the differential and long USD should pay. The sign is inverted and the
magnitude was never set from any NGN or USD rate.

The fix is one owner call with a negative value: −(spread APR) / 8760 per hour, where the spread is the
operator's view of NGN yields over USD yields. The contract bound is ±0.001e18/h (±876% APR), far above any
candidate. Nothing in markets-service, the app or the market maker needs to change: `ui_long_funding_rate_1h`
is the chain rate, and the header, ticket and APR suffix flip sign on the next refresh.

## Candidates

| Spread (NGN over USD, APR) | Hourly rate (e18) | Reads as | MPCVault digest |
| --- | --- | --- | --- |
| **15%** (rendered artifact) | `-17123287671233` | −0.001712%/h, longs receive | `0x4b355c6cd31b2316b7f6eb1ee3d5be697a4d9516931d0b05e1b1c3547124e306` |
| 20% | `-22831050228311` | −0.002283%/h, longs receive | `0x2496415f15246a4655471558083b1a962f0b4e1ed8d9e8e52adf54d580e8dac2` |
| 25% | `-28538812785388` | −0.002854%/h, longs receive | `0xbdd25e0fc9686892ab40dde38284d02007a31e80571309a953cb4536b25415af` |
| 30% | `-34246575342466` | −0.003425%/h, longs receive | `0x202bbef6856f2ab02fbb40230fad66a2b6ae72139c66cb5e9a6cf0f536f5a284` |

`CNGN_PERP_FUNDING_RATE_VAULT_ACTIONS.json` holds the 15% row, chosen 2026-10-07 against secondary NGN yields of about 18%. To choose another, re-render
(`--render --spread-apr 0.25`), commit the artifact, and pass that row's digest to `--propose`. The digest is
`keccak(to ‖ keccak(calldata))`, as for every earlier batch; compare it with the one MPCVault shows before
approving.

| # | Target | Function | Argument | Purpose |
| --- | --- | --- | --- | --- |
| 0 | PerpAsset (perp)<br>`0xC74EfC8B4808803dBCF439E76Fde076d56625b8E` | `setStaticInterestRate(int256)` | `rate` = `-17123287671233` (−0.001712%/h, 18dp) | Static funding leg with the carry sign corrected: long cNGN receives, long USD pays, about 15% APR on the position. |

## Gates (the dry run refuses otherwise)

- The artifact's target is the perp, the function is `setStaticInterestRate(int256)`, the rate is negative and
  within the contract's bound, the value is 0, and the digest recomputes.
- `perp.owner()` is the vault; `staticInterestRate()` does not already read the new value (it reads
  `+12500000000000` at render, 2026-10-07); the RPC is chain 8453.

## After it lands

- `GET /v1/markets` → `perp.ui_long_funding_rate_1h` reads the negative rate; the app header shows
  "1h Funding −0.0017% (−15.0% APR)" and the Long side's ticket row reads "receives". The market maker reads the
  same field and needs no change.
- Positions accrue the new rate from the next time the contract is touched; `aggregatedFunding` is continuous,
  there is no settlement moment.

## Rollback

The same call with the deployed constant `+12500000000000`: calldata
`0xffa63d2600000000000000000000000000000000000000000000000000000b5e620f4800`, digest
`0x02d80413d2a1292115b54b1753756f25b964fd4eba9896c96977c04be3dd3d39`.
