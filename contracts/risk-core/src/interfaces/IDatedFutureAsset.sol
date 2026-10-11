// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IAsset} from "./IAsset.sol";
import {IPositionTracking} from "./IPositionTracking.sol";

/**
 * @notice USDC/cNGN dated future, cash settled in cNGN.
 * @dev    Prices are cNGN per USDC (18dp). Contract size is in USDC (18dp). Variation margin is denominated in
 *         cNGN (18dp): a long gains `contractSize * (newMark - oldMark)` cNGN per contract.
 */
interface IDatedFutureAsset is IAsset, IPositionTracking {
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

  function setDailyMark(uint96 subId, uint64 markTime, uint markPrice) external;

  function setSettlementPrice(uint96 subId, uint settlementPrice) external;

  function recordFixingSample(uint96 subId) external;

  function fixSettlementFromIndex(uint96 subId) external;

  function fixings(uint subId) external view returns (Fixing memory);

  /// @notice Realise and return the cNGN owed to (positive) or by (negative) an account. Manager only.
  function settleAccountVM(uint accountId, uint subId) external returns (int cngnDelta);

  /// @notice cNGN that settleAccountVM would return now, without changing state.
  function getPendingVM(uint accountId, uint subId) external view returns (int cngnDelta);

  function getReferencePrice(uint subId) external view returns (uint price, bool isSet);

  function getSubId(uint64 expiry) external pure returns (uint96);

  function parseSubId(uint96 subId) external pure returns (uint64 expiry);

  event FutureContractSet(uint96 indexed subId, uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice);
  event MarkBoundsSet(uint maxMarkDeviation, uint maxMarkDelay);
  event DailyMarkSet(
    uint96 indexed subId, uint64 markTime, uint oldMarkPrice, uint newMarkPrice, int cumulativeVMPerContract
  );
  event IndexParamsSet(
    address indexFeed, uint maxMarkIndexDeviation, uint fixingWindow, uint maxSampleGap, uint fallbackDelay
  );
  event FixingSampled(uint96 indexed subId, uint64 sampleTime, uint indexPrice);
  event SettlementPriceSet(uint96 indexed subId, uint settlementPrice, int cumulativeVMPerContract, bool fromIndex);
  event FutureVMSynchronized(uint indexed accountId, uint96 indexed subId, int cngnDelta, int cumulativeVMPerContract);

  error DFA_NotManager();
  error DFA_UnknownFuture();
  error DFA_InvalidSubId();
  error DFA_InvalidSchedule();
  error DFA_InvalidMark();
  error DFA_StaleMark();
  error DFA_MarkDeviationExceeded();
  error DFA_AlreadySettled();
  error DFA_NotExpired();
  error DFA_TradingClosed();
  error DFA_InvalidIndexParams();
  error DFA_MarkOutsideIndexBand();
  error DFA_OutsideFixingWindow();
  error DFA_FixingIncomplete();
  error DFA_FixingAvailable();
}
