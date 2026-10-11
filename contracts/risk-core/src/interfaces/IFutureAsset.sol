// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IAsset} from "./IAsset.sol";
import {IPositionTracking} from "./IPositionTracking.sol";

/**
 * @notice USDC/cNGN dated future, cash settled in cNGN.
 * @dev    Prices are cNGN per USDC (18dp). Contract size is in USDC (18dp). Variation margin is denominated in
 *         cNGN (18dp): a long gains `contractSize * (newMark - oldMark)` cNGN per contract.
 */
interface IFutureAsset is IAsset, IPositionTracking {
  struct FutureContract {
    bool listed;
    bool settled;
    uint64 expiry;
    uint64 lastTradeTime;
    uint64 lastMarkTime;
    uint markPrice;
    int cumulativeVMPerContract;
  }

  /// @dev Settlement fixing state. Prices are cNGN per USDC; the accumulator sums price * seconds held.
  struct Fixing {
    uint64 windowStart;
    uint64 maxSampleGap;
    uint64 firstSampleTime;
    uint64 lastSampleTime;
    uint64 largestGap;
    uint lastPrice;
    uint accumulator;
  }

  function contractSize() external view returns (uint);

  function futureContracts(uint subId) external view returns (FutureContract memory);

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice) external returns (uint96 subId);

  function setMark(uint96 subId, uint64 markTime, uint markPrice) external;

  function pullMark(uint96 subId) external;

  function markIndexBand(uint64 expiry) external view returns (uint);

  function setSettlementPrice(uint96 subId, uint settlementPrice) external;

  function recordFixingSample(uint96 subId) external;

  function fixSettlementFromIndex(uint96 subId) external;

  function fixings(uint subId) external view returns (Fixing memory);

  function fallbackReference(uint96 subId) external view returns (uint);

  /// @notice Realise and return the cNGN owed to (positive) or by (negative) an account. Manager only.
  function settleAccountVM(uint accountId, uint subId) external returns (int cngnDelta);

  /// @notice cNGN that settleAccountVM would return now, without changing state.
  function getPendingVM(uint accountId, uint subId) external view returns (int cngnDelta);

  function getReferencePrice(uint subId) external view returns (uint price, bool isSet);

  function getSubId(uint64 expiry) external pure returns (uint96);

  function parseSubId(uint96 subId) external pure returns (uint64 expiry);

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
    address indexFeed,
    uint maxMarkIndexDeviation,
    uint minMarkIndexDeviation,
    uint bandNarrowingPeriod,
    uint fixingWindow,
    uint maxSampleGap,
    uint fallbackDelay
  );
  event ForwardFeedSet(address forwardFeed, uint minMarkInterval);
  event FixingSampled(uint96 indexed subId, uint64 sampleTime, uint indexPrice);
  event SettlementPriceSet(uint96 indexed subId, uint settlementPrice, int cumulativeVMPerContract, bool fromIndex);
  event FutureVMSynchronized(uint indexed accountId, uint96 indexed subId, int cngnDelta, int cumulativeVMPerContract);

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
  error FA_OutsideFixingWindow();
  error FA_FixingIncomplete();
  error FA_FixingAvailable();
  error FA_FallbackOutsideBand();
  error FA_NoSettlementReference();
  error FA_NoForwardFeed();
  error FA_MarkTooSoon();
  error FA_MarkingClosed();
}
