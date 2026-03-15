// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IAsset} from "./IAsset.sol";
import {IPositionTracking} from "./IPositionTracking.sol";

interface IDatedFutureAsset is IAsset, IPositionTracking {
  struct FutureContract {
    bool listed;
    uint64 expiry;
    uint64 lastTradeTime;
    uint64 lastMarkTime;
    uint markPrice;
    int cumulativeDailyVMPerContract;
  }

  function contractSize() external view returns (uint);

  function futureContracts(uint subId) external view returns (FutureContract memory);

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice) external returns (uint96 subId);

  function setDailyMark(uint96 subId, uint64 markTime, uint markPrice) external;

  function settleAccount(uint accountId, uint subId) external returns (int cashDelta);

  function getReferencePrice(uint subId) external view returns (uint price, bool isSet);

  function getSubId(uint64 expiry) external pure returns (uint96);

  function parseSubId(uint96 subId) external pure returns (uint64 expiry);

  event FutureContractSet(uint96 indexed subId, uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice);
  event DailyMarkSet(
    uint96 indexed subId, uint64 markTime, uint oldMarkPrice, uint newMarkPrice, int cumulativeDailyVMPerContract
  );
  event FutureVMSynchronized(uint indexed accountId, uint96 indexed subId, int cashDelta, int cumulativeDailyVMPerContract);

  error DFA_NotManager();
  error DFA_UnknownFuture();
  error DFA_InvalidSubId();
  error DFA_InvalidSchedule();
  error DFA_InvalidMark();
  error DFA_TradingClosed();
}
