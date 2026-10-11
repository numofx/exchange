// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IDatedFutureAsset} from "../interfaces/IDatedFutureAsset.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";

import {ManagerWhitelist} from "./utils/ManagerWhitelist.sol";
import {PositionTracking} from "./utils/PositionTracking.sol";

/**
 * @title DatedFutureAsset
 * @notice USDC/cNGN dated futures, cash settled in cNGN.
 * @dev Quoted in cNGN per USDC; one contract is `contractSize` USDC. Daily variation margin accrues in cNGN and is
 *      realised lazily: the manager calls settleAccountVM whenever an account is touched and moves the cNGN.
 *      Fills carry their price in `assetData`, so a position opened away from the mark starts accruing from the fill
 *      price rather than the mark.
 *
 *      The index is the cNGN spot feed the perp also reads (USDC per cNGN, published from the rate picker). It is not
 *      the mark: the future trades at a forward, away from spot by the NGN/USD carry. It does two jobs:
 *      - every daily mark must sit within `maxMarkIndexDeviation` of it;
 *      - it fixes the settlement price. Anyone may record index samples during the `fixingWindow` before expiry, and
 *        after expiry anyone may fix the price to their time-weighted average. The owner may set the price by hand
 *        only if that fixing could not be made, and only `fallbackDelay` after expiry.
 */
contract DatedFutureAsset is IDatedFutureAsset, PositionTracking, ManagerWhitelist {
  using SafeCast for uint;

  /// @dev USDC (18dp) per contract.
  uint public immutable contractSize;

  /// @dev Largest move a single mark may make, as a fraction of the previous mark (18dp). 0 disables.
  uint public maxMarkDeviation;

  /// @dev Oldest markTime, in seconds before now, that a mark may carry. 0 disables.
  uint public maxMarkDelay;

  /// @dev cNGN spot, USDC per cNGN (18dp)
  ISpotFeed public indexFeed;

  /// @dev Largest distance a mark may sit from the index, as a fraction of the index (18dp). 0 disables.
  uint public maxMarkIndexDeviation;

  /// @dev Length of the fixing window that ends at expiry, in seconds
  uint public fixingWindow;

  /// @dev Longest stretch of the window, in seconds, that may pass without a sample
  uint public maxSampleGap;

  /// @dev Time after expiry before the owner may set the settlement price by hand, in seconds
  uint public fallbackDelay;

  mapping(uint subId => Fixing) internal _fixings;

  /// @dev The manual fallback must sit within this of its reference: the fixing samples' TWAP, else the last index.
  uint public constant FALLBACK_BAND = 0.02e18;

  /// @dev The last index this contract read (cNGN per USDC), and when. Stored by every mark and fixing sample, so the
  ///      fallback has a reference even when the feed has gone stale.
  uint public lastIndexPrice;
  uint64 public lastIndexTime;

  mapping(uint subId => FutureContract) internal _futureContracts;

  /// @dev accountId => subId => cumulative VM per contract at which the account is checkpointed
  mapping(uint accountId => mapping(uint subId => int cumulative)) public accountLastCumulativeVM;

  /// @dev accountId => subId => cNGN realised but not yet moved by the manager
  mapping(uint accountId => mapping(uint subId => int cngn)) public accountCngnToSettle;

  constructor(ISubAccounts _subAccounts, uint _contractSize) ManagerWhitelist(_subAccounts) {
    if (_contractSize == 0) revert DFA_InvalidSchedule();
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
    uint _fixingWindow,
    uint _maxSampleGap,
    uint _fallbackDelay
  ) external onlyOwner {
    if (
      address(_indexFeed) == address(0) || _maxMarkIndexDeviation > 1e18 || _fixingWindow == 0 || _maxSampleGap == 0
        || _maxSampleGap > _fixingWindow
    ) revert DFA_InvalidIndexParams();
    indexFeed = _indexFeed;
    maxMarkIndexDeviation = _maxMarkIndexDeviation;
    fixingWindow = _fixingWindow;
    maxSampleGap = _maxSampleGap;
    fallbackDelay = _fallbackDelay;
    emit IndexParamsSet(address(_indexFeed), _maxMarkIndexDeviation, _fixingWindow, _maxSampleGap, _fallbackDelay);
  }

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice)
    external
    onlyOwner
    returns (uint96 subId)
  {
    if (expiry <= block.timestamp || lastTradeTime >= expiry || initialMarkPrice == 0) {
      revert DFA_InvalidSchedule();
    }
    subId = getSubId(expiry);

    FutureContract storage market = _futureContracts[subId];
    if (market.listed) revert DFA_InvalidSchedule();

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

  function setDailyMark(uint96 subId, uint64 markTime, uint markPrice) external onlyOwner {
    if (markPrice == 0) revert DFA_InvalidMark();

    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert DFA_UnknownFuture();
    if (market.settled) revert DFA_AlreadySettled();
    if (markTime <= market.lastMarkTime || markTime > market.expiry || markTime > block.timestamp) {
      revert DFA_InvalidMark();
    }
    if (maxMarkDelay != 0 && uint(markTime) + maxMarkDelay < block.timestamp) revert DFA_StaleMark();

    uint oldMarkPrice = market.markPrice;
    _checkDeviation(oldMarkPrice, markPrice);
    _observeIndexAndCheckBand(markPrice);
    _accrue(market, markPrice);
    market.lastMarkTime = markTime;

    emit DailyMarkSet(subId, markTime, oldMarkPrice, markPrice, market.cumulativeVMPerContract);
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
    if (!market.listed) revert DFA_UnknownFuture();
    if (block.timestamp < uint(market.expiry) + fallbackDelay) revert DFA_NotExpired();
    if (settlementPrice == 0) revert DFA_InvalidMark();
    if (_fixingComplete(market, _fixings[subId])) revert DFA_FixingAvailable();

    uint reference_ = fallbackReference(subId);
    uint diff = settlementPrice > reference_ ? settlementPrice - reference_ : reference_ - settlementPrice;
    if (diff * 1e18 > reference_ * FALLBACK_BAND) revert DFA_FallbackOutsideBand();

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
      if (lastIndexTime == 0) revert DFA_NoSettlementReference();
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
    if (!market.listed) revert DFA_UnknownFuture();
    if (market.settled) revert DFA_AlreadySettled();

    Fixing storage fixing = _fixings[subId];
    uint64 windowStart = fixing.firstSampleTime == 0 ? _windowStart(market) : fixing.windowStart;
    if (block.timestamp < windowStart || block.timestamp > market.expiry) revert DFA_OutsideFixingWindow();

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
    if (!market.listed) revert DFA_UnknownFuture();
    if (block.timestamp < market.expiry) revert DFA_NotExpired();

    Fixing storage fixing = _fixings[subId];
    if (!_fixingComplete(market, fixing)) revert DFA_FixingIncomplete();

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
    if (market.settled) revert DFA_AlreadySettled();
    _accrue(market, settlementPrice);
    market.lastMarkTime = uint64(block.timestamp);
    market.settled = true;

    emit SettlementPriceSet(subId, settlementPrice, market.cumulativeVMPerContract, fromIndex);
  }

  function _windowStart(FutureContract storage market) internal view returns (uint64) {
    if (address(indexFeed) == address(0)) revert DFA_InvalidIndexParams();
    return market.expiry - fixingWindow.toUint64();
  }

  /// @dev The index in this contract's units: cNGN per USDC. The feed is USDC per cNGN, and reverts when stale.
  function _indexPrice() internal view returns (uint) {
    (uint spot,) = indexFeed.getSpot();
    if (spot == 0) revert DFA_InvalidMark();
    return 1e36 / spot;
  }

  /// @dev Read the index and keep it as the last valid one.
  function _observeIndex() internal returns (uint price) {
    price = _indexPrice();
    lastIndexPrice = price;
    lastIndexTime = uint64(block.timestamp);
  }

  function _observeIndexAndCheckBand(uint markPrice) internal {
    if (address(indexFeed) == address(0)) return;
    uint index = _observeIndex();
    if (maxMarkIndexDeviation == 0) return;
    uint diff = markPrice > index ? markPrice - index : index - markPrice;
    if (diff * 1e18 > index * maxMarkIndexDeviation) revert DFA_MarkOutsideIndexBand();
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
    if (!market.listed) revert DFA_UnknownFuture();
    if (uint96(adjustment.subId) != getSubId(market.expiry)) revert DFA_InvalidSubId();

    _checkManager(address(manager));

    // After last trade only the manager moves positions: liquidations, and the close-out after settlement.
    if (block.timestamp >= market.lastTradeTime && adjustment.amount != 0 && caller != address(manager)) {
      revert DFA_TradingClosed();
    }

    _takeTotalPositionSnapshotPreTrade(manager, tradeId);
    _updateTotalPositions(manager, preBalance, adjustment.amount);

    _synchronizeVM(adjustment.acc, adjustment.subId, preBalance);

    finalBalance = preBalance + adjustment.amount;

    _blendVM(adjustment.acc, adjustment.subId, preBalance, finalBalance, uint(adjustment.assetData));

    // always require allowance for transfer-like adjustments
    return (finalBalance, true);
  }

  //////////////////////////
  //     Settlement       //
  //////////////////////////

  function settleAccountVM(uint accountId, uint subId) external returns (int cngnDelta) {
    if (msg.sender != address(subAccounts.manager(accountId))) revert DFA_NotManager();

    int position = subAccounts.getBalance(accountId, this, subId);
    _synchronizeVM(accountId, subId, position);

    cngnDelta = accountCngnToSettle[accountId][subId];
    accountCngnToSettle[accountId][subId] = 0;
  }

  function getPendingVM(uint accountId, uint subId) external view returns (int cngnDelta) {
    cngnDelta = accountCngnToSettle[accountId][subId];
    int position = subAccounts.getBalance(accountId, this, subId);
    if (position == 0) return cngnDelta;
    int diff = _futureContracts[subId].cumulativeVMPerContract - accountLastCumulativeVM[accountId][subId];
    cngnDelta += position * diff / 1e18;
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

    int cngnDelta = position * diff / 1e18;
    if (cngnDelta != 0) {
      accountCngnToSettle[accountId][subId] += cngnDelta;
    }

    emit FutureVMSynchronized(accountId, uint96(subId), cngnDelta, latest);
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
      accountCngnToSettle[acc][subId] += amount * (latest - entryVM) / 1e18;
    } else {
      // closing, or flipping through zero: the old position realises at the fill, any new one enters at it
      accountCngnToSettle[acc][subId] += -preBalance * (latest - entryVM) / 1e18;
      accountLastCumulativeVM[acc][subId] = entryVM;
    }
  }

  function _checkDeviation(uint oldPrice, uint newPrice) internal view {
    if (maxMarkDeviation == 0) return;
    uint diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
    if (diff * 1e18 > oldPrice * maxMarkDeviation) revert DFA_MarkDeviationExceeded();
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
