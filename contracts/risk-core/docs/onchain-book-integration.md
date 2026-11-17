# Integrating with the OnchainBook

How another contract prices, takes, and reads positions on Numo's futures, in the same transaction as its own logic
(spec Part C, `eurc-usdc-futures-spec.md`). The kit:

| | |
|---|---|
| Interface | `src/interfaces/IOnchainBook.sol`: take, quote, market and spline reads, events, a take's errors. Asserted equal to the contract's ABI (`test/periphery/OnchainBookKit.t.sol`) |
| Router | `src/periphery/OnchainBookRouter.sol`: deposit, take, reduce-only, withdraw in one call, for wallets and simple contracts |
| Example | `examples/DeltaHedgedEurcVault.sol`: a Morpho flash loan, an Aerodrome swap, Morpho collateral and borrow, and a book short, in one transaction; `close` unwinds it in one more and `withdrawMargin` returns the cash. Fork-tested on a book built on the fork (`test/fork/OnchainBookKitFork.t.sol`) and on the deployed v2 book, the existing Morpho EURC/USDC market and the Aerodrome pool at head (`test/fork/DeltaHedgedEurcVaultLiveFork.t.sol`). Run once on mainnet, 2026-11-17: open `0xa634e40d…` (1.39M gas), close `0x74026401…` (1.14M). Not audited |

**Which book.** EURC-30NOV26 has two books, market 1 on each. v2 (`0x83C5741a24d57189379E1215F7A22d9f048E89d5`, from
2026-11-17, router `0xd9540220b514ab2E1a98Ff3C4c4F1F5FD5cf76aB`) has everything here: `quote`, self-priced quotes, the
router. v1 (`0x8Fc63DcB3a173aAF5d2de0F42648D908A519d456`) has `take` and the reads only, and pegged quotes. Read the
current address from the markets API, never a hard-coded one.

## Units

| | |
|---|---|
| Position | the future's units, 18 dp: `1e18` is one contract (1,000 EURC on EURC-USDC). Takes round down to whole lots (`lotSize`, 1 EURC) |
| Price | quote per base, 18 dp (USDC per EURC) |
| Cash, fees, margin | 18 dp. Deposits and withdrawals through CashAsset take the stable token's units (USDC: 6 dp) |

EURC (6 dp) to position units: `eurc * 1e30 / contractSize`, then round down to `lotSize`.

## Setup

1. **An account** under the market's margin engine (`markets(id).engine`): `SubAccounts.createAccount(owner, engine)`.
   A contract can own its own account (the example does).
2. **Cash** in it as margin: `CashAsset.deposit(accountId, usdcAmount)` after approving USDC to the cash asset.
3. **The book's permission** on the account, to move its positions and pay fees: `SubAccounts.setApprovalForAll(book,
   true)` from the owner, or asset allowances to the book on the future and on cash.
4. **The caller** of `take` must be the account's owner or an operator (`setApprovalForAll`) of that owner.

## Price, then take

```solidity
IOnchainBook.TakeOrder memory o = IOnchainBook.TakeOrder({
  marketId: id, takerAccountId: acc, isBuy: true, amount: 100e15 /* 100 EURC */,
  limitPrice: 1.20e18, minFill: 100e15, maxFee: 1e18, deadline: uint64(block.timestamp),
  maxLevels: 50, selfTradeMode: IOnchainBook.SelfTradeMode.Abort, managerData: ""
});
(uint qFilled, uint qAvg, uint qFee, uint makerCount) = book.quote(o);   // a view
(uint filled, uint avgPrice) = book.take(o, reports);                   // reports: abi.encode(bytes[]) or ""
```

- **`quote`** returns what `take(o, "")` would do now if every maker's settlement succeeds, with the same reverts. It
  reads the stored reports (a view cannot post), includes the priority tax at the call's gas price, and cannot foresee
  a maker's settlement reverting on margin: in `take` that maker's lots go to the others in a second round. `makerCount`
  sizes gas. `takerAccountId` 0 prices the book with no account.
- **`take`** returns the filled size and average price. **Bound it**: `limitPrice` (worst price), `minFill` (set it to
  `amount` for all or nothing, which a hedge wants), `maxFee`, `deadline`, `maxLevels`.
- **Reports.** Pegged quotes price from the index and fill only while both stored Data Streams reports are at most
  `takeMaxAge` old. Attach fresh reports (`abi.encode(bytes[])` of signed reports, from Chainlink Data Streams) to
  `take` and the book posts them first. Self-priced quotes need none: the maker carries the staleness (its ttl, at most
  `maxSelfPricedTtl`). Every fill, either kind, must be inside the index band, so an index that cannot be read (its
  reports over 60 s old) fills nothing.
- **Nothing to fill is not an error.** `take` returns 0 filled when no quote is live or in range, unless `minFill` says
  otherwise.

### Reverts a taker sees

| Error | Meaning |
|---|---|
| `OB_InvalidMarket` | no such market |
| `OB_MarketDisabled` | the owner switched the market off |
| `OB_TradingClosed` | at or after `lastTradeTime` (30 min before expiry) |
| `OB_Expired` | past `deadline` |
| `OB_NotAuthorized` | the caller is neither the account's owner nor the owner's operator |
| `OB_TakerAllowanceTooLow` | the book lacks permission on the account (setup step 3) |
| `OB_FeeTooHigh` | fee plus priority tax over `maxFee` |
| `OB_BelowMinFill` | filled less than `minFill` |
| `OB_SelfTrade` | crossed a maker the taker's owner also owns, with `Abort` |
| `OB_GasFloor` | too little gas left to settle the next maker: send more gas |

A margin failure on the taker's account reverts from the margin engine.

## Events

| Event | When |
|---|---|
| `Fill(marketId, takerAccountId, makerAccountId, isBuy, amount, price, fee)` | one per maker settled; `price` is that maker's average |
| `TakeExecuted(marketId, takerAccountId, isBuy, filled, avgPrice, fee)` | once per take: what `take` returned; `fee` includes the priority tax |
| `MakerSkipped(marketId, accountId, reason)` | a maker's settlement reverted; its lots went back to the take |

The fills of a take sum to its `filled` (the markets indexer checks this). Index at the log's block, after your
confirmation depth.

## Reading positions, margin and the mark

| Read | Call |
|---|---|
| Position | `SubAccounts.getBalance(accountId, future, subId)` (18 dp contracts; negative = short) |
| Cash | `SubAccounts.getBalance(accountId, cash, 0)` |
| Margin | `MarginEngine.getMargin(accountId, isInitial)`: negative maintenance margin means liquidatable; `getMarginAndMarkToMarket(accountId, isInitial, 0)` adds the mark-to-market |
| Mark, expiry, settled | `FutureAsset.futureContracts(subId)` → `markPrice`, `lastTradeTime`, `expiry`, `settled` |
| Index | `FutureAsset.indexFeed().getSpot()` (reverts when stale) |
| Auction | `DutchAuction.isAuctionLive(accountId)` |

## Router

For wallets and contracts that do not want to own the account steps:
`OnchainBookRouter.route(Route{accountId, deposit, take, reports, reduceOnly, withdraw, recipient})` → `(filled,
avgPrice)`. Only the account's owner calls it. Setup: `SubAccounts.setApprovalForAll(router, true)` and the book's own
permission as above. CashAsset pays out only to the owner, so for a withdrawal the router holds the account for that
step and returns it in the same call; an `approve(router, id)` for one account is cleared by that transfer, so use
`setApprovalForAll`. Reduce-only cuts the take to the position and refuses one that would not reduce it.

## Gas (Base, live-stack fork)

| | gas |
|---|---|
| take, 1 maker, reports attached | 1,269,142 |
| take, 1 maker, reports already posted | 1,135,791 |
| take, 2 / 5 / 10 makers | 1,746,074 / 3,576,952 / 6,625,717 |
| router: deposit + take (1 maker, reports) + withdraw | 1,364,329 |
| example `open`: flash loan + swap + collateral + borrow + short (3 makers) | 3,276,751 |

About 610k per maker settled (spec B10); `quote`'s `makerCount` predicts it. Measured in the spec's C4 entries.

## Pitfalls

- **`markets(id)` returns 13 values.** Destructuring them is too deep for solc's legacy (non-IR) pipeline. Use the
  interface's `MarketView` struct return: same selector, same bytes.
- **A priority fee costs extra when the tax is on**: `priorityTaxRate` per wei of gas price over the base fee, on a take
  that fills. Quote at the gas price you will send.
- **Settlement is atomic per maker, not per take.** A maker whose settlement reverts is skipped and the take continues;
  use `minFill` if a partial result is unacceptable.
- **Expiry.** No takes from `lastTradeTime`; positions are then settled at the fixing (spec A8) and closed out by the
  keeper.
