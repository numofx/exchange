// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {IBaseModule} from "./IBaseModule.sol";

/**
 * @notice risk-core's OnchainBook, as BookTakeModule calls it. `TakeOrder` and the `markets` getter mirror
 *         risk-core/src/periphery/OnchainBook.sol field for field: both ABI-encode identically.
 */
interface IOnchainBookTake {
  struct TakeOrder {
    uint marketId;
    uint takerAccountId;
    bool isBuy;
    uint amount;
    uint limitPrice;
    uint minFill;
    uint maxFee;
    uint64 deadline;
    uint16 maxLevels;
    uint8 selfTradeMode;
    bytes managerData;
  }

  function take(TakeOrder calldata o, bytes calldata optionalReport) external returns (uint filled, uint avgPrice);

  /// @dev Every field is static, so this one struct decodes the getter's thirteen return values as they are encoded.
  struct MarketView {
    address future;
    address engine;
    uint96 subId;
    uint64 expiry;
    uint64 lastTradeTime;
    address adapter;
    uint tickSize;
    uint lotSize;
    uint takerFeeRate;
    uint32 takeMaxAge;
    uint32 maxTtl;
    uint16 maxMakers;
    bool enabled;
  }

  function markets(uint marketId) external view returns (MarketView memory);
}

interface IBookTakeModule is IBaseModule {
  /// @dev What the account's owner signs as the action's `data`. The taker is always the action's own account.
  struct BookTakeData {
    address book;
    uint marketId;
    bool isBuy;
    /// @dev position units (1e18 a contract), rounded down to the book's lots
    uint amount;
    /// @dev worst price, quote per base, 18 dp
    uint limitPrice;
    /// @dev the take reverts below this fill, position units
    uint minFill;
    /// @dev the most the take may charge, cash 18 dp
    uint maxFee;
    uint64 deadline;
    uint16 maxLevels;
    /// @dev only reduce the position: the take must oppose it, and is cut to its size
    bool reduceOnly;
  }

  event BookAllowed(address indexed book, bool allowed);
  event BookTake(
    uint indexed accountId, address indexed book, uint indexed marketId, bool isBuy, uint filled, uint avgPrice
  );

  error BTM_InvalidActionLength();
  error BTM_InvalidAccount();
  error BTM_BookNotAllowed();
  error BTM_NotReducing();
}
