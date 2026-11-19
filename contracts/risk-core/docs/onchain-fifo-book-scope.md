# On-chain FIFO book: scope (draft, 2026-11-19)

Resting limit orders on the OnchainBook, merged with makers' splines in one `take`: the B13 constraint in
`eurc-usdc-futures-spec.md` and roadmap item 6, scoped against two references. Perpl
(docs.perpl.xyz/exchange/order-book) for the EVM data structures; Phoenix
(docs.phoenix.trade/phoenix/matching-engine/fifo-order-book, spline-liquidity) for the semantics. Nothing here is
built. Target: a series after 30NOV26; the deployed books are immutable, so this ships as a new book with a new series.

## What exists today

- `OnchainBook` (risk-core/src/periphery): splines only. Allowlisted makers post curves (`setCurve`,
  `registerMaker`, `updateSplines`); anyone takes (`take`, `quote`). No function places or cancels a resting order.
- App users trade through `BookTakeModule` (2026-11-19): a signed take for an account `Matching` holds, submitted by
  the executor. Take-only: a limit order is fill-or-kill.
- The matcher (markets-service) is an off-chain FIFO book. It still accepts futures orders, but no maker quotes
  there, and its orders never meet the on-chain curves.

## Three constraints that decide the design

### 1. Custody: a resting order from a `Matching` account cannot be filled

A fill moves the maker's position and cash, so the book needs the maker account owner's permission at fill time.
`Matching` holds every app user's account and has no approve function (`Matching.sol`, `SubAccountsManager.sol`):
it lends an account to a module only inside a `verifyAndMatch` call that the account's owner signed. A taker's
`take` runs long after the maker posted, with no maker signature in it, so the book cannot settle against a
`Matching` account. This is not a bug to patch: `Matching` is immutable, and the gap is structural.

Options:

| | How | Cost |
|---|---|---|
| **A. A book custodian** (recommended) | A new contract holds app users' accounts instead of `Matching`. It approves the allowlisted books on `SubAccounts` once, and executes user-signed (EIP-712) post, cancel, change, take and withdraw, relayed by the executor. The user keeps an exit: withdraw the account to their wallet at any time. | One new custody contract (the most sensitive code in the system) and a migration of each user's account out of `Matching` (`requestWithdrawAccount` → deposit to the custodian). Futures then stop depending on `Matching`. |
| B. Self-custody | Accounts owned by the user's wallet, `setAssetAllowances` to the book, the user sends their own transactions. | No longer gasless. Privy email wallets hold no ETH; fixing that is ERC-4337 smart wallets with a paymaster, a vendor integration. |
| C. Pre-signed resting orders | Makers sign `Action`s; the executor bundles them into a take so `Matching` lends their accounts. | The executor chooses which resting orders fill: off-chain matching again. Rejected: it is the matcher we are replacing. |

Self-custodied accounts (market makers, integrators, routers) can rest orders directly under any option.

### 2. Gas: settlement, not the book, is the cost

Measured (B10): a take settles each counterparty account through `SubAccounts` and the engine's margin hook at
~610k gas; the book's own logic is small. Perpl's ~100k post-and-cancel keeps balances inside the book; ours stay
in the shared margin accounts on purpose (positions usable by lenders, C0 items 4 and 5). A FIFO book of many small
makers multiplies counterparties, so:

- Settle once per counterparty account per take, whatever the number of its orders filled (as splines are now).
- Cap distinct counterparties per take (Phoenix's `match_limit`, counted per account here): 8 gives a worst take of
  ~5.5M gas on Base.
- **Measure first** (B13 already asks): one `submitTransfers` carrying every fill of a take, against one batch per
  counterparty. If the engine's per-account check dominates either way, the cap is the lever; reserving margin for
  resting orders in the engine (Phoenix's model, out of scope here) is the larger one.

Post, cancel and change touch only the book (no settlement): ~60–120k gas, in Perpl's range.

### 3. Size: the book is at the contract size limit

`OnchainBook` is 23,563 bytes of runtime code; EIP-170 allows 24,576. The FIFO code cannot be added inline. Put it
in an external library (`FifoBookLib`, called by `DELEGATECALL`, storage stays in the book), so one `take` can walk
splines and resting orders together without a cross-contract call per level.

## Design (B13, with the references' choices)

**Structures** (Perpl):
- Per side, a three-level bitmap tree of 256-bit words over price ticks (16.7M levels; cNGN at a 1e-8 tick is
  ~68,700, EURC at 1e-6 ~1.1M): next better or worse price in O(1) words.
- Order slots from a two-level bitmap (65,536 per market), reused on cancel or fill.
- One storage slot per order: account id, remaining lots, price tick, expiry, flags, and prev/next slot ids (a
  doubly linked FIFO list per level, head and tail per level).
- Per account, its order slots per side (cap below), for cancel-all and to drop an account's orders when it fails.

**Semantics** (Phoenix):
- Price, then time. At an equal price, splines fill before resting orders, up to the next resting price; a worse
  spline never jumps a better resting order.
- Order types: `Limit` (rests after crossing), `PostOnly` (rejected if it would take; no sliding in v1),
  `ImmediateOrCancel` (today's `take`), `FillOrKill` (`minFill` = amount), reduce-only (clamped to the position at
  fill time, cancelled when flat), expiry by timestamp. Change (amend) as Perpl: a smaller size keeps priority, a
  larger size or new expiry moves to the back.
- Self-trade: today's `Abort` and `DecrementTake`, plus `CancelResting`.
- Limits: 64 resting orders per side per account per market (Phoenix); a minimum order size; a market-wide order cap
  below 65,536.

**Failure at fill time.** The engine does not reserve margin for resting orders, so a counterparty can fail its
check when hit: the take skips it, cancels that account's orders on the levels it touched, and re-plans, as it
already does for a failing maker (try/catch per counterparty, B5a). Post checks the account is under the series'
engine, has granted the book its allowances and holds initial margin for the order, but cannot guarantee it later.

**Stale orders** (Perpl): an order with an expiry pays a recycling fee, refunded on cancel or full fill; a taker who
walks into an expired order clears it and keeps the fee. No keeper, no off-chain hand on the book. Every order dies
at the series' last trade time; a new series is a new market.

**Fees.** Taker fee as now. Resting makers pay 0 (as splines), no rebate in v1.

## Off chain

- **Custodian relay** (option A): post, cancel, change and take as signed actions through markets-service and the
  executor, as `BookTakeModule` takes are today. The venue pays ~100k gas a post, so the budget, a per-owner rate
  limit and the minimum order size matter more than for takes.
- **Indexer**: `OrderPosted`, `OrderCancelled`, `OrderChanged` and fills into the venue's order history and tape.
- **Depth**: an L2 view read from the book's levels, merged with the spline ladder `/book-depth` serves now.
- **App**: limit orders rest; Open Orders lists them; cancel and amend; the migration of each user's account to
  the custodian.

## Phases and effort

| | Work | Estimate |
|---|---|---|
| 0 | Measure: one batch vs per-counterparty settlement on a fork; set the counterparty cap and gas floor | 1–2 days |
| 1 | Custody (option A): the custodian, its signed actions and exit, fork tests, review | ~1 week |
| 2 | `FifoBookLib` and OnchainBook v3: structures, post, cancel, change, merged `take`/`quote`, failure handling, recycling; unit, invariant and fork tests, every guard broken and restored, gas snapshots | 2–3 weeks |
| 3 | Services and app: relay, indexer, depth, Open Orders, migration flow | 1–1.5 weeks |
| 4 | External audit of the custodian and the book; fork rehearsal; deploy for the next series | audit lead time |

About 5–7 weeks of build before an audit. The current series expire on 30 Nov; this is for a later one.

## Decisions for the owner

1. Custody: A (book custodian, recommended), B (self-custody, user pays gas) or both.
2. Who pays for posts: the venue (gasless, rate-limited) or the user.
3. Equal-price priority: splines first (Phoenix, proposed) or resting orders first.
4. Maker incentive: zero fee (proposed) or a rebate.
