# BookCustodian: spec (2026-11-19; built and reviewed once, not deployed)

Option A of `onchain-fifo-book-scope.md`, decided by the owner 2026-11-19: a contract holds app users' trading
accounts so the OnchainBooks can act on them, built now, and accounts migrate into it mid-series once it is reviewed.
EURC-31DEC26 lists on time on today's path (`Matching` + `BookTakeModule`). Nothing here is deployed.

Model: Phoenix's (accounts held by the exchange side, a wallet authority and a trading-only delegate), with our
gasless relay in front. Perpl and Phoenix were read for this (`onchain-fifo-book-scope.md`).

Code: `src/periphery/BookCustodian.sol`. Tests: `test/fork/BookCustodianFork.t.sol`.

## Guarantees (each is a test)

1. **Only the user's wallet withdraws, and only to itself.** A trading key can take, and act through modules the
   owner allowed for keys (`KeyModule`); never withdraw, exit, use any other module, clear grants or change keys.
2. **The exit always works.** `exit(accountId)`, called by the wallet itself, sends the account (the SubAccounts NFT,
   with its positions and balances) to the wallet, and first zeroes every allowance the custodian left on it. No
   relayer, no admin, no pause, no allowlist, no cooldown can block it.
3. **No admin path to balances.** The owner (the vault) has no function that moves an account, a balance or a
   position. Not upgradeable, no `delegatecall`. A test pins the whole external surface from the compiled ABI.
4. **Nothing is ever ERC-721 approved on an account.** An approved address could re-delegate the account to itself
   (`setAssetAllowances`), which outlives the call (the 2026-11-19 review proved it, F1). Instead:
   - a **book** gets SubAccounts subId allowances for exactly the signed order: its size on the series, in its
     direction, and its `maxFee` on cash (an immutable of the custodian, not the book's say), zeroed after the call;
   - a **module** gets only the allowances the signer lists in the signed `Act` (`grants`): zeroed after the call, or,
     with `persist` (a resting order's power to settle), recorded per account (at most 16) until the wallet calls
     `clearGrants` or exits;
   - books, modules, key modules, managers and deposit assets are usable only 48 hours after the owner queues them,
     so users can leave first. Disallowing is immediate. A disallowed module's persisted grants stay until the wallet
     clears them or exits (the wallet's own choice; no admin path touches them).
5. **A signature authorizes one action once.** EIP-712, per-signer nonces, a deadline; the account is part of what is
   signed, so a signature for one account cannot act on another.

What it cannot promise (the layer below, as today): the vault's admin powers on SubAccounts' assets and the
MarginEngine (freezes, caps), liquidation under maintenance margin, and token issuers' freezes. An account's manager
can move the account (SubAccounts authorizes it); a take or action during which that happens reverts.

## Functions

**Accounts and deposits** (anyone may relay; the signer is what is checked):
- `openAccount(wallet, manager)`, by anyone (an empty account harms no one): `SubAccounts.createAccount` under an
  allowed manager (MarginEngine v2), recorded to the wallet.
- `deposit(accountId, asset, amount)`: the caller's own tokens after an ERC-20 `approve` (cNGN has no permit).
- `depositWithPermit(accountId, asset, amount, deadline, v, r, s)`: EIP-2612 permit from the account's own wallet
  (USDC and EURC on Base). A relayer's call needs the permit to succeed, or, if it was front-run, exactly `amount`
  approved; only the wallet itself can use a standing approval (review F3).
- `onERC721Received`: a wallet sends its own account in with `safeTransferFrom`; recorded to it. The operator must be
  the owner (review F4: never an approved operator or manager), and the account under an allowed manager.

**Trading**:
- `take(Take, signature, reports)`: the book's `take` for the account, all-or-nothing as signed, self-trade Abort.
  `reports` are Data Streams reports the book verifies, so a relayer may attach fresh ones (review F8). `reduceOnly`
  cuts the size to the opposing position, in whole lots (review F6).
- `act(Action, signature)`: an allowed module's `onAct(accountId, wallet, signer, data)`, with the signed grants. The
  module is told who signed (review F2).
- `clearGrants(accountId)`: the wallet zeroes every persisted grant.

**Leaving** (the wallet only):
- `withdraw(accountId, asset, amount)` from the wallet, or `withdrawFor(..., nonce, deadline, signature)` with the
  wallet's own signature: the asset's `withdraw` to the wallet, never elsewhere. The engine refuses one below initial
  margin. The venue's "no borrowed cash out" rule stays in markets-service for relayed withdrawals.
- `exit(accountId)` from the wallet, or `exitFor(accountId, nonce, deadline, signature)`. An account the engine has
  already moved out just has its record cleared.

**Keys**: `setTradingKey(key, validUntil)` from the wallet (zero key revokes), or `setTradingKeyFor` with its
signature. `cancelNonce(nonce)` burns any of the caller's nonces.

**Owner (vault)**: `queue`, `cancelQueued`, `enable` (48 h after queueing), `disallow` (immediate), `setPaused`
(takes and actions only); `Ownable2Step`. The constructor may allow entries at once: before deployment there are no
accounts.

## Signed types (EIP-712, domain `NumoBookCustodian`, version `1`, Base)

The type strings are the `*_TYPEHASH` constants:
`Take(uint256 accountId,address book,uint256 marketId,bool isBuy,uint256 amount,uint256 limitPrice,uint256 minFill,uint256 maxFee,uint64 deadline,uint16 maxLevels,bool reduceOnly,uint256 nonce)`,
`Act(uint256 accountId,address module,bytes data,Grant[] grants,bool persist,uint256 nonce,uint64 deadline)` with
`Grant(address asset,uint256 subId,uint256 positive,uint256 negative)`,
`Withdraw(uint256 accountId,address asset,uint256 amount,uint256 nonce,uint64 deadline)`,
`Exit(uint256 accountId,uint256 nonce,uint64 deadline)`,
`SetTradingKey(address wallet,address key,uint64 validUntil,uint256 nonce,uint64 deadline)`.
`takeDigest` and `actDigest` return what to sign.

## Notes for the services and the app (from the review)

- **Contract wallets** (review F5): OpenZeppelin's `SignatureChecker` uses only EIP-1271 for an address with code,
  EIP-7702-delegated EOAs included. A wallet whose delegate has no `isValidSignature` cannot use the signed paths;
  direct `exit` and `withdraw` still work. The app checks `code.length` before offering a relayed path.
- **`maxFee` binds the priority tax too** (F8): the relayer chooses the gas price, and OnchainBook charges a priority
  tax on it (0 on both live books, read 2026-11-19; the book owner can raise it). The app signs a tight `maxFee`.
- **Key rotation** (F9): rotating a key away and back revives the old key's unexpired, unused signatures. Takes are
  signed with 60 s deadlines, so this is narrow; the app never reuses a key.
- **Account discovery** from the custodian's events only, never `ownerOf == custodian`: anyone can create accounts
  owned by the custodian that it never recorded (`createAccountWithApproval(custodian, …)`), and those are inert.
- **`CashAsset.forceWithdraw`** pays `ownerOf(account)`, which would be the custodian, with no way out. It is
  manager-only and MarginEngine does not call it today; a manager change that does would need a custodian change.
- **FIFO self-trade identity** (F7): OnchainBook's self-trade check compares owners, and every custodian account has
  the same owner. A FIFO book or module must compare recorded wallets (`accountOwner`), or custodian users could never
  trade with one another.

## Migration out of `Matching`

`Matching`'s own exit is the only way out of it: `requestWithdrawAccount` from the wallet, then
`completeWithdrawAccount` by anyone after 30 minutes, which sends the account to the wallet.

- **Accounts with an open position** keep it by moving the account itself: the wallet's `requestWithdrawAccount`
  (one transaction), the venue's `completeWithdrawAccount` 30 minutes later, then the wallet's
  `safeTransferFrom(wallet, custodian, id)` (a second). Two wallet transactions with gas; the venue may send the
  wallet enough ETH for them. Tested on a fork with a position carried across and closed from the custodian.
- **Flat accounts** move gaslessly: a signed `WithdrawalModule` withdrawal (today's), then `openAccount` and
  `depositWithPermit` into a new custodian account. cNGN needs an `approve` first.
- The app does it per user, with the account's state shown before and after. Our own accounts (#57, #61) go first.

## Services

- **execution-service:** submits custodian calls (`take`, `act`, `withdrawFor`, `exitFor`, `openAccount`,
  `depositWithPermit`) from the executor, policy-checked and simulated first as for `/book-take`.
- **markets-service:** the owner check reads `accountOwner` (instead of `Matching.subAccountToOwner`) for custodian
  accounts; `/book-takes` gains the custodian path; account discovery from the custodian's events.
- **App:** detects which holder an account is under; migration flow; trading key generated in the browser and set
  once by the wallet, so a take signs with the key (no wallet prompt per order).

## Tests

`test/fork/BookCustodianFork.t.sol`, on the live SubAccounts, MarginEngine v2, cash, the cNGN book and Matching
(37 tests). Each review finding has a `testReview*` test that failed against the first version. 42 mutations, each
removing or weakening one guard, are each caught by the suite (run 2026-11-19).

Not covered yet: exit of an account mid-auction (needs an underwater account on a fork); a real FIFO module (none
exists; the tests use stand-in modules).

## Plan

| | Work | Status |
|---|---|---|
| 1 | This spec, reviewed by the owner | done 2026-11-19 |
| 2 | `BookCustodian` and its tests | done 2026-11-19 |
| 3 | Adversarial review (not the author's) and fixes | first review and fixes done 2026-11-19; a fresh review of the fixed version next |
| 4 | Deploy, our own accounts first | after 3; a separate go-ahead |
| 5 | Services and app: relay paths, owner checks, migration flow, trading key | 3–4 days |
| 6 | External audit before user accounts migrate at scale | lead time |

## Decisions (change any)

- **48 h** timelock on everything that gains power over accounts.
- **Modules** for future actions (FIFO), with signed, bounded grants, so there is one migration, ever.
- **Pause** covers takes and module actions only.
- **One trading key** per wallet, with an expiry; keys reach only `KeyModule`s.
- **Venue-funded gas** for the two migration transactions of accounts with open positions.
