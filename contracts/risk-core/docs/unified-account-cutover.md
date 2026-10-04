# Unified account cutover: spot onto the perp stack

Decided 2026-10-04. Spot and perp become one account per wallet under the perp SRM
(`0xDE0423D0…`): spot trades the perp's cNGN escrow (`0x37c976bb…`) through the perp TradeModule
(`0xDea96818…`) against the perp cash (`0xA74E49b4…`), and everything in the account is margin for
everything else (USDC in full, cNGN at its factor). No new contract is deployed: the perp
TradeModule trades any base asset an order names (only the perp asset is flagged `isPerpAsset`), and
the escrow is already a base asset on the SRM. This SubAccounts has no `changeManager`, so every
balance on the old spot stack moves by withdrawal and redeposit; only two accounts hold any (the MM's
#15 and the operator's #19).

What changes for a trader: one "Deposit margin"/one account; spot holdings count as margin; the
guardian's pause stops spot as well as the perp; a spot sell cannot overdraw cash (the venue's
funding check refuses the fill, so borrowing stays a perp-margin matter); trade history and candles
restart at the switch (the market's asset address changes); resting spot orders do not survive it.

## What was proved before the window

**Local venue** (`scripts/local-venue/up.sh --unified && scripts/local-venue/unified-rules.sh`,
passed 2026-10-04): `/v1/markets` binds spot to the perp escrow, module, cash and SRM; a spot trade
settles through the perp module with both legs on the perp cash and escrow, exactly per the spot fill
contract, with the executor's gas headroom; an overdrawn spot sell is accepted as an order and never
fills (`buyer_underfunded`); a unified account's cNGN is credited at the haircut in the SRM's own
headroom and it trades the perp; the guardian's pause refuses a spot order with `trading_paused` and
lifts; a withdrawal of the perp cash from a spot account pays USDC.

**Mainnet-fork rehearsal** (`scripts/local-venue/rehearse-mainnet.sh --unified --keeper-env …`, on a
temporary instance with the box's role, the keeper key never leaving AWS): a unified account holding
$800 cash and 500k cNGN with a 4M cNGN long-naira perp, insolvent after a 40% fall; the production
keeper takes the whole portfolio, cNGN included, and reports it (`keeper-cngn-inventory`); the
SecurityModule pays at most the auction's terminal maintenance-margin deficit. **Ran 2026-10-04 on
i-04bc4fc160c41339e (terminated after), branch `feat/unified-spot` at `cc871d0`, PASSED:** at the
crash the unified account was $622.09 under maintenance margin; the production keeper started its
auction and took it whole with one insolvent bid (tx `0xc18fd5f4…`), reported
`keeper-cngn-inventory: 500,000 cNGN`; the SecurityModule paid $696.35 in total for alice's and
the unified account's auctions against a terminal bound of $1,953.62 (alice $1,331.53 + mixed
$622.09), the keeper bidding well before the auctions' ends; all 12 keeper transactions were signed
for chain 31337 and none is valid on Base.

## Cutover, in order

Each step is verified before the next. Nothing here moves a user's funds without their signature.

1. **Freeze.** Announce the window. Set `desired_count_market_maker = 0` and apply: the spot MM stops
   quoting. Cancel its resting orders:
   `migrate-spot-mm.ts cancel --execute` (on the box, through the SSM wrapper that exports
   `MM_OWNER_PRIVATE_KEY` from `/numo/exchange/mm_private_key`; the box role must be able to read it).
2. **Migrate the MM.** `migrate-spot-mm.ts status` (dry), then `withdraw --execute` (two signed
   WithdrawalModule actions; the venue pays wrapped USDC and spot cNGN to the MM wallet), then
   `deposit --execute` (SubAccountCreator opens the unified account with the USDC into the perp cash
   under the perp SRM, then `escrow.deposit` of the cNGN). Note the new account id. The perp escrow's
   8M cap holds the MM's ~470k cNGN with room.
3. **Migrate #19** by hand in the app: Withdraw both assets from spot, then "Deposit margin" on the
   perp for USDC and for cNGN. (After step 5 the same is offered on the Assets tab as the legacy row.)
4. **Switch the services.** One Terraform apply with:
   - `cngn_spot_asset_address = <perp cNGN escrow>`, `trade_module_address = <perp TradeModule>`,
     `quote_asset_address = <perp cash>`, `spot_margin_manager_address = <perp SRM>`;
   - `legacy_withdrawal_asset_addresses = [<old wrapped USDC 0x364058…>, <old spot escrow 0x9d806fd…>]`
     so the old accounts stay withdrawable through the venue;
   - `mm_subaccount_id` / recipient = the id from step 2 (the MM's `MM_TRADE_MODULE_ADDRESS` follows
     `trade_module_address`), `desired_count_market_maker = 1`.
   Verify from the running tasks: markets-service and matcher task definitions carry the four spot
   envs and the withdrawal list with six addresses; execution-service's `TRADE_MODULE_ADDRESS` is the
   perp module; `/v1/markets` shows the spot market's `asset_address`, `trade_module_address`,
   `quote_asset_address`, `margin_manager_address` on the perp stack; the MM is quoting the new book.
5. **Switch the app** (Vercel production env, one redeploy): `NEXT_PUBLIC_USDCCNGN_MANAGER_ADDRESS`,
   `NEXT_PUBLIC_TRADE_MODULE_ADDRESS`, `NEXT_PUBLIC_WRAPPED_USDC_ASSET_ADDRESS` (= the perp cash),
   `NEXT_PUBLIC_CNGN_ASSET_ADDRESS` (= the perp escrow) to the perp stack, and
   `NEXT_PUBLIC_LEGACY_SPOT_MANAGER_ADDRESS` / `_USDC_ESCROW_ADDRESS` / `_CNGN_ESCROW_ADDRESS` to
   today's spot SRM and escrows. trading-app#110 then shows a wallet's old spot account as two
   withdraw-only rows on the Assets tab while anything is left in it.
6. **Prove it live.** A small spot trade and a small perp trade from one account; a withdrawal of
   each; the pager's next run (`sm coverage`, `negative-cash`); the keeper's `/health` with the
   escrow; a legacy withdrawal from an old account (#16 holds 1 cNGN) through the Assets tab row.
7. **Later.** `setAllowedModule(old spot TradeModule 0x12423B36…, false)` by vault action, once no
   old-stack order can matter; leave the old stack withdrawable indefinitely.

**Back out** (any step up to 5): re-apply the previous Terraform vars and app envs; migrated balances
stay where they were put and remain withdrawable either way.

## Risk notes

- The SecurityModule rule and the keeper's `MAX_CNGN_INVENTORY` now cover spot holdings: cNGN under
  the perp SRM is MM inventory plus margin deposits. Re-size `MAX_CNGN_INVENTORY` and the escrow cap
  against that total; the pager's `sm-coverage` reads actual one-side open interest and is unchanged.
- Thin cNGN liquidity is the exposure when the keeper inherits cNGN: it hedges on the perp rather
  than dumping on spot (unchanged).
- One pause, one SRM: a guardian pause for a perp incident stops spot too.
