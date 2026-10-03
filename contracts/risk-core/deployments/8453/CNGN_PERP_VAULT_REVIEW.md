# USDCcNGN-PERP vault actions: review before signing

Rendered 2026-10-03 22:49 UTC from commit `c25d4df`, from `CNGN_PERP_STACK.json`, `CNGN_PERP_STACK_VAULT_ACTIONS.json`, `CNGN_PERP_TRADE_MODULE.json` and `CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json`.
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

## Batch 4: cNGN as margin (configure)

After the escrow deploy (`CNGN_PERP_COLLATERAL.json`: escrow `0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98`, factor 50%, cap 8,000,000 cNGN, rate floor 10%; hash of both batches `0x4d0ab1030a64e5a633d524f1a4931a5c876fcf98de13b291eb31204121ead54b`). In order; every prefix is a safe place to stop. None of these lets cNGN in.

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | cNGN escrow (perp collateral, WrappedERC20Asset)<br>`0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98` | `acceptOwnership()` | (none) | The vault takes ownership of the cNGN escrow (perp collateral, WrappedERC20Asset) (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing. | `0xca88cc3e17c9ade2aa6db53e30aa13913f2299a68b752cc78dc8d4e86225cb0a` |
| 1 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `setBaseAssetMarginFactor(uint256,uint256,uint256)` | `marketId` = `1`<br>`marginFactor` = `500000000000000000` (50%, 18dp)<br>`imScale` = `1000000000000000000` (100%, 18dp) | The haircut: 50% of cNGN's oracle value counts as maintenance margin (x1.00 again for initial margin) on market 1. Sized by CngnPerpCollateralFork so a long-naira account on cNGN alone, left at maintenance margin, is still solvent after a 25% step. | `0x2ee8bdae1eb1179e24690f48ea1c1bc5061440adeb274b97c66fa2da309e3fb9` |
| 2 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `whitelistAsset(address,uint256,uint8)` | `asset` = `0x37c976bb5d4887a714ef19af6b83e34fe2f37c98` (cNGN escrow (perp collateral, WrappedERC20Asset))<br>`marketId` = `1`<br>`assetType` = `3` (Base) | The SRM accepts the cNGN escrow as a BASE asset of market 1: valued at the market's spot feed (the perp index), haircut by the factor above. The escrow itself is still shut. | `0x9558de602b886a6250baeb2923b4e4f738750505e14d9e3c7d480074712d8f7b` |
| 3 | cNGN escrow (perp collateral, WrappedERC20Asset)<br>`0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98` | `setTotalPositionCap(address,uint256)` | `manager` = `0xde0423d0a1e15536265c9513d2e0c10dab5835d4` (StandardManager (perp SRM))<br>`cap` = `8000000000000000000000000` (8,000,000 cNGN, 18dp) | Opens the perp to every path, bounded: open interest may reach 8,000,000 cNGN summed over both sides (4,000,000 cNGN a side). Until this, the cap is 0 and nothing can open a position. | `0x54d64724a554b9fe729d3832218c856263e6291d833a084c078e056ab3e9f5f7` |
| 4 | CashAsset (the perp's USDC cash)<br>`0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272` | `setInterestRateModel(address)` | `rateModel` = `0x4446656122bf54c7b24ac023379d3717df29caaf` (InterestRateModel (replacement, 10% floor)) | The perp's cash prices borrowed cash on the replacement model: a higher floor so a USDC withdrawal against cNGN (borrowing stays on: a cNGN-only account pays its fee from zero cash) is unattractive. Changes no balance; interest accrues from the next touch. | `0xd8a14ded9ecfb188b9117b61a7078eccdda7d7099d90dd301460df1c7fb2dcc6` |

## Batch 5: cNGN as margin (open deposits)

LAST, on its own. Sign only once the keeper, markets-service and app are deployed with the escrow configured and the mainnet-fork rehearsal has run a cNGN scenario against this escrow.

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | cNGN escrow (perp collateral, WrappedERC20Asset)<br>`0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98` | `setWhitelistManager(address,bool)` | `manager` = `0xde0423d0a1e15536265c9513d2e0c10dab5835d4` (StandardManager (perp SRM))<br>`whitelisted` = `true` | THE ENABLING SWITCH: the escrow accepts the perp SRM, so cNGN can be deposited into perp accounts. Nothing can enter before this. Sign only once the keeper, markets-service and app that enforce the cNGN rules are live and the fork rehearsal has run a cNGN scenario against this escrow. | `0xa109461ae67d8885ade26a1cdadeacaeeaab8c949756eb3b4bc6c3b9fdf1c0d2` |

## Batch 6: stage (B) leverage, 5x with the cNGN factor re-sized

Only after the SecurityModule holds at least $6,000 of cash (it held $3,250 when this was rendered; the proposer refuses below the floor). In order: the requirements first (eases every account), then the factor 35% (tightens cNGN-margined accounts; a 1:1 hedge then liquidates on a ~30% naira rally, from ~43% today). Hedge mode stays 1:1 in markets-service and the app. Hash `0x22ff8b039708b4aef3f0635b35cd65adb12b6b9a49bafc0a9374674ba15527a1`.

| # | Target | Function | Arguments | Purpose | MPCVault digest |
| --- | --- | --- | --- | --- | --- |
| 0 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `setPerpMarginRequirements(uint256,uint256,uint256)` | `marketId` = `1`<br>`mm` = `120000000000000000` (12.0%, 18dp)<br>`im` = `200000000000000000` (20.0%, 18dp) | Perp margin requirements on market 1: maintenance 12.0%, initial 20.0% (5x). Lower than today's: eases every account, tightens none. Sized with the cNGN factor that follows (CngnPerpFiveXFork). | `0x4282de301de3bd8290eb30c5cd4f824c6e28102d9df96c56ebd76be5e40ef4de` |
| 1 | StandardManager (perp SRM)<br>`0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` | `setBaseAssetMarginFactor(uint256,uint256,uint256)` | `marketId` = `1`<br>`marginFactor` = `350000000000000000` (35%, 18dp)<br>`imScale` = `1000000000000000000` (100%, 18dp) | The haircut: 35% of cNGN's oracle value counts as maintenance margin (x1.00 again for initial margin) on market 1. Sized by CngnPerpCollateralFork so a long-naira account on cNGN alone, left at maintenance margin, is still solvent after a 25% step. | `0x21ffcdcf708911002a4209fbad7a467e942c104c784c7a22c434c6deaa97bee9` |
