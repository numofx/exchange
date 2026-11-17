// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title IOnchainBook
 * @notice What another contract needs to price and take against an OnchainBook (spec C4.4), with no import of the book
 *         itself. Guide: docs/onchain-book-integration.md. Selectors, events and errors are asserted equal to the
 *         contract's (test/periphery/OnchainBookKit.t.sol).
 *
 *         Units: positions in the future's units (18 dp; 1e18 = one contract), rounded down to whole lots; prices are
 *         quote per base, 18 dp; cash (fees, margin) 18 dp.
 */
interface IOnchainBook {
  enum SelfTradeMode {
    /// @dev revert the whole take on crossing a maker the taker's owner also owns
    Abort,
    /// @dev skip that maker for the rest of the take
    DecrementTake
  }

  struct TakeOrder {
    uint marketId;
    /// @dev the account that takes; the caller must be its owner or the owner's operator. 0 in `quote`: no account.
    uint takerAccountId;
    bool isBuy;
    /// @dev position units; rounded down to whole lots
    uint amount;
    /// @dev worst acceptable price, 18 dp
    uint limitPrice;
    /// @dev revert unless at least this is filled, position units
    uint minFill;
    /// @dev taker fee plus priority-fee tax, cash 18 dp; revert if exceeded
    uint maxFee;
    /// @dev revert after this timestamp
    uint64 deadline;
    /// @dev at most this many price levels filled
    uint16 maxLevels;
    SelfTradeMode selfTradeMode;
    /// @dev passed to the margin engine with each settlement; empty for the MarginEngine
    bytes managerData;
  }

  struct MarketView {
    /// @dev the FutureAsset (IFutureAssetV3) and the series' subId
    address future;
    /// @dev the margin engine every taker and maker account must be under
    address engine;
    uint96 subId;
    uint64 expiry;
    /// @dev no take at or after this time
    uint64 lastTradeTime;
    /// @dev the StreamsIndexAdapter whose reports price pegged quotes and the band
    address adapter;
    /// @dev price per tick, 18 dp
    uint tickSize;
    /// @dev position units per lot
    uint lotSize;
    /// @dev taker fee as a fraction of notional, 18 dp
    uint takerFeeRate;
    /// @dev pegged quotes need both stored reports at most this old
    uint32 takeMaxAge;
    uint32 maxTtl;
    uint16 maxMakers;
    bool enabled;
  }

  /// @dev A maker's spline as `splines()` returns it (v1's getter layout). Self-priced: `offsetTicks` is the mid.
  struct SplineView {
    int32 offsetTicks;
    uint32 halfSpreadTicks;
    uint16 bidCurve;
    uint16 askCurve;
    uint32 skewTicksPerLot;
    uint32 maxSkewTicks;
    uint32 refillLotsPerSecond;
    uint40 updatedAt;
    uint32 ttl;
    uint64 seq;
    bool active;
    address owner;
  }

  /// @notice One maker's part of a take. `price` is that maker's average, `fee` the taker fee on it.
  event Fill(
    uint indexed marketId,
    uint indexed takerAccountId,
    uint indexed makerAccountId,
    bool isBuy,
    uint amount,
    uint price,
    uint fee
  );
  /// @notice The whole take, once: what `take` returns, and the fee including the priority tax.
  event TakeExecuted(
    uint indexed marketId, uint indexed takerAccountId, bool isBuy, uint filled, uint avgPrice, uint fee
  );
  /// @notice A maker's settlement reverted and its lots went back to the take (the take continues without it).
  event MakerSkipped(uint indexed marketId, uint indexed accountId, bytes reason);

  error OB_InvalidMarket();
  error OB_MarketDisabled();
  error OB_TradingClosed();
  error OB_Expired();
  error OB_NotAuthorized();
  error OB_TakerAllowanceTooLow();
  error OB_FeeTooHigh();
  error OB_BelowMinFill();
  error OB_SelfTrade();
  error OB_GasFloor();

  /**
   * @notice Take against the market's makers, best price first. `optionalReport` is abi.encode(bytes[]) of Data Streams
   *         reports, posted before pricing; empty to use the stored ones.
   * @return filled position units
   * @return avgPrice 18 dp; 0 when nothing filled
   */
  function take(TakeOrder calldata o, bytes calldata optionalReport) external returns (uint filled, uint avgPrice);

  /**
   * @notice What `take(o, "")` would do now if every settlement succeeds, with the same reverts. Reads stored reports.
   *         The priority tax is read at the call's gas price.
   * @return filled position units
   * @return avgPrice 18 dp
   * @return fee taker fee plus priority tax, cash 18 dp
   * @return makerCount makers that would settle: ~610k gas each
   */
  function quote(TakeOrder calldata o) external view returns (uint filled, uint avgPrice, uint fee, uint makerCount);

  /// @dev The contract's `markets` getter returns these 13 static words; declared as a struct here because destructuring
  ///      13 return values is too deep for the legacy (non-IR) pipeline. Same selector, same bytes.
  function markets(uint marketId) external view returns (MarketView memory);

  function makers(uint marketId) external view returns (uint[] memory);
  function splines(uint marketId, uint accountId) external view returns (SplineView memory);
  function isSelfPriced(uint marketId, uint accountId) external view returns (bool);
  function maxSelfPricedTtl(uint marketId) external view returns (uint32);
  /// @notice Cash charged per unit of priority fee (gas price over base fee) on a take that fills; 0: off.
  function priorityTaxRate() external view returns (uint);
  function subAccounts() external view returns (address);
  function cash() external view returns (address);
}
