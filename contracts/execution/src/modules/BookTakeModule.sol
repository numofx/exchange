// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

// Inherited
import {BaseModule} from "./BaseModule.sol";
import {IBookTakeModule, IOnchainBookTake} from "../interfaces/IBookTakeModule.sol";
// Interfaces
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IMatching} from "../interfaces/IMatching.sol";

/**
 * @title BookTakeModule
 * @notice A signed take against risk-core's OnchainBook for an account Matching holds: the owner signs the take,
 *         Matching hands the account to this module for the call (which makes the module the account's owner, as
 *         OnchainBook.take requires of its caller), the module takes, and returns the account. The venue's executor
 *         submits it, so the taker sends no transaction and needs no gas.
 *
 *         The taker is always the action's own account: a signature can only trade the account it was made for.
 *         Only books the owner allows can be called, and allowing one approves it on SubAccounts for the accounts
 *         this module holds, which it holds only inside `executeAction`.
 */
contract BookTakeModule is IBookTakeModule, BaseModule {
  /// @dev OnchainBook.SelfTradeMode.Abort: a take that would cross the taker's own quote reverts
  uint8 internal constant SELF_TRADE_ABORT = 0;

  mapping(address book => bool) public allowedBooks;

  constructor(IMatching _matching) BaseModule(_matching) {}

  /// @notice Allow a book, and approve it on SubAccounts for the accounts this module holds during a take; or the reverse.
  function setBookAllowed(address book, bool allowed) external onlyOwner {
    allowedBooks[book] = allowed;
    subAccounts.setApprovalForAll(book, allowed);
    emit BookAllowed(book, allowed);
  }

  function executeAction(VerifiedAction[] memory actions, bytes memory)
    external
    onlyMatching
    returns (uint[] memory newAccIds, address[] memory newAccOwners)
  {
    if (actions.length != 1) revert BTM_InvalidActionLength();
    uint accountId = actions[0].subaccountId;
    if (accountId == 0) revert BTM_InvalidAccount();

    _checkAndInvalidateNonce(actions[0].owner, actions[0].nonce);

    BookTakeData memory data = abi.decode(actions[0].data, (BookTakeData));
    if (!allowedBooks[data.book]) revert BTM_BookNotAllowed();

    uint amount = data.amount;
    if (data.reduceOnly) amount = _reducing(data, accountId);

    IOnchainBookTake.TakeOrder memory order = IOnchainBookTake.TakeOrder({
      marketId: data.marketId,
      takerAccountId: accountId,
      isBuy: data.isBuy,
      amount: amount,
      limitPrice: data.limitPrice,
      minFill: data.minFill > amount ? amount : data.minFill,
      maxFee: data.maxFee,
      deadline: data.deadline,
      maxLevels: data.maxLevels,
      selfTradeMode: SELF_TRADE_ABORT,
      managerData: ""
    });
    (uint filled, uint avgPrice) = IOnchainBookTake(data.book).take(order, "");
    emit BookTake(accountId, data.book, data.marketId, data.isBuy, filled, avgPrice);

    _returnAccounts(actions, newAccIds);
    return (newAccIds, newAccOwners);
  }

  /// @dev The take cut to the position it reduces: a buy needs a short, a sell a long.
  function _reducing(BookTakeData memory data, uint accountId) internal view returns (uint) {
    IOnchainBookTake.MarketView memory m = IOnchainBookTake(data.book).markets(data.marketId);
    int position = subAccounts.getBalance(accountId, IAsset(m.future), m.subId);
    if (data.isBuy ? position >= 0 : position <= 0) revert BTM_NotReducing();
    uint size = uint(position < 0 ? -position : position);
    return data.amount < size ? data.amount : size;
  }
}
