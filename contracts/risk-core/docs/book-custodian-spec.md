# BookCustodian: spec (draft, 2026-11-19)

Option A of `onchain-fifo-book-scope.md`, decided by the owner 2026-11-19: a contract holds app users' trading
accounts so the OnchainBooks can act on them, built now, and accounts migrate into it mid-series once it is reviewed.
EURC-31DEC26 lists on time on today's path (`Matching` + `BookTakeModule`). Nothing here is deployed.

Model: Phoenix's (accounts held by the exchange side, a wallet authority and a trading-only delegate), with our
gasless relay in front. Perpl and Phoenix were read for this (`onchain-fifo-book-scope.md`).

## Guarantees (the contract is built around these; each is a test)

1. **Only the user's wallet withdraws, and only to itself.** A trading key can take (and, with FIFO, post and cancel)
   but never withdraw, exit, delegate or change keys.
2. **The exit always works.** `exit(accountId)`, called by the wallet itself, sends the account (the SubAccounts NFT,
   with its positions and balances) to the wallet. No relayer, no admin, no pause, no cooldown can block it.
3. **No admin path to balances.** The owner (the vault) has no function that moves an account, a balance or a
   position. The contract is not upgradeable and has no `delegatecall`.
4. **A book or module gets power over accounts only after a 48-hour timelock.** Approving a book on SubAccounts gives
   it standing power over every account the custodian holds, so `allowBook` is queued and executable after 48 h,
   leaving users time to exit. Revoking is immediate (it only removes power).
5. **A signature authorizes one action once.** EIP-712, per-signer nonces, a deadline; the account is part of what is
   signed, so a signature for one account cannot act on another.

What it cannot promise (the layer below, as today): the vault's admin powers on SubAccounts' assets and the
MarginEngine (freezes, caps), liquidation under maintenance margin, and token issuers' freezes.

## State

| | |
|---|---|
| `accountOwner[accountId]` | the wallet the account belongs to; zero for an account the custodian does not hold |
| `tradingKey[wallet]` | `{key, validUntil}`: one trading-only delegate per wallet |
| `nonceUsed[signer][nonce]` | replay protection, per signer |
| `bookAllowed[book]`, `bookEta[book]` | the book allowlist and its queue |
| `moduleAllowed[module]`, `moduleEta[module]` | action modules (below) and their queue |
| `takePaused` | the owner may pause new takes and module actions; never exit, withdraw or key changes |

## Functions

**Accounts and deposits** (anyone may relay; the signer is what is checked):
- `openAccount(wallet, manager)` direct, or `openAccountFor` with the wallet's signature: `SubAccounts.createAccount`
  under the MarginEngine, recorded to the wallet. The manager must be one the custodian allows (MarginEngine v2).
- `depositWithPermit(accountId, asset, amount, permit)`: EIP-2612 permit from the wallet, then the asset's
  `deposit`. USDC and EURC support permits on Base (read 2026-11-19); cNGN does not, so cNGN uses
  `deposit(accountId, asset, amount)` after an ERC-20 `approve`, as the app does today.
- `onERC721Received` / `depositAccount`: a wallet sends its own SubAccounts account in; recorded to the sender. Only
  accounts under an allowed manager.

**Trading** (signed by the wallet or its trading key; relayed by anyone, so the venue's relayer is a convenience, not
a gate):
- `take(TakeAuth, sig)`: the book's `take` for the account, as `BookTakeModule` does today, with `reduceOnly` as the
  router does. The custodian is the account's owner, so `take` authorizes it directly; no lending.
- Module actions (FIFO post, cancel, change later): `act(module, accountId, data, sig)`. For the call the custodian
  approves the module on that one account (`SubAccounts.approve(module, accountId)`), calls it, then revokes. A module
  is an allowlisted, timelocked contract, so FIFO arrives without a new custodian or a second migration.

**Leaving** (the wallet only):
- `withdraw(accountId, asset, amount, deadline, sig)` or the wallet calling it directly: the asset's `withdraw` to the
  wallet, never elsewhere. The engine refuses one below initial margin, as now. The venue's "no borrowed cash out"
  rule stays in markets-service for relayed withdrawals; a direct withdrawal is the user's own call.
- `exit(accountId)`: the wallet only, `msg.sender` checked, no signature path needed: the NFT to the wallet and the
  record deleted. Also `exitFor` with the wallet's signature, so a relayer can do it for a wallet with no ETH.

**Keys**: `setTradingKey(key, validUntil)` and `revokeTradingKey()`, the wallet only (direct or signed).

**Owner (vault)**: queue, execute and revoke books and modules; pause and unpause takes and module actions; nothing
else. `Ownable2Step`.

## Signed types (EIP-712, domain `NumoBookCustodian`, version `1`, Base)

`OpenAccount`, `Take` (accountId, book, marketId, isBuy, amount, limitPrice, minFill, maxFee, deadline, maxLevels,
reduceOnly, nonce), `Act` (module, accountId, keccak(data), nonce, deadline), `Withdraw` (accountId, asset, amount,
nonce, deadline), `Exit` (accountId, nonce, deadline), `SetTradingKey` (key, validUntil, nonce, deadline). EIP-1271
for contract wallets, so a smart wallet can sign.

## Migration out of `Matching`

`Matching`'s own exit is the only way out of it: `requestWithdrawAccount` from the wallet, then
`completeWithdrawAccount` by anyone after 30 minutes, which sends the account to the wallet.

- **Accounts with an open position** keep it by moving the account itself: the wallet's `requestWithdrawAccount`
  (one transaction), the venue's `completeWithdrawAccount` 30 minutes later, then the wallet's
  `safeTransferFrom(wallet, custodian, id)` (a second). Two wallet transactions with gas; the venue may send the
  wallet enough ETH for them.
- **Flat accounts** move gaslessly: a signed `WithdrawalModule` withdrawal (today's), then `openAccountFor` and
  `depositWithPermit` into a new custodian account. cNGN needs an `approve` first.
- The app does it per user, with the account's state shown before and after. Our own accounts (#57, #61) go first.

## Services

- **execution-service:** submits custodian calls (`take`, `act`, `withdraw`, `exitFor`, `openAccountFor`,
  `depositWithPermit`) from the executor, policy-checked and simulated first as for `/book-take`.
- **markets-service:** the owner check reads `accountOwner` (instead of `Matching.subAccountToOwner`) for custodian
  accounts; `/book-takes` gains the custodian path; account discovery from the custodian's events.
- **App:** detects which holder an account is under; migration flow; trading key generated in the browser and set
  once by the wallet, so a take signs with the key (no wallet prompt per order).

## Tests

Unit and fork (live MarginEngine v2, the live books): every guarantee above as a test that fails when its guard is
removed (break it, see it fail, put it back); a malicious module and a malicious book (queued, not yet allowed: no
power; allowed: power only over the account in the call for a module); replay, wrong account, expired, a trading key
trying to withdraw, exit, delegate; exit while paused; exit of an account under liquidation; migration both ways on a
fork from a real `Matching` account.

## Plan

| | Work | Estimate |
|---|---|---|
| 1 | This spec, reviewed by the owner | now |
| 2 | `BookCustodian` and its tests (unit, fork, guards broken and restored) | 3–4 days |
| 3 | Internal adversarial review (a second pass, not the author's) and fixes | 1–2 days |
| 4 | Deploy, books queued (48 h), our own accounts first | after 3 |
| 5 | Services and app: relay paths, owner checks, migration flow, trading key | 3–4 days |
| 6 | External audit before user accounts migrate at scale | lead time |

## Decisions in this draft (change any)

- **48 h** timelock on books and modules.
- **Modules** for future actions (FIFO), so there is one migration, ever.
- **Pause** covers takes and module actions only.
- **One trading key** per wallet, with an expiry.
- **Venue-funded gas** for the two migration transactions of accounts with open positions.
