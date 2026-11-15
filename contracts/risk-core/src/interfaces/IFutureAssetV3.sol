// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IAsset} from "./IAsset.sol";
import {IPositionTracking} from "./IPositionTracking.sol";
import {IFutureAsset} from "./IFutureAsset.sol";
import {ISpotFeed} from "./ISpotFeed.sol";

/**
 * @notice Dated future, v3 (src/assets/FutureAsset): settles only from its index, through repeating recovery windows,
 *         with no owner settlement price. See docs/eurc-usdc-futures-spec.md, A8.
 * @dev    MarginEngine calls a future through IFutureAsset, and only `contractSize`, `futureContracts`, `getPendingVM`
 *         and `settleAccountVM` (FutureVMLib). Those keep IFutureAsset's selectors and `FutureContract` layout here, so
 *         the deployed engine margins a v3 series as it does a v2 one. IFutureAsset's `setSettlementPrice` and
 *         `fallbackReference` are deliberately absent: v3 has no owner price.
 */
interface IFutureAssetV3 is IAsset, IPositionTracking {
  /// @dev One fixing window: the original, ending at expiry (round 0), or a recovery window opened after it broke.
  ///      `feed` is the index feed in effect at `windowStart`, resolved at the first sample and used for every sample.
  struct Fixing {
    uint32 round;
    uint64 windowStart;
    uint64 windowEnd;
    uint64 maxSampleGap;
    uint64 firstSampleTime;
    uint64 lastSampleTime;
    uint64 largestGap;
    address feed;
    uint lastPrice;
    uint accumulator;
  }

  /// @dev A series' fixing parameters, fixed when it is listed.
  struct FixingParams {
    uint64 fixingWindow;
    uint64 maxSampleGap;
    uint64 recoveryDelay;
  }

  /// @dev An index feed and the time it took effect. History is append-only.
  struct FeedChange {
    address feed;
    uint64 since;
  }

  // ---- read by MarginEngine (IFutureAsset selectors) ----

  function contractSize() external view returns (uint);

  function futureContracts(uint subId) external view returns (IFutureAsset.FutureContract memory);

  function settleAccountVM(uint accountId, uint subId) external returns (int vmDelta);

  function getPendingVM(uint accountId, uint subId) external view returns (int vmDelta);

  // ---- series ----

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice) external returns (uint96 subId);

  function setMark(uint96 subId, uint64 markTime, uint markPrice) external;

  function pullMark(uint96 subId) external;

  function markIndexBand(uint64 expiry) external view returns (uint);

  function getReferencePrice(uint subId) external view returns (uint price, bool isSet);

  function getSubId(uint64 expiry) external pure returns (uint96);

  function parseSubId(uint96 subId) external pure returns (uint64 expiry);

  // ---- index feed, behind a timelock ----

  function feedTimelock() external view returns (uint);

  function indexFeed() external view returns (ISpotFeed);

  function indexFeedAt(uint64 time) external view returns (ISpotFeed);

  function feedHistory() external view returns (FeedChange[] memory);

  function proposeIndexFeed(ISpotFeed feed) external;

  function cancelIndexFeed() external;

  function activateIndexFeed() external;

  // ---- fixing ----

  function recordFixingSample(uint96 subId) external;

  function fixSettlementFromIndex(uint96 subId) external;

  function openRecoveryWindow(uint96 subId) external;

  function fixings(uint subId) external view returns (Fixing memory);

  function seriesFixing(uint subId) external view returns (FixingParams memory);

  event FutureContractSet(uint96 indexed subId, uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice);
  event MarkBoundsSet(uint maxMarkDeviation, uint maxMarkDelay);
  event MarkSet(
    uint96 indexed subId,
    uint64 markTime,
    uint oldMarkPrice,
    uint newMarkPrice,
    int cumulativeVMPerContract,
    bool fromFeed
  );
  event IndexParamsSet(
    uint maxMarkIndexDeviation,
    uint minMarkIndexDeviation,
    uint bandNarrowingPeriod,
    uint fixingWindow,
    uint maxSampleGap,
    uint recoveryDelay
  );
  event IndexFeedProposed(address feed, uint64 effectiveAt);
  event IndexFeedProposalCancelled(address feed);
  event IndexFeedActivated(address feed, uint64 since);
  event ForwardFeedSet(address forwardFeed, uint minMarkInterval);
  event SeriesFixingSet(uint96 indexed subId, uint fixingWindow, uint maxSampleGap, uint recoveryDelay);
  event FixingSampled(uint96 indexed subId, uint32 round, uint64 sampleTime, uint indexPrice);
  event RecoveryWindowOpened(uint96 indexed subId, uint32 round, uint64 windowStart, uint64 windowEnd);
  /// @dev `fromIndex` is always true in v3; kept so indexers read v2 and v3 settlements alike.
  event SettlementPriceSet(uint96 indexed subId, uint settlementPrice, int cumulativeVMPerContract, bool fromIndex);
  event FutureVMSynchronized(uint indexed accountId, uint96 indexed subId, int vmDelta, int cumulativeVMPerContract);

  error FA_NotManager();
  error FA_UnknownFuture();
  error FA_InvalidSubId();
  error FA_InvalidSchedule();
  error FA_InvalidMark();
  error FA_StaleMark();
  error FA_MarkDeviationExceeded();
  error FA_AlreadySettled();
  error FA_NotExpired();
  error FA_TradingClosed();
  error FA_InvalidIndexParams();
  error FA_MarkOutsideIndexBand();
  /// @dev A fill priced outside the band a mark must sit in (markIndexBand around the index)
  error FA_FillOutsideIndexBand();
  error FA_OutsideFixingWindow();
  error FA_FixingIncomplete();
  error FA_FixingAvailable();
  error FA_WindowNotOver();
  error FA_NoForwardFeed();
  error FA_MarkTooSoon();
  error FA_InvalidFeed();
  error FA_NoPendingFeed();
  error FA_TimelockNotElapsed();
  error FA_FeedProposalLapsed();
  /// @dev A feed change while a series is past last trade, with the current feed still alive
  error FA_FeedChangeAfterLastTrade();
}
