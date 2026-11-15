// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../interfaces/IFutureAssetV3.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../interfaces/IForwardFeed.sol";

import {ManagerWhitelist} from "./utils/ManagerWhitelist.sol";
import {PositionTracking} from "./utils/PositionTracking.sol";

/**
 * @title FutureAsset
 * @notice Dated futures in American terms (<BASE>-<expiry>), cash settled in the engine's cash, settled only from the
 *         index. v3. The deployed v2 (cNGN-30NOV26, the retired EURC-30NOV26) is src/legacy/v2/FutureAssetV2; v1 is
 *         src/legacy/v1/FutureAssetV1. Spec: docs/eurc-usdc-futures-spec.md, A8.
 * @dev    Quoted in USDC per unit of the base; one contract is `contractSize` of the base. VM is linear in the price and
 *         realised lazily: the manager calls settleAccountVM whenever an account is touched. VM accounting, fills and
 *         handleAdjustment are v2's, unchanged.
 *
 *         What v3 changes, and why:
 *         - No owner settlement price. v2's setSettlementPrice and its FALLBACK_BAND are gone. A fixing that cannot
 *           complete is recovered by a later window (below), never by a chosen number.
 *         - Recovery windows. The original window ends at expiry. If it was not sampled to within `maxSampleGap`
 *           throughout, anyone may open a recovery window `recoveryDelay` later, of the same length; its samples
 *           replace the broken window's, never mix with them. If it breaks too, the next opens. The series settles once
 *           the index and the chain work for one full window.
 *         - The index feed cannot be swapped under a fixing. A change is proposed, waits the immutable `feedTimelock`,
 *           and is then activated by anyone; the history of feeds and the times they took effect is kept. Every window
 *           samples the feed that was in effect at its start, so a change reaches only windows that start after it.
 *           In v2, `setIndexParams` replaced the feed at once and the fixing read it live: an owner could have chosen
 *           the settlement price by pointing the index at any contract mid-window.
 *         - Marks run until the series settles, not only until last trade: margin follows the price through a
 *           recovery. From last trade on, the mark is the index, read from the current feed; before it, the forward
 *           feed, as in v2. A stale index stops marks, fills and samples alike.
 *         - Owner levers on the fixing are closed (independent review, 2026-11-15; spec A8.8): a series keeps the
 *           fixing parameters it was listed with; after last trade a feed change only replaces a dead feed, and a
 *           proposal lapses; the owner's mark obeys the same interval as anyone's.
 */
contract FutureAsset is IFutureAssetV3, PositionTracking, ManagerWhitelist {
  using SafeCast for uint;

  /// @dev Units of the base (18dp) per contract.
  uint public immutable contractSize;

  /// @dev Seconds a proposed index feed waits before it may be activated. Fixed at deploy, so it cannot be shortened.
  uint public immutable feedTimelock;

  /// @dev Largest move a single mark may make, as a fraction of the previous mark (18dp). 0 disables.
  uint public maxMarkDeviation;

  /// @dev Oldest markTime, in seconds before now, that an owner mark may carry. 0 disables.
  uint public maxMarkDelay;

  /// @dev Largest distance a mark or a priced fill may sit from the index, as a fraction of the index (18dp).
  uint public maxMarkIndexDeviation;

  /// @dev The band at expiry; it narrows linearly to this over the last `bandNarrowingPeriod`.
  uint public minMarkIndexDeviation;

  /// @dev Seconds before expiry over which the band narrows. 0 keeps it at maxMarkIndexDeviation throughout.
  uint public bandNarrowingPeriod;

  /// @dev The forward per expiry: the index plus a published forward difference. pullMark reads it before expiry.
  IForwardFeed public forwardFeed;

  /// @dev Fewest seconds between marks.
  uint public minMarkInterval;

  /// @dev Length of every fixing window, in seconds, for series listed from now on. A series keeps the fixing
  ///      parameters it was listed with (seriesFixing): a later setIndexParams cannot reshape its fixing.
  uint public fixingWindow;

  /// @dev Longest stretch of a window, in seconds, that may pass without a sample. For series listed from now on.
  uint public maxSampleGap;

  /// @dev Seconds between a broken window being found and its recovery window starting. For series listed from now on.
  uint public recoveryDelay;

  /// @dev The last time a mark, fill or sample read the current index feed and got a price. activateIndexFeed reads it
  ///      to tell a dead feed from a live one after last trade.
  uint64 public lastIndexReadAt;

  /// @dev A proposed index feed and when it may be activated. Zero when none is pending.
  address public pendingIndexFeed;
  uint64 public pendingIndexFeedEffectiveAt;

  FeedChange[] internal _feedHistory;

  mapping(uint subId => Fixing) internal _fixings;

  /// @dev Each series' fixing parameters, copied from the defaults when it is listed and never changed after.
  mapping(uint subId => FixingParams) internal _seriesFixing;

  /// @dev Every series ever listed, so activateIndexFeed can find those past last trade.
  uint96[] internal _series;

  /// @dev Bounds on the fixing parameters. No setting can stop a series settling (a recovery window always starts
  ///      within 6 hours, lasts at most a day, and tolerates a gap of at least a minute), and none can make a fixing
  ///      a handful of samples (a window is at least 15 minutes, and samples at least every quarter of it).
  uint public constant MAX_RECOVERY_DELAY = 6 hours;
  uint public constant MAX_FIXING_WINDOW = 1 days;
  uint public constant MIN_FIXING_WINDOW = 15 minutes;
  uint public constant MIN_SAMPLE_GAP = 1 minutes;
  /// @dev A window must be at least this many gap limits long.
  uint public constant MIN_GAPS_PER_WINDOW = 4;

  /// @dev How long a proposed feed stays activatable once its timelock has passed. After that it lapses, so a
  ///      proposal cannot be held in reserve and activated at a moment of the owner's choosing.
  uint public constant FEED_ACTIVATION_PERIOD = 2 days;

  mapping(uint subId => IFutureAsset.FutureContract) internal _futureContracts;

  /// @dev accountId => subId => cumulative VM per contract at which the account is checkpointed
  mapping(uint accountId => mapping(uint subId => int cumulative)) public accountLastCumulativeVM;

  /// @dev accountId => subId => cash realised but not yet moved by the manager
  mapping(uint accountId => mapping(uint subId => int cash)) public accountCashToSettle;

  constructor(ISubAccounts _subAccounts, uint _contractSize, ISpotFeed _indexFeed, uint _feedTimelock)
    ManagerWhitelist(_subAccounts)
  {
    if (_contractSize == 0) revert FA_InvalidSchedule();
    if (address(_indexFeed) == address(0) || _feedTimelock == 0) revert FA_InvalidFeed();
    contractSize = _contractSize;
    feedTimelock = _feedTimelock;
    _feedHistory.push(FeedChange({feed: address(_indexFeed), since: uint64(block.timestamp)}));
    emit IndexFeedActivated(address(_indexFeed), uint64(block.timestamp));
  }

  //////////////////////////
  //      Owner-only      //
  //////////////////////////

  function setMarkBounds(uint _maxMarkDeviation, uint _maxMarkDelay) external onlyOwner {
    maxMarkDeviation = _maxMarkDeviation;
    maxMarkDelay = _maxMarkDelay;
    emit MarkBoundsSet(_maxMarkDeviation, _maxMarkDelay);
  }

  /// @notice Band parameters, and the fixing parameters for series listed from now on. The feed is not here: it changes
  ///         only through the timelock. A series already listed keeps the fixing parameters it was listed with.
  function setIndexParams(
    uint _maxMarkIndexDeviation,
    uint _minMarkIndexDeviation,
    uint _bandNarrowingPeriod,
    uint _fixingWindow,
    uint _maxSampleGap,
    uint _recoveryDelay
  ) external onlyOwner {
    if (
      _maxMarkIndexDeviation > 1e18 || _minMarkIndexDeviation > _maxMarkIndexDeviation
        || _fixingWindow < MIN_FIXING_WINDOW || _fixingWindow > MAX_FIXING_WINDOW || _maxSampleGap < MIN_SAMPLE_GAP
        || _maxSampleGap * MIN_GAPS_PER_WINDOW > _fixingWindow || _recoveryDelay > MAX_RECOVERY_DELAY
    ) revert FA_InvalidIndexParams();
    maxMarkIndexDeviation = _maxMarkIndexDeviation;
    minMarkIndexDeviation = _minMarkIndexDeviation;
    bandNarrowingPeriod = _bandNarrowingPeriod;
    fixingWindow = _fixingWindow;
    maxSampleGap = _maxSampleGap;
    recoveryDelay = _recoveryDelay;
    emit IndexParamsSet(
      _maxMarkIndexDeviation, _minMarkIndexDeviation, _bandNarrowingPeriod, _fixingWindow, _maxSampleGap, _recoveryDelay
    );
  }

  function setForwardFeed(IForwardFeed _forwardFeed, uint _minMarkInterval) external onlyOwner {
    forwardFeed = _forwardFeed;
    minMarkInterval = _minMarkInterval;
    emit ForwardFeedSet(address(_forwardFeed), _minMarkInterval);
  }

  /// @notice List a series. It takes the fixing parameters set now, for good: set them first.
  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice)
    external
    onlyOwner
    returns (uint96 subId)
  {
    if (expiry <= block.timestamp || lastTradeTime >= expiry || initialMarkPrice == 0) {
      revert FA_InvalidSchedule();
    }
    if (fixingWindow == 0) revert FA_InvalidIndexParams();
    subId = getSubId(expiry);

    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (market.listed) revert FA_InvalidSchedule();

    _futureContracts[subId] = IFutureAsset.FutureContract({
      listed: true,
      settled: false,
      expiry: expiry,
      lastTradeTime: lastTradeTime,
      lastMarkTime: uint64(block.timestamp),
      markPrice: initialMarkPrice,
      cumulativeVMPerContract: 0
    });
    _seriesFixing[subId] = FixingParams({
      fixingWindow: fixingWindow.toUint64(),
      maxSampleGap: maxSampleGap.toUint64(),
      recoveryDelay: recoveryDelay.toUint64()
    });
    _series.push(subId);

    emit FutureContractSet(subId, expiry, lastTradeTime, initialMarkPrice);
    emit SeriesFixingSet(subId, fixingWindow, maxSampleGap, recoveryDelay);
  }

  //////////////////////////
  //  Index feed, timelocked
  //////////////////////////

  /// @notice Propose a new index feed. It may be activated `feedTimelock` from now. Replaces any pending proposal.
  function proposeIndexFeed(ISpotFeed feed) external onlyOwner {
    if (address(feed) == address(0)) revert FA_InvalidFeed();
    uint64 effectiveAt = (block.timestamp + feedTimelock).toUint64();
    pendingIndexFeed = address(feed);
    pendingIndexFeedEffectiveAt = effectiveAt;
    emit IndexFeedProposed(address(feed), effectiveAt);
  }

  function cancelIndexFeed() external onlyOwner {
    address feed = pendingIndexFeed;
    if (feed == address(0)) revert FA_NoPendingFeed();
    delete pendingIndexFeed;
    delete pendingIndexFeedEffectiveAt;
    emit IndexFeedProposalCancelled(feed);
  }

  /**
   * @notice Activate the pending feed once its timelock has passed, within FEED_ACTIVATION_PERIOD. Anyone may call. It
   *         takes effect now, and so reaches only fixing windows that start from now on.
   * @dev    While any series is past its last trade and unsettled, its holders cannot exit, so a feed change could be
   *         aimed at them. Then the change is a rescue only: allowed once the current feed is failing now and has not
   *         given a price for a full fixing window of every such series. Anyone holding Data Streams reports can keep
   *         the current feed alive by posting them, and so block it.
   */
  function activateIndexFeed() external {
    address feed = pendingIndexFeed;
    if (feed == address(0)) revert FA_NoPendingFeed();
    uint64 effectiveAt = pendingIndexFeedEffectiveAt;
    if (block.timestamp < effectiveAt) revert FA_TimelockNotElapsed();
    if (block.timestamp > effectiveAt + FEED_ACTIVATION_PERIOD) revert FA_FeedProposalLapsed();
    _checkFeedChangeIsARescue();
    delete pendingIndexFeed;
    delete pendingIndexFeedEffectiveAt;
    _feedHistory.push(FeedChange({feed: feed, since: uint64(block.timestamp)}));
    emit IndexFeedActivated(feed, uint64(block.timestamp));
  }

  /// @dev Reverts FA_FeedChangeAfterLastTrade unless no unsettled series is past last trade, or the current feed is
  ///      dead: failing now, and without a price for the longest fixing window among those series.
  function _checkFeedChangeIsARescue() internal view {
    uint deadFor;
    bool locked;
    for (uint i; i < _series.length; ++i) {
      IFutureAsset.FutureContract storage market = _futureContracts[_series[i]];
      if (market.settled || block.timestamp < market.lastTradeTime) continue;
      locked = true;
      uint window = _seriesFixing[_series[i]].fixingWindow;
      if (window > deadFor) deadFor = window;
    }
    if (!locked) return;
    if (block.timestamp < uint(lastIndexReadAt) + deadFor || _feedAnswers(indexFeed())) {
      revert FA_FeedChangeAfterLastTrade();
    }
  }

  /// @dev Whether `feed` gives a non-zero price now, without reverting.
  function _feedAnswers(ISpotFeed feed) internal view returns (bool) {
    try feed.getSpot() returns (uint spot, uint) {
      return spot != 0;
    } catch {
      return false;
    }
  }

  /// @notice The index feed in effect now: marks and fills read it.
  function indexFeed() public view returns (ISpotFeed) {
    return ISpotFeed(_feedHistory[_feedHistory.length - 1].feed);
  }

  /// @notice The index feed that was in effect at `time`: a fixing window samples the one in effect at its start.
  function indexFeedAt(uint64 time) public view returns (ISpotFeed) {
    for (uint i = _feedHistory.length; i > 0; i--) {
      if (_feedHistory[i - 1].since <= time) return ISpotFeed(_feedHistory[i - 1].feed);
    }
    // before the first feed took effect: the deploy-time feed (a window cannot start before the series is listed)
    return ISpotFeed(_feedHistory[0].feed);
  }

  function feedHistory() external view returns (FeedChange[] memory) {
    return _feedHistory;
  }

  /// @notice The fixing parameters `subId` was listed with.
  function seriesFixing(uint subId) external view returns (FixingParams memory) {
    return _seriesFixing[subId];
  }

  //////////////////////////
  //        Marks         //
  //////////////////////////

  /**
   * @notice Mark the series. Anyone may call, at most every `minMarkInterval`, until it settles. Until last trade the
   *         mark is the forward feed; from last trade on it is the index, so margin follows the price to expiry and
   *         through a recovery. (The forward publisher stops at last trade, and its last forward ages out before
   *         expiry; the forward difference that close to expiry is negligible.)
   */
  function pullMark(uint96 subId) external {
    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp < uint(market.lastMarkTime) + minMarkInterval) revert FA_MarkTooSoon();

    uint price;
    if (block.timestamp < market.lastTradeTime) {
      if (address(forwardFeed) == address(0)) revert FA_NoForwardFeed();
      (price,) = forwardFeed.getForwardPrice(market.expiry);
    } else {
      price = _indexPrice();
    }
    if (price == 0) revert FA_InvalidMark();
    _applyMark(subId, market, uint64(block.timestamp), price, true);
  }

  /// @notice The owner's mark, for when the forward feed cannot be used. Same checks as pullMark, until settlement,
  ///         including `minMarkInterval`: the owner can neither mark faster than anyone else nor, by marking, hold
  ///         permissionless marks off for longer than one interval.
  function setMark(uint96 subId, uint64 markTime, uint markPrice) external onlyOwner {
    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp < uint(market.lastMarkTime) + minMarkInterval) revert FA_MarkTooSoon();
    if (markTime > block.timestamp) revert FA_InvalidMark();
    if (maxMarkDelay != 0 && uint(markTime) + maxMarkDelay < block.timestamp) revert FA_StaleMark();
    _applyMark(subId, market, markTime, markPrice, false);
  }

  function _applyMark(
    uint96 subId,
    IFutureAsset.FutureContract storage market,
    uint64 markTime,
    uint markPrice,
    bool fromFeed
  ) internal {
    if (markPrice == 0) revert FA_InvalidMark();
    if (market.settled) revert FA_AlreadySettled();
    if (markTime <= market.lastMarkTime) revert FA_InvalidMark();

    uint oldMarkPrice = market.markPrice;
    // a feed mark moves at most one deviation step towards its price, so marks converge on a jump on their own
    if (fromFeed) markPrice = _clampStep(oldMarkPrice, markPrice);
    _checkDeviation(oldMarkPrice, markPrice);
    // read the index whatever the band: a stale index stops marks, as it stops fills and samples
    _checkMarkAgainstIndex(oldMarkPrice, markPrice, _indexPrice(), market.expiry);
    _accrue(market, markPrice);
    market.lastMarkTime = markTime;

    emit MarkSet(subId, markTime, oldMarkPrice, markPrice, market.cumulativeVMPerContract, fromFeed);
  }

  //////////////////////////
  //       Fixing         //
  //////////////////////////

  /**
   * @notice Record the index for the current fixing window. Anyone may call, inside the window.
   * @dev    The original window (round 0) opens itself at the first sample, ending at expiry. Each sample holds until
   *         the next, so the fixing is the time-weighted average of the index as sampled. Every sample reads the feed
   *         in effect at the window's start, resolved at the first sample.
   */
  function recordFixingSample(uint96 subId) external {
    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (market.settled) revert FA_AlreadySettled();

    Fixing storage fixing = _fixings[subId];
    if (fixing.windowEnd == 0) _openWindow(subId, fixing, 0, market.expiry - _seriesFixing[subId].fixingWindow);
    if (block.timestamp < fixing.windowStart || block.timestamp > fixing.windowEnd) revert FA_OutsideFixingWindow();

    if (fixing.feed == address(0)) fixing.feed = address(indexFeedAt(fixing.windowStart));
    uint price = _spot(ISpotFeed(fixing.feed));
    uint64 now_ = uint64(block.timestamp);
    if (fixing.feed == address(indexFeed())) lastIndexReadAt = now_;

    if (fixing.firstSampleTime == 0) {
      fixing.firstSampleTime = now_;
      fixing.largestGap = now_ - fixing.windowStart;
    } else {
      uint64 gap = now_ - fixing.lastSampleTime;
      fixing.accumulator += fixing.lastPrice * gap;
      if (gap > fixing.largestGap) fixing.largestGap = gap;
    }
    fixing.lastSampleTime = now_;
    fixing.lastPrice = price;

    emit FixingSampled(subId, fixing.round, now_, price);
  }

  /**
   * @notice Once the current window has ended, fix the settlement price to its time-weighted index. Anyone may call.
   * @dev    Refused unless the window was sampled to within its gap limit at every point, start to end. Not held to
   *         the mark deviation bound: a mark that drifted from the index must not be able to block settlement.
   */
  function fixSettlementFromIndex(uint96 subId) external {
    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (block.timestamp < market.expiry) revert FA_NotExpired();

    Fixing storage fixing = _fixings[subId];
    if (block.timestamp < fixing.windowEnd) revert FA_WindowNotOver();
    if (!_fixingComplete(fixing)) revert FA_FixingIncomplete();

    uint64 end = fixing.windowEnd;
    uint duration = end - fixing.firstSampleTime;
    uint accumulator = fixing.accumulator + fixing.lastPrice * (end - fixing.lastSampleTime);
    uint settlementPrice = duration == 0 ? fixing.lastPrice : accumulator / duration;

    _settle(subId, market, settlementPrice);
  }

  /**
   * @notice Open a recovery window for a series whose current window has ended without a complete fixing. Anyone may
   *         call. The window starts the series' `recoveryDelay` from now and runs its `fixingWindow`; the broken
   *         window's samples are discarded. Called again if the recovery window breaks too.
   */
  function openRecoveryWindow(uint96 subId) external {
    IFutureAsset.FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert FA_UnknownFuture();
    if (market.settled) revert FA_AlreadySettled();
    if (block.timestamp < market.expiry) revert FA_NotExpired();

    Fixing storage fixing = _fixings[subId];
    // an original window never sampled still ends at expiry
    uint64 currentEnd = fixing.windowEnd == 0 ? market.expiry : fixing.windowEnd;
    if (block.timestamp < currentEnd) revert FA_WindowNotOver();
    if (fixing.windowEnd != 0 && _fixingComplete(fixing)) revert FA_FixingAvailable();

    uint32 round = fixing.windowEnd == 0 ? 1 : fixing.round + 1;
    _openWindow(subId, fixing, round, (block.timestamp + _seriesFixing[subId].recoveryDelay).toUint64());
    emit RecoveryWindowOpened(subId, round, fixing.windowStart, fixing.windowEnd);
  }

  /// @dev Reset `fixing` to a fresh window, with the series' length and gap limit. Its feed is fixed at its first sample.
  function _openWindow(uint96 subId, Fixing storage fixing, uint32 round, uint64 windowStart) internal {
    FixingParams storage params = _seriesFixing[subId];
    fixing.round = round;
    fixing.windowStart = windowStart;
    fixing.windowEnd = windowStart + params.fixingWindow;
    fixing.maxSampleGap = params.maxSampleGap;
    fixing.firstSampleTime = 0;
    fixing.lastSampleTime = 0;
    fixing.largestGap = 0;
    fixing.feed = address(0);
    fixing.lastPrice = 0;
    fixing.accumulator = 0;
  }

  /// @dev Sampled from the window's start to its end with no gap over the limit.
  function _fixingComplete(Fixing storage fixing) internal view returns (bool) {
    if (fixing.firstSampleTime == 0) return false;
    uint64 closingGap = fixing.windowEnd - fixing.lastSampleTime;
    uint64 largest = closingGap > fixing.largestGap ? closingGap : fixing.largestGap;
    return largest <= fixing.maxSampleGap;
  }

  function _settle(uint96 subId, IFutureAsset.FutureContract storage market, uint settlementPrice) internal {
    if (market.settled) revert FA_AlreadySettled();
    _accrue(market, settlementPrice);
    market.lastMarkTime = uint64(block.timestamp);
    market.settled = true;

    emit SettlementPriceSet(subId, settlementPrice, market.cumulativeVMPerContract, true);
  }

  //////////////////////////
  //        Index         //
  //////////////////////////

  /// @dev The current index. The feed reverts when stale. Records that the feed answered.
  function _indexPrice() internal returns (uint price) {
    price = _spot(indexFeed());
    lastIndexReadAt = uint64(block.timestamp);
  }

  function _spot(ISpotFeed feed) internal view returns (uint spot) {
    (spot,) = feed.getSpot();
    if (spot == 0) revert FA_InvalidMark();
  }

  /**
   * @dev A mark must sit inside the index band, or, when the mark it replaces was already outside it, be strictly
   *      closer to the index than that mark was. Without the second clause a jump in the index wider than the band
   *      plus one deviation step freezes the mark: one step cannot reach the band, and every intermediate step is
   *      outside it. Near expiry, with the band at its narrowest, that is a jump of a few percent. Marks still cannot
   *      move away from the index.
   */
  function _checkMarkAgainstIndex(uint oldMark, uint newMark, uint index, uint64 expiry) internal view {
    uint band = markIndexBand(expiry);
    if (band == 0) return;
    uint newDiff = newMark > index ? newMark - index : index - newMark;
    if (newDiff * 1e18 <= index * band) return;
    uint oldDiff = oldMark > index ? oldMark - index : index - oldMark;
    if (newDiff >= oldDiff) revert FA_MarkOutsideIndexBand();
  }

  /// @dev `target` moved at most maxMarkDeviation from `from`, towards it. Unbounded when maxMarkDeviation is 0.
  function _clampStep(uint from, uint target) internal view returns (uint) {
    if (maxMarkDeviation == 0) return target;
    uint step = from * maxMarkDeviation / 1e18;
    if (target > from) return target - from > step ? from + step : target;
    return from - target > step ? from - step : target;
  }

  function _checkInsideIndexBand(uint price, uint index, uint64 expiry, bool isFill) internal view {
    uint band = markIndexBand(expiry);
    if (band == 0) return;
    uint diff = price > index ? price - index : index - price;
    if (diff * 1e18 > index * band) {
      if (isFill) revert FA_FillOutsideIndexBand();
      revert FA_MarkOutsideIndexBand();
    }
  }

  /// @notice The band a mark or a priced fill must sit within of the index now, for a contract expiring at `expiry`.
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
    IFutureAsset.FutureContract storage market = _futureContracts[adjustment.subId];
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
      uint band = markIndexBand(market.expiry);
      if (band != 0) _checkInsideIndexBand(uint(adjustment.assetData), _indexPrice(), market.expiry, true);
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

  function _accrue(IFutureAsset.FutureContract storage market, uint newPrice) internal {
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

    IFutureAsset.FutureContract storage market = _futureContracts[subId];
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
    IFutureAsset.FutureContract memory market = _futureContracts[subId];
    if (!market.listed) return (0, false);
    return (market.markPrice, true);
  }

  function futureContracts(uint subId) external view returns (IFutureAsset.FutureContract memory) {
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
