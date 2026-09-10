# Wrapped-USDC quote module: preconditions and cutover

Moving the quote leg from `CashAsset` to `WrappedERC20Asset` (wrapped USDC) makes the USDC
side structurally 1:1 — the ledger balance is minted on deposit and burned on withdrawal,
so it cannot be credited by a manager the way cash can. That is the point of the change.

`TradeModule.quoteAsset` is **`immutable`** (`contracts/execution/src/modules/TradeModule.sol:32`), so this is a
new module deployment, not a reconfiguration. Everything below follows from that.

This document covers the three things that are not in the deploy script's happy path.

## 1. The fee recipient is ungrantable, not merely ungranted

```
TradeModule.feeRecipient = 1
subAccounts.ownerOf(1)   = 0x3195Bd7e…   ← the StandardManager contract
```

`WrappedERC20Asset.handleAdjustment` returns `needAllowance = true` unconditionally — including
on the **credit** side, because the asset cannot be forced onto an account that has not agreed
to receive it. `CashAsset` returns `adjustment.amount < 0`, so cash fees need no allowance and
the problem does not exist today. In `SubAccounts._transferAsset`:

```solidity
if (toAdjustmentNeedAllowance && !_isApprovedOrOwner(msg.sender, toAccAdjustment.acc)) {
  _spendAllowance(toAccAdjustment, ownerOf(toAccAdjustment.acc), msg.sender);
}
```

Subaccount 1's owner is a contract with no path to `setAssetAllowances` or `setApprovalForAll`
— checked across `StandardManager` and `BaseManager`. So it can never grant the allowance, and
every fee-bearing fill would revert.

This is why there is no cheaper fix than a new fee subaccount: the problem is not a missing
transaction, it is a missing capability at an address nobody controls.

Subaccount 1 holds nothing (`getAccountBalances(1) == []`), so moving the recipient strands no
accrued fees.

### The account id must come from the return value, not from an expectation

`subAccounts.createAccount(owner, manager)` mints to `owner`, but **anyone may call it**. Ids
are sequential and global, so between reading `lastAccountId` and mining your own transaction,
someone else's `createAccount` can take the id you expected. Wiring that id into the
constructor of an immutable-quote module burns the deployment: the module would pay fees into
a subaccount the vault cannot grant an allowance on, and the only repair is redeploying.

Two rules, and the first one is what actually removes the race:

- **Create the account inside the deploy script's broadcast and use the returned id.**
  `createAccount` returns `newId`, so the value is never guessed.

  This narrows the window but does **not** close it. Under `forge script`, `createAccount`
  and `new TradeModule(...)` are two separate broadcast transactions, and the constructor
  argument is fixed during local *simulation* — so a stranger's `createAccount` landing
  between the two still produces a module wired to an id the vault does not own. Closing it
  completely needs either one atomic transaction (a throwaway deployer contract whose
  constructor creates the account and deploys the module) or a post-broadcast postcondition
  that re-reads `subAccounts.ownerOf(module.feeRecipient()) == vault` against real state.
  The postcondition turns a burned deployment into a detected failure, at the cost of one
  wasted `TradeModule` — cheap, since nothing is wired until the vault batch runs.
- **Assert `ownerOf(id) == vault` before the id reaches the constructor.** Necessary in both
  designs — it is the only check that catches an id supplied out of band, and per the point
  above it is still the last line of defence when the script creates the account itself.

The script on `feat/spot-wrapped-usdc-quote`
(`contracts/execution/scripts/deploy-wrapped-quote-trade-module.s.sol`) currently takes `FEE_RECIPIENT_SUBACCOUNT` from
the environment and checks only that its owner is not a contract:

```solidity
address feeOwner = subAccounts.ownerOf(feeRecipient);
if (feeOwner.code.length != 0) revert("fee recipient is contract-owned …");
```

That catches subaccount 1. It does **not** catch a raced id owned by some other EOA — which
passes `code.length == 0`, and passes the manager check too if that account happens to sit
under the SRM. Tighten it to:

```solidity
if (feeOwner != vault) revert("fee recipient is not vault-owned");
```

and prefer creating the account in-script so the value is never guessed at all.

## 2. Step 4 is the cutover, and resting orders do not survive it

Allowlisting the new module is not a configuration change, it is a migration moment. Orders
resting in the book were signed against the **old** module's address, which is part of the
EIP-712 domain and the action payload. They cannot be filled by the new module, and re-signing
is the only way to carry them across.

The runbook therefore needs, in order:

1. Stop accepting new orders, and cancel the resting book. Do not rely on expiry.
2. `matching.setAllowedModule(newModule, true)` — **without** disallowing the old one.
3. Repoint `TRADE_MODULE_ADDRESS` on the execution service and redeploy.
4. Re-sign and repost the book against the new module.
5. Only once no in-flight fill can name the old module,
   `matching.setAllowedModule(oldModule, false)`.

**Both modules stay allowed across the gap deliberately.** `Matching` rejects a module that is
not allowlisted (`contracts/execution/src/Matching.sol:64`), so a hard switch fails any fill that was verified against
the old module and had not yet landed — which is precisely the window where a matcher retry
lands a transaction built moments earlier. Allowing both costs nothing while no order is signed
against the old one, and it converts a class of hard failure into a no-op.

Step 5 is a real step, not a tidy-up. Leaving the old module allowed indefinitely leaves a
second, cash-quoted path into the same subaccounts.

## 3. `negative: 0` on the fee allowance is correct — do not widen it

The grant is:

```solidity
IAllowances.AssetAllowance({asset: wrappedUSDC, positive: type(uint).max, negative: 0})
```

`positive` lets the module credit fees in. `negative` would let the module take wrapped USDC
**out** of the fee account, which it has no reason to do — fees only ever flow inward.

**Withdrawing collected fees is the vault acting on its own subaccount directly**, calling
`WrappedERC20Asset.withdraw(feeAcct, amount, recipient)` as the owner. `_isApprovedOrOwner`
short-circuits the allowance check entirely for the owner, so no negative grant is needed for
that path, ever.

This matters because the symptom of getting it wrong looks like the symptom of a missing
allowance. If a withdrawal is attempted by anything other than the owner it will revert on the
negative side, and the tempting repair is to widen the grant to
`negative: type(uint).max`. That would hand the trade module standing authority to move fees
out of the account. The correct repair is to withdraw as the vault.

`type(uint).max` on the positive side is not a stylistic choice: `_spendAbsAllowance`
(`contracts/risk-core/src/Allowances.sol:130-150`) decrements on every spend with **no max-value exemption**, unlike
most ERC20 implementations. A finite grant is a scheduled outage. `2^256` fee units is
unreachable, so one grant is permanent in practice.

## Order of operations

1. Commit and ship the settlement canary, so the new module's first fills are watched.
   (Done: `execution:641e6f2b8764`.) Add the new fee subaccount to
   `SETTLEMENT_CANARY_ACCOUNTS` once it holds a balance.
2. Create the fee subaccount, vault-owned, SRM-managed — ideally inside the deploy script.
   `subAccounts.balanceOf(vault)` is **0** today, so there is no existing subaccount for
   `FEE_RECIPIENT_SUBACCOUNT` to point at; in-script creation removes a manual pre-step, not
   only a race. `createAccount(owner, manager)` mints to an arbitrary owner, so the deployer
   key can create it for the vault without a vault transaction.
3. Deploy the module with `quoteAsset = wrapped USDC` and the returned fee subaccount id.
4. Vault batch: `setAssetAllowances(feeAcct, module, +max/-0)`, then the cutover in §2.
