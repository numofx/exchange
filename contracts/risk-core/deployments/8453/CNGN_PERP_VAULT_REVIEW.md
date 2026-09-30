# USDCcNGN-PERP vault actions: review before signing

Rendered 2026-09-30 16:41 UTC from commit `f8d2dc3`, from `CNGN_PERP_STACK.json`, `CNGN_PERP_STACK_VAULT_ACTIONS.json`, `CNGN_PERP_TRADE_MODULE.json` and `CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json`.
Every row was decoded and re-encoded to its own calldata, every digest recomputed, every target matched to an artifact, and every value is 0. Compare each digest with the one MPCVault shows before approving.

- Vault: `0x1dcA42ab54Bd3862853A821F84B29BF65245F435`
- Guardian set by batch 1: `0xDb7137Fc6e3437Bd6D8923A94b0af746Ea463C31`
- Perp: `0xC74EfC8B4808803dBCF439E76Fde076d56625b8E`, SRM: `0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4`, TradeModule: `0xDea968188598BA0E3F58A56C0fdfF338C74F699f`

None of these moves funds. Batches 1 and 2 are custody only: after them the market is still closed (cap 0, module not allowlisted). Batch 3 opens it, and is proposed only by `propose_perp_enable_batch.py --propose`, one action at a time, after its gates pass.

## Batch 1: stack custody and the guardian

Sign after the stack deploy (checklist step 10).

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | CashAsset (the perp's USDC cash)<br>`0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272` | `acceptOwnership()` | (none) | The vault takes ownership of the CashAsset (the perp's USDC cash) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x1e7520073cab64bd332e4968382e23d8bd649ff9f3196399bcaacc4a225360da` |
| 1 | SRMPortfolioViewer<br>`0xda5989f435507F8C3070Cd30B19f7607615599E5` | `acceptOwnership()` | (none) | The vault takes ownership of the SRMPortfolioViewer (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xa1f76282f9a27b736ff06032de7283a796af91eb9c3162a19001e425d7869181` |
| 2 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `acceptOwnership()` | (none) | The vault takes ownership of the StandardManager (perp SRM) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xd190c572d622e8f3c146e344d2240d0f85074072fb3fdee6fafc4109cb524431` |
| 3 | SecurityModule<br>`0x92A6F2f5EE253Db67a5980864195b7BC5A586530` | `acceptOwnership()` | (none) | The vault takes ownership of the SecurityModule (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x10a504c5a1ba54f4bae0070cc80a9fd2908006e63342b0d12e61e161f12df389` |
| 4 | DutchAuction<br>`0xd07176B006cE8246e930d37b8bc44B1154f8c4cE` | `acceptOwnership()` | (none) | The vault takes ownership of the DutchAuction (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x6401d20318f5d7eef0e0c96d73d998c6f9526b3246d72f397cf5c09a2a409f11` |
| 5 | stable feed (static)<br>`0x7B52f41fa6E2CEC5416e68ED91F4C9899c94492B` | `acceptOwnership()` | (none) | The vault takes ownership of the stable feed (static) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x9c840dcfd392fcede440a6ab6534ade067afb3ed2d314e36d38d11051d41d2fe` |
| 6 | index feed<br>`0xFaC420d160C7c219A72DC676971670980bAC20a5` | `acceptOwnership()` | (none) | The vault takes ownership of the index feed (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x5650c27006ea58b1ed883f4764d8b104f27e1feb60a038fc6afd4c6f73800e65` |
| 7 | mark feed<br>`0x702636073742C30bE3592f07739785a2B80ad19B` | `acceptOwnership()` | (none) | The vault takes ownership of the mark feed (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xf5e9e5dfaf8f100e86248ae70254ff953343fa4bf368e646ecf70b16ed10e077` |
| 8 | impact ask feed<br>`0xEbF529c35Eb468d2fD8f3110B9aEFcEDfAB742bB` | `acceptOwnership()` | (none) | The vault takes ownership of the impact ask feed (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xa99f0ebeb737ddccf1d5eae4c69ca47f039409edf79a10a3d1721a0d052091ed` |
| 9 | impact bid feed<br>`0xD8880113Db44304dFD792c5161D79E6774D0B1fA` | `acceptOwnership()` | (none) | The vault takes ownership of the impact bid feed (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xd6db8c7687b976ef61888399e02e1e976ec1f57ddcf3fcd130cc18cec611435c` |
| 10 | PerpAsset (USDCcNGN-PERP)<br>`0xC74EfC8B4808803dBCF439E76Fde076d56625b8E` | `acceptOwnership()` | (none) | The vault takes ownership of the PerpAsset (USDCcNGN-PERP) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x430c9c36ec9836a4b303d7d6c303962a4e03b56697b3cf745dd627996bbb93e1` |
| 11 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `setGuardian(address)` | `guardian` = `0xdb7137fc6e3437bd6d8923a94b0af746ea463c31` (PERP_GUARDIAN (hot KMS key)) | Makes the hot KMS key the SRM's guardian: it alone can pause and unpause every adjustment on the perp's accounts (trades, deposits, withdrawals, liquidation bids). The vault can reclaim it with another setGuardian. | `0x343b3c85efeb5fd716da8787aac30f1e7655ce7b1c1738b01a5411d570c38f73` |

## Batch 2: TradeModule custody

Sign after the module deploy (checklist step 11).

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | TradeModule (perp)<br>`0xDea968188598BA0E3F58A56C0fdfF338C74F699f` | `acceptOwnership()` | (none) | The vault takes ownership of the TradeModule (perp) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0x6749adb664daec0c55469efcea92fb43a436073b41c9ba8e55bffb276b17b64e` |

## Batch 3: enable (opens the market)

Last (checklist step 21). Action 0 first, then action 1.

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | PerpAsset (USDCcNGN-PERP)<br>`0xC74EfC8B4808803dBCF439E76Fde076d56625b8E` | `setTotalPositionCap(address,uint256)` | `manager` = `0xde0423d0a1e15536265c9513d2e0c10dab5835d4` (StandardManager (perp SRM))<br>`cap` = `50000000000000000000000000` (50,000,000 cNGN, 18dp) | Opens the perp to every path, bounded: open interest may reach 50,000,000 cNGN summed over both sides (25,000,000 cNGN a side). Until this, the cap is 0 and nothing can open a position. | `0x0ad282fd4472be5072fcdb1566d1fd76898179482a57d3a9e5fa28bf78cd8ede` |
| 1 | Matching<br>`0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191` | `setAllowedModule(address,bool)` | `module` = `0xdea968188598ba0e3f58a56c0fdff338c74f699f` (TradeModule (perp))<br>`allowed` = `true` | Opens the venue: Matching accepts orders settled through the perp's TradeModule. From here the matcher trades the perp. | `0xcd88a11493bb464face11ab4b8655fba60907f2f599251e46c57828b5773ff30` |
