// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../interfaces/IForwardFeed.sol";

import {ManagerWhitelist} from "./utils/ManagerWhitelist.sol";
import {PositionTracking} from "./utils/PositionTracking.sol";

/**
 * @title FutureAsset
 * @notice cNGN dated futures in American terms (cNGN-<expiry>), cash settled in USDC.
 * @dev Quoted in USDC per cNGN; one contract is `contractSize` cNGN. Variation margin is linear in the price: a long
 *      gains (newMark - oldMark) x contractSize USDC per contract as cNGN strengthens. It is realised lazily: the
 *      manager calls settleAccountVM whenever an account is touched and moves the cash.
 *
 *      v2. The v1 series (USDC-cNGN-<expiry>, cNGN per USDC, a USDC contract, VM in cNGN) is src/legacy/v1/FutureAssetV1.
 *      Fills carry their price in `assetData`, so a position opened away from the mark starts accruing from the fill
 *      price rather than the mark.
 *
 *      Marks come from the forward feed: anyone may pullMark, at most every `minMarkInterval`, until last trade. The
 *      owner's setMark is the fallback when the feed cannot be used. Both are held to the same limits.
 *
 *      The index is the cNGN spot feed (USDC per cNGN, published from the rate picker), read as is. It is not
 *      the mark: the future trades at a forward, away from spot by the NGN/USD carry. It does two jobs:
 *      - every mark must sit within markIndexBand of it: maxMarkIndexDeviation, narrowing to minMarkIndexDeviation
 *        over the last bandNarrowingPeriod before expiry;
 *      - it fixes the settlement price. Anyone may record index samples during the `fixingWindow` before expiry, and
 *        after expiry anyone may fix the price to their time-weighted average. The owner may set the price by hand
 *        only if that fixing could not be made, only `fallbackDelay` after expiry, and only within FALLBACK_BAND.
 */
contract FutureAsset is IFutureAsset, PositionTracking, ManagerWhitelist {
  using SafeCast for uint;

  /// @dev cNGN (18dp) per contract.
  uint public immutable contractSize;

  /// @dev Largest move a single mark may make, as a fraction of the previous mark (18dp). 0 disables.
  uint public maxMarkDeviation;

  /// @dev Oldest markTime, in seconds before now, that a mark may carry. 0 disables.
  uint public maxMarkDelay;

  /// @dev cNGN spot, USDC per cNGN (18dp)
  ISpotFeed public indexFeed;

  /// @dev Largest distance a mark may sit from the index, as a fraction of the index (18dp). 0 disables.
  uint public maxMarkIndexDeviation;

  /// @dev The band at expiry. Over the last `bandNarrowingPeriod` it narrows linearly from maxMarkIndexDeviation to
  ///      this, as the forward converges on the index the fixing settles to.
  uint public minMarkIndexDeviation;

  /// @dev Seconds before expiry over which the band narrows. 0 keeps it at maxMarkIndexDeviation throughout.
  uint public bandNarrowingPeriod;

  /// @dev Signed forward per expiry (USDC per cNGN): the index plus a published forward difference. pullMark reads it.
  IForwardFeed public forwardFeed;

  /// @dev Fewest seconds between marks, so repeated pulls cannot walk the mark past maxMarkDeviation a step at a time.
  uint public minMarkInterval;

  /// @dev Length of the fixing window that ends at expiry, in seconds
  uint public fixingWindow;

  /// @dev Longest stretch of the window, in seconds, that may pass without a sample
  uint public maxSampleGap;

  /// @dev Time after expiry before the owner may set the settlement price by hand, in seconds
  uint public fallbackDelay;

  mapping(uint subId => Fixing) internal _fixings;

  /// @dev The manual fallback must sit within this of its reference: the fixing samples' TWAP, else the last index.
  uint public constant FALLBACK_BAND = 0.02e18;

  /// @dev The last index this contract read (USDC per cNGN), and when. Stored by every mark and fixing sample, so the
  ///      fallback has a reference even when the feed has gone stale.
  uint public lastIndexPrice;
  uint64 public lastIndexTime;

  mapping(uint subId => FutureContract) internal _futureContracts;

  /// @dev accountId => subId => cumulative VM per contract at which the account is checkpointed
  mapping(uint accountId => mapping(uint subId => int cumulative)) public accountLastCumulativeVM;

  /// @dev accountId => subId => USDC realised but not yet moved by the manager
  mapping(uint accountId => mapping(uint subId => int cash)) public accountCashToSettle;

  constructor(ISubAccounts _subAccounts, uint _contractSize) ManagerWhitelist(_subAccounts) {
    if (_contractSize == 0) revert FA_InvalidSchedule();
    contractSize = _contractSize;
  }

  //////////////////////////
  //      Owner-only      //
  //////////////////////////

  function setMarkBounds(uint _maxMarkDeviation, uint _maxMarkDelay) external onlyOwner {
    maxMarkDeviation = _maxMarkDeviation;
    maxMarkDelay = _maxMarkDelay;
    emit MarkBoundsSet(_maxMarkDeviation, _maxMarkDelay);
  }

  function setIndexParams(
    ISpotFeed _indexFeed,
    uint _maxMarkIndexDeviation,
    uint _minMarkIndexDeviation,
    uint _bandNarrowingPeriod,
    uint _fixingWindow,
    uint _maxSampleGap,
    uint _fallbackDelay
  ) external onlyOwner {
    if (
      address(_indexFeed) == address(0) || _maxMarkIndexDeviation > 1e18
        || _minMarkIndexDeviation > _maxMarkIndexDeviation || _fixingWindow == 0 || _maxSampleGap == 0
        || _maxSampleGap > _fixingWindow
    ) revert FA_InvalidIndexParams();
    indexFeed = _indexFeed;
    maxMarkIndexDeviation = _maxMarkIndexDeviation;
    minMarkIndexDeviation = _minMarkIndexDeviation;
    bandNarrowingPeriod = _bandNarrowingPeriod;
    fixingWindow = _fixingWindow;
    maxSampleGap = _maxSampleGap;
    fallbackDelay = _fallbackDelay;
    emit IndexParamsSet(
      address(_indexFeed),
      _maxMarkIndexDeviation,
      _minMarkIndexDeviation,
      _bandNarrowingPeriod,
      _fixingWindow,
      _maxSampleGap,
      _fallbackDelay
    );
  }

  function setForwardFeed(IForwardFeed _forwardFeed, uint _minMarkInterval) external onlyOwner {
    forwardFeed = _forwardFeed;
    minMarkInterval = _minMarkInterval;
    emit ForwardFeedSet(address(_forwardFeed), _minMarkInterval);
  }

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice)
    external
    onlyOwner
    returns (uint96 subId)
  {
    if (expiry <= block.timestamp || lastTradeTime >= expiry || initialMarkPrice == 0) {
      revert FA_InvalidSchedule();
    }
    subId = getSubId(expiry);

    FutureContract storage market = _futureContracts[subId];
    if (market.listed) revert FA_InvalidSchedule();

    _futureContracts[subId] = FutureContract({
      listed: true,
      settled: false,
      expiry: expiry,
      lastTradeTime: lastTradeTime,
      lastMarkTime: uint64(block.timestamp),
      markPrice: initialMarkPrice,
      cumulativeVMPerContract: 0
    });

    emit FutureContractSet(subId, expiry, lastTradeTime, initialMarkPrice);
  }

  /**
   * @notice Mark from the forward feed. Anyone may call, at most every `minMarkInterval`, until last trade.
   * @dev    The feed is USDC per cNGN, as the mark is. Held to the same move limit and index band as an owner
   *         mark, so a bad forward print is bounded by the index, which comes from a separate signer.
   */
  function pullMark(uint96 subId) external {
    if (address(forwardFeed) == address(0)) revert FA_NoForwardFeed();
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp >= market.lastTradeTime) revert FA_MarkingClosed();
    if (block.timestamp < uint(market.lastMarkTime) + minMarkInterval) revert FA_MarkTooSoon();

    (uint forward,) = forwardFeed.getForwardPrice(market.expiry);
    if (forward == 0) revert FA_InvalidMark();
    _applyMark(subId, market, uint64(block.timestamp), forward, true);
  }

  /// @notice The owner's mark, for when the forward feed cannot be used. Same checks as pullMark.
  function setMark(uint96 subId, uint64 markTime, uint markPrice) external onlyOwner {
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (markTime > block.timestamp) revert FA_InvalidMark();
    if (maxMarkDelay != 0 && uint(markTime) + maxMarkDelay < block.timestamp) revert FA_StaleMark();
    _applyMark(subId, market, markTime, markPrice, false);
  }

  function _applyMark(uint96 subId, FutureContract storage market, uint64 markTime, uint markPrice, bool fromFeed)
    internal
  {
    if (markPrice == 0) revert FA_InvalidMark();
    if (market.settled) revert FA_AlreadySettled();
    if (markTime <= market.lastMarkTime || markTime > market.expiry) revert FA_InvalidMark();

    uint oldMarkPrice = market.markPrice;
    _checkDeviation(oldMarkPrice, markPrice);
    _observeIndexAndCheckBand(markPrice, market.expiry);
    _accrue(market, markPrice);
    market.lastMarkTime = markTime;

    emit MarkSet(subId, markTime, oldMarkPrice, markPrice, market.cumulativeVMPerContract, fromFeed);
  }

  /**
   * @notice Fallback for when the index fixing could not be made: the owner sets the settlement price by hand, no
   *         sooner than `fallbackDelay` after expiry, never over a complete fixing, and within FALLBACK_BAND of
   *         fallbackReference: the TWAP of whatever fixing samples were recorded, or with none, the last index read.
   * @dev    Not held to the mark deviation bound, for the reason fixSettlementFromIndex is not: the reference bound is
   *         the one that matters, and a mark that drifted from the index must not be able to block settlement.
   */
  function setSettlementPrice(uint96 subId, uint settlementPrice) external onlyOwner {
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp < uint(market.expiry) + fallbackDelay) revert FA_NotExpired();
    if (settlementPrice == 0) revert FA_InvalidMark();
    if (_fixingComplete(market, _fixings[subId])) revert FA_FixingAvailable();

    uint reference_ = fallbackReference(subId);
    uint diff = settlementPrice > reference_ ? settlementPrice - reference_ : reference_ - settlementPrice;
    if (diff * 1e18 > reference_ * FALLBACK_BAND) revert FA_FallbackOutsideBand();

    _settle(subId, market, settlementPrice, false);
  }

  /**
   * @notice The price the manual fallback is bounded against. With fixing samples, their TWAP: each sample holds until
   *         the next, and the last for at most the window's gap limit (and not past expiry), so an index that went stale
   *         early is not carried forward as if it had held. With no samples, the last index this contract read.
   */
  function fallbackReference(uint96 subId) public view returns (uint) {
    Fixing storage fixing = _fixings[subId];
    if (fixing.firstSampleTime == 0) {
      if (lastIndexTime == 0) revert FA_NoSettlementReference();
      return lastIndexPrice;
    }
    uint64 expiry = _futureContracts[subId].expiry;
    uint64 end = fixing.lastSampleTime + fixing.maxSampleGap;
    if (end > expiry) end = expiry;
    uint duration = end - fixing.firstSampleTime;
    if (duration == 0) return fixing.lastPrice;
    return (fixing.accumulator + fixing.lastPrice * (end - fixing.lastSampleTime)) / duration;
  }

  //////////////////////////
  //       Fixing         //
  //////////////////////////

  /**
   * @notice Record the index for the settlement fixing. Anyone may call, any time in the window ending at expiry.
   * @dev    Each sample holds until the next, so the fixing is the time-weighted average of the index as sampled. The
   *         window and gap limit are fixed by the first sample, so a parameter change cannot move a window under way.
   */
  function recordFixingSample(uint96 subId) external {
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (market.settled) revert FA_AlreadySettled();

    Fixing storage fixing = _fixings[subId];
    uint64 windowStart = fixing.firstSampleTime == 0 ? _windowStart(market) : fixing.windowStart;
    if (block.timestamp < windowStart || block.timestamp > market.expiry) revert FA_OutsideFixingWindow();

    uint price = _observeIndex();
    uint64 now_ = uint64(block.timestamp);

    if (fixing.firstSampleTime == 0) {
      fixing.windowStart = windowStart;
      fixing.maxSampleGap = maxSampleGap.toUint64();
      fixing.firstSampleTime = now_;
      fixing.largestGap = now_ - windowStart;
    } else {
      uint64 gap = now_ - fixing.lastSampleTime;
      fixing.accumulator += fixing.lastPrice * gap;
      if (gap > fixing.largestGap) fixing.largestGap = gap;
    }
    fixing.lastSampleTime = now_;
    fixing.lastPrice = price;

    emit FixingSampled(subId, now_, price);
  }

  /**
   * @notice After expiry, fix the settlement price to the time-weighted index over the window. Anyone may call.
   * @dev    Refused if the window was not sampled to within `maxSampleGap` at every point, start to expiry. Not held to
   *         the mark deviation bound: the index is what the contract converges to, and a mark that drifted from it
   *         must not be able to block settlement.
   */
  function fixSettlementFromIndex(uint96 subId) external {
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp < market.expiry) revert FA_NotExpired();

    Fixing storage fixing = _fixings[subId];
    if (!_fixingComplete(market, fixing)) revert FA_FixingIncomplete();

    uint64 closingGap = market.expiry - fixing.lastSampleTime;
    uint duration = market.expiry - fixing.firstSampleTime;
    uint accumulator = fixing.accumulator + fixing.lastPrice * closingGap;
    uint settlementPrice = duration == 0 ? fixing.lastPrice : accumulator / duration;

    _settle(subId, market, settlementPrice, true);
  }

  /// @dev Sampled from the window's start to expiry with no gap over the limit.
  function _fixingComplete(FutureContract storage market, Fixing storage fixing) internal view returns (bool) {
    if (fixing.firstSampleTime == 0) return false;
    uint64 closingGap = market.expiry - fixing.lastSampleTime;
    uint64 largest = closingGap > fixing.largestGap ? closingGap : fixing.largestGap;
    return largest <= fixing.maxSampleGap;
  }

  function _settle(uint96 subId, FutureContract storage market, uint settlementPrice, bool fromIndex) internal {
    if (market.settled) revert FA_AlreadySettled();
    _accrue(market, settlementPrice);
    market.lastMarkTime = uint64(block.timestamp);
    market.settled = true;

    emit SettlementPriceSet(subId, settlementPrice, market.cumulativeVMPerContract, fromIndex);
  }

  function _windowStart(FutureContract storage market) internal view returns (uint64) {
    if (address(indexFeed) == address(0)) revert FA_InvalidIndexParams();
    return market.expiry - fixingWindow.toUint64();
  }

  /// @dev The index, USDC per cNGN: the feed's own units, which are this contract's. The feed reverts when stale.
  function _indexPrice() internal view returns (uint spot) {
    (spot,) = indexFeed.getSpot();
    if (spot == 0) revert FA_InvalidMark();
  }

  /// @dev Read the index and keep it as the last valid one.
  function _observeIndex() internal returns (uint price) {
    price = _indexPrice();
    lastIndexPrice = price;
    lastIndexTime = uint64(block.timestamp);
  }

  function _observeIndexAndCheckBand(uint markPrice, uint64 expiry) internal {
    if (address(indexFeed) == address(0)) return;
    uint index = _observeIndex();
    uint band = markIndexBand(expiry);
    if (band == 0) return;
    uint diff = markPrice > index ? markPrice - index : index - markPrice;
    if (diff * 1e18 > index * band) revert FA_MarkOutsideIndexBand();
  }

  /// @dev The same test marks pass (_observeIndexAndCheckBand), without recording the index: no band, no check.
  function _checkFillInsideIndexBand(uint fillPrice, uint64 expiry) internal view {
    if (address(indexFeed) == address(0)) return;
    uint band = markIndexBand(expiry);
    if (band == 0) return;
    uint index = _indexPrice();
    uint diff = fillPrice > index ? fillPrice - index : index - fillPrice;
    if (diff * 1e18 > index * band) revert FA_FillOutsideIndexBand();
  }

  /// @notice The band a mark must sit within of the index now, for a contract expiring at `expiry`.
  function markIndexBand(uint64 expiry) public view returns (uint) {
    uint maxBand = maxMarkIndexDeviation;
    if (bandNarrowingPeriod == 0 || block.timestamp + bandNarrowingPeriod <= expiry) return maxBand;
    if (block.timestamp >= expiry) return minMarkIndexDeviation;
    uint remaining = expiry - block.timestamp;
    return minMarkIndexDeviation + (maxBand - minMarkIndexDeviation) * remaining / bandNarrowingPeriod;
  }

  //////////////////////////
  //    Account Hooks     //
  //////////////////////////

  function handleAdjustment(
    ISubAccounts.AssetAdjustment memory adjustment,
    uint tradeId,
    int preBalance,
    IManager manager,
    address caller
  ) external onlyAccounts returns (int finalBalance, bool needAllowance) {
    FutureContract storage market = _futureContracts[adjustment.subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (uint96(adjustment.subId) != getSubId(market.expiry)) revert FA_InvalidSubId();

    _checkManager(address(manager));

    // After last trade only the manager moves positions: liquidations, and the close-out after settlement.
    if (block.timestamp >= market.lastTradeTime && adjustment.amount != 0 && caller != address(manager)) {
      revert FA_TradingClosed();
    }

    _takeTotalPositionSnapshotPreTrade(manager, tradeId);
    _updateTotalPositions(manager, preBalance, adjustment.amount);

    _synchronizeVM(adjustment.acc, adjustment.subId, preBalance);

    finalBalance = preBalance + adjustment.amount;

    // A fill carries its price, and VM is realised at it at once: bound it by the band a mark must sit in, so two
    // accounts cannot move value between them at an arbitrary price. Transfers with no price (liquidation, close-out)
    // move at the mark and are not checked.
    if (adjustment.assetData != bytes32(0) && adjustment.amount != 0) {
      _checkFillInsideIndexBand(uint(adjustment.assetData), market.expiry);
    }
    _blendVM(adjustment.acc, adjustment.subId, preBalance, finalBalance, uint(adjustment.assetData));

    // always require allowance for transfer-like adjustments
    return (finalBalance, true);
  }

  //////////////////////////
  //     Settlement       //
  //////////////////////////

  function settleAccountVM(uint accountId, uint subId) external returns (int vmDelta) {
    if (msg.sender != address(subAccounts.manager(accountId))) revert FA_NotManager();

    int position = subAccounts.getBalance(accountId, this, subId);
    _synchronizeVM(accountId, subId, position);

    vmDelta = accountCashToSettle[accountId][subId];
    accountCashToSettle[accountId][subId] = 0;
  }

  function getPendingVM(uint accountId, uint subId) external view returns (int vmDelta) {
    vmDelta = accountCashToSettle[accountId][subId];
    int position = subAccounts.getBalance(accountId, this, subId);
    if (position == 0) return vmDelta;
    int diff = _futureContracts[subId].cumulativeVMPerContract - accountLastCumulativeVM[accountId][subId];
    vmDelta += position * diff / 1e18;
  }

  function _accrue(FutureContract storage market, uint newPrice) internal {
    int delta = newPrice.toInt256() - market.markPrice.toInt256();
    market.cumulativeVMPerContract += delta * contractSize.toInt256() / 1e18;
    market.markPrice = newPrice;
  }

  function _synchronizeVM(uint accountId, uint subId, int position) internal {
    int latest = _futureContracts[subId].cumulativeVMPerContract;
    int diff = latest - accountLastCumulativeVM[accountId][subId];
    if (diff == 0) return;

    accountLastCumulativeVM[accountId][subId] = latest;

    int vmDelta = position * diff / 1e18;
    if (vmDelta != 0) {
      accountCashToSettle[accountId][subId] += vmDelta;
    }

    emit FutureVMSynchronized(accountId, uint96(subId), vmDelta, latest);
  }

  /**
   * @dev Re-checkpoint an account whose position changed at `tradePrice`, so its VM runs from the fill price rather
   *      than the mark. `entryVM` is the cumulative VM the contract would show if it were marked at the fill price.
   *      Transfers that carry no price (tradePrice == 0) move the position at the mark.
   */
  function _blendVM(uint acc, uint subId, int preBalance, int finalBalance, uint tradePrice) internal {
    int amount = finalBalance - preBalance;
    if (tradePrice == 0 || amount == 0) return;

    FutureContract storage market = _futureContracts[subId];
    int latest = market.cumulativeVMPerContract;
    int entryVM = latest + (tradePrice.toInt256() - market.markPrice.toInt256()) * contractSize.toInt256() / 1e18;

    if (preBalance == 0) {
      accountLastCumulativeVM[acc][subId] = entryVM;
      return;
    }

    bool sameSign = (preBalance > 0) == (finalBalance > 0) && finalBalance != 0;
    if (sameSign && SignedMath.abs(finalBalance) > SignedMath.abs(preBalance)) {
      // adding: weighted-average entry
      accountLastCumulativeVM[acc][subId] = (preBalance * latest + amount * entryVM) / finalBalance;
    } else if (sameSign) {
      // reducing: the closed part realises (mark -> fill) now, the rest stays at the mark
      accountCashToSettle[acc][subId] += amount * (latest - entryVM) / 1e18;
    } else {
      // closing, or flipping through zero: the old position realises at the fill, any new one enters at it
      accountCashToSettle[acc][subId] += -preBalance * (latest - entryVM) / 1e18;
      accountLastCumulativeVM[acc][subId] = entryVM;
    }
  }

  function _checkDeviation(uint oldPrice, uint newPrice) internal view {
    if (maxMarkDeviation == 0) return;
    uint diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
    if (diff * 1e18 > oldPrice * maxMarkDeviation) revert FA_MarkDeviationExceeded();
  }

  //////////////////////////
  //         View         //
  //////////////////////////

  function getReferencePrice(uint subId) external view returns (uint price, bool isSet) {
    FutureContract memory market = _futureContracts[subId];
    if (!market.listed) return (0, false);
    return (market.markPrice, true);
  }

  function futureContracts(uint subId) external view returns (FutureContract memory) {
    return _futureContracts[subId];
  }

  function fixings(uint subId) external view returns (Fixing memory) {
    return _fixings[subId];
  }

  function getSubId(uint64 expiry) public pure returns (uint96) {
    return uint96(expiry);
  }

  function parseSubId(uint96 subId) external pure returns (uint64 expiry) {
    return uint64(subId);
  }
}
