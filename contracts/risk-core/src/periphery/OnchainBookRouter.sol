// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/ReentrancyGuard.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {OnchainBook} from "./OnchainBook.sol";

/// @dev The three CashAsset calls the router makes.
interface IRouterCash {
  function wrappedAsset() external view returns (IERC20);
  function deposit(uint recipientAccount, uint stableAmount) external;
  function withdraw(uint accountId, uint stableAmount, address recipient) external;
}

/**
 * @title OnchainBookRouter
 * @notice One call for an outside contract or wallet (spec C4.3): deposit collateral, take against an OnchainBook,
 *         optionally only reducing the position, and withdraw. It acts on the caller's own account and holds nothing
 *         between calls: no tokens, no accounts, no allowances.
 *
 *         Setup, once per owner: `subAccounts.setApprovalForAll(router, true)` (the router takes and withdraws for the
 *         owner), and the book's own permission on the account as for any take (`setApprovalForAll(book, true)`, or
 *         asset allowances to the book on the future and cash); the stable token approved to the router for deposits.
 *
 *         Withdrawing: CashAsset pays out only to a call from the account's owner, so the router holds the account for
 *         that one step (owner → router → owner, inside the call). Allowances are keyed by account and owner, so the
 *         owner's are untouched, but ERC721 clears a per-account approval (`approve(router, id)`) on transfer: a
 *         withdrawal needs `setApprovalForAll`. Splines the account quotes as a maker are inert only within the call.
 * @dev Not upgradeable and ownerless: nothing to administer.
 */
contract OnchainBookRouter is ReentrancyGuard {
  using SafeERC20 for IERC20;

  OnchainBook public immutable book;
  ISubAccounts public immutable subAccounts;
  IRouterCash public immutable cash;
  IERC20 public immutable stable;

  struct Route {
    uint accountId;
    /// @dev stable token units (USDC: 6 dp), pulled from the caller and deposited before the take; 0: none
    uint deposit;
    /// @dev the take; `amount` 0 skips it. `takerAccountId` must be `accountId`.
    OnchainBook.TakeOrder take;
    /// @dev passed to `take` as `optionalReport`
    bytes reports;
    /// @dev the take may only reduce the position: it must oppose it, and its size is cut to the position's
    bool reduceOnly;
    /// @dev stable token units withdrawn after the take; 0: none
    uint withdraw;
    /// @dev the withdrawal's recipient; 0: the caller
    address recipient;
  }

  event Routed(
    uint indexed accountId,
    address indexed owner,
    uint deposited,
    uint filled,
    uint avgPrice,
    uint withdrawn,
    address recipient
  );

  error R_NotOwner();
  error R_WrongAccount();
  error R_NotReducing();
  error R_WrongCash();

  constructor(OnchainBook book_, IRouterCash cash_) {
    if (address(book_.cash()) != address(cash_)) revert R_WrongCash();
    book = book_;
    subAccounts = book_.subAccounts();
    cash = cash_;
    stable = cash_.wrappedAsset();
  }

  /// @return filled position units the take filled (0 when skipped)
  /// @return avgPrice the take's average price, 18 dp
  function route(Route calldata r) external nonReentrant returns (uint filled, uint avgPrice) {
    address owner = subAccounts.ownerOf(r.accountId);
    if (msg.sender != owner) revert R_NotOwner();

    if (r.deposit > 0) {
      stable.safeTransferFrom(msg.sender, address(this), r.deposit);
      stable.forceApprove(address(cash), r.deposit);
      cash.deposit(r.accountId, r.deposit);
    }

    if (r.take.amount > 0) {
      if (r.take.takerAccountId != r.accountId) revert R_WrongAccount();
      OnchainBook.TakeOrder memory o = r.take;
      if (r.reduceOnly) o.amount = _reducing(o);
      (filled, avgPrice) = book.take(o, r.reports);
    }

    address recipient = r.recipient == address(0) ? msg.sender : r.recipient;
    if (r.withdraw > 0) {
      subAccounts.transferFrom(owner, address(this), r.accountId);
      cash.withdraw(r.accountId, r.withdraw, recipient);
      subAccounts.transferFrom(address(this), owner, r.accountId);
    }

    emit Routed(r.accountId, owner, r.deposit, filled, avgPrice, r.withdraw, recipient);
  }

  /// @dev The take's size cut to the position it reduces; reverts unless it opposes a position.
  function _reducing(OnchainBook.TakeOrder memory o) internal view returns (uint) {
    (address future, uint96 subId) = _series(o.marketId);
    int pos = subAccounts.getBalance(o.takerAccountId, IAsset(future), subId);
    if (o.isBuy ? pos >= 0 : pos <= 0) revert R_NotReducing();
    uint size = uint(pos < 0 ? -pos : pos);
    return o.amount < size ? o.amount : size;
  }

  /// @dev `markets(id)`'s first and third words (future, subId): the getter returns 13 static words, and decoding all
  ///      of them is too deep for the legacy pipeline.
  function _series(uint marketId) internal view returns (address future, uint96 subId) {
    (bool ok, bytes memory ret) = address(book).staticcall(abi.encodeCall(book.markets, (marketId)));
    require(ok);
    (future,, subId) = abi.decode(ret, (address, address, uint96));
  }
}
