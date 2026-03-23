// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IAsset} from "./IAsset.sol";
import {IPositionTracking} from "./IPositionTracking.sol";

interface IDeliverableFXFutureAsset is IAsset, IPositionTracking {
  enum SettlementType {
    PhysicalDelivery
  }

  struct Series {
    bool listed;
    uint64 expiry;
    uint64 lastTradeTime;
    address baseAsset;
    address quoteAsset;
    uint128 contractSizeBase;
    uint128 minTradeIncrement;
    uint128 tickSize;
    uint96 markPrice;
    uint64 lastMarkTime;
    uint96 settlementPrice;
    bool settlementPriceSet;
    int cumulativeVMPerContract;
    SettlementType settlementType;
  }

  struct SettlementPreview {
    int position;
    uint absPosition;
    uint baseAmount;
    uint quoteAmount;
    bool canSettle;
  }

  function createSeries(
    uint64 expiry,
    uint64 lastTradeTime,
    address baseAsset,
    address quoteAsset,
    uint128 contractSizeBase,
    uint128 minTradeIncrement,
    uint128 tickSize,
    uint initialMarkPrice
  ) external returns (uint96 subId);

  function setMarkPrice(uint96 subId, uint64 markTime, uint markPrice) external;

  function setSettlementPrice(uint96 subId, uint settlementPrice) external;

  function settleAccountVM(uint accountId, uint96 subId) external returns (int cashDelta);

  function getSettlementAmounts(uint96 subId, int position) external view returns (uint baseAmount, uint quoteAmount);

  function previewSettlement(uint accountId, uint96 subId) external view returns (SettlementPreview memory);

  function getSeries(uint96 subId) external view returns (Series memory);

  function isTradingOpen(uint96 subId) external view returns (bool);

  event SeriesCreated(
    uint96 indexed subId,
    uint64 expiry,
    uint64 lastTradeTime,
    address baseAsset,
    address quoteAsset,
    uint128 contractSizeBase,
    uint128 minTradeIncrement,
    uint128 tickSize,
    uint initialMarkPrice
  );
  event MarkPriceSet(
    uint96 indexed subId, uint64 markTime, uint oldMarkPrice, uint newMarkPrice, int cumulativeVMPerContract
  );
  event SettlementPriceSet(uint96 indexed subId, uint settlementPrice);
  event DeliverableFutureVMSynchronized(
    uint indexed accountId, uint96 indexed subId, int cashDelta, int cumulativeVMPerContract
  );

  error DFXF_NotManager();
  error DFXF_UnknownSeries();
  error DFXF_InvalidSchedule();
  error DFXF_InvalidMark();
  error DFXF_TradingClosed();
  error DFXF_InvalidTradeIncrement();
}
