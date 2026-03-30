// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IDeliverableFXFutureAsset} from "../interfaces/IDeliverableFXFutureAsset.sol";

import {ManagerWhitelist} from "./utils/ManagerWhitelist.sol";
import {PositionTracking} from "./utils/PositionTracking.sol";

contract DeliverableFXFutureAsset is IDeliverableFXFutureAsset, PositionTracking, ManagerWhitelist {
  using SafeCast for uint;

  mapping(uint96 subId => Series) internal _series;
  mapping(uint accountId => mapping(uint96 subId => int cumulative)) public accountLastCumulativeVM;
  mapping(uint accountId => mapping(uint96 subId => int cashToSettle)) public accountCashToSettle;
  mapping(IManager manager => uint) public totalLongPosition;
  mapping(IManager manager => uint) public totalShortPosition;

  constructor(ISubAccounts _subAccounts) ManagerWhitelist(_subAccounts) {}

  function createSeries(
    uint64 expiry,
    uint64 lastTradeTime,
    address baseAsset,
    address quoteAsset,
    uint128 contractSizeBase,
    uint128 minTradeIncrement,
    uint128 tickSize,
    uint initialMarkPrice
  ) external onlyOwner returns (uint96 subId) {
    if (
      expiry <= block.timestamp || lastTradeTime >= expiry || baseAsset == address(0) || quoteAsset == address(0)
        || contractSizeBase == 0 || minTradeIncrement == 0 || tickSize == 0 || initialMarkPrice == 0
    ) revert DFXF_InvalidSchedule();

    subId = uint96(expiry);
    if (_series[subId].listed) revert DFXF_InvalidSchedule();

    _series[subId] = Series({
      listed: true,
      expiry: expiry,
      lastTradeTime: lastTradeTime,
      baseAsset: baseAsset,
      quoteAsset: quoteAsset,
      contractSizeBase: contractSizeBase,
      minTradeIncrement: minTradeIncrement,
      tickSize: tickSize,
      markPrice: initialMarkPrice.toUint96(),
      lastMarkTime: uint64(block.timestamp),
      settlementPrice: 0,
      settlementPriceSet: false,
      cumulativeVMPerContract: 0,
      settlementType: SettlementType.PhysicalDelivery
    });

    emit SeriesCreated(
      subId, expiry, lastTradeTime, baseAsset, quoteAsset, contractSizeBase, minTradeIncrement, tickSize, initialMarkPrice
    );
  }

  function setMarkPrice(uint96 subId, uint64 markTime, uint markPrice) external onlyOwner {
    Series storage series = _series[subId];
    if (!series.listed) revert DFXF_UnknownSeries();
    if (markPrice == 0 || markTime <= series.lastMarkTime || markTime > series.expiry) revert DFXF_InvalidMark();

    uint oldMarkPrice = series.markPrice;
    int delta = int(markPrice) - int(oldMarkPrice);
    series.cumulativeVMPerContract += (delta * int(uint(series.contractSizeBase))) / 1e18;
    series.markPrice = markPrice.toUint96();
    series.lastMarkTime = markTime;

    emit MarkPriceSet(subId, markTime, oldMarkPrice, markPrice, series.cumulativeVMPerContract);
  }

  function setSettlementPrice(uint96 subId, uint settlementPrice) external onlyOwner {
    Series storage series = _series[subId];
    if (!series.listed || settlementPrice == 0) revert DFXF_InvalidMark();
    series.settlementPrice = settlementPrice.toUint96();
    series.settlementPriceSet = true;
    emit SettlementPriceSet(subId, settlementPrice);
  }

  function handleAdjustment(
    ISubAccounts.AssetAdjustment memory adjustment,
    uint tradeId,
    int preBalance,
    IManager manager,
    address caller
  ) external onlyAccounts returns (int finalBalance, bool needAllowance) {
    Series storage series = _series[uint96(adjustment.subId)];
    if (!series.listed) revert DFXF_UnknownSeries();

    _checkManager(address(manager));
    if (block.timestamp >= series.lastTradeTime && adjustment.amount != 0 && caller != address(manager)) {
      revert DFXF_TradingClosed();
    }

    uint absDelta = SignedMath.abs(adjustment.amount);
    if (absDelta % series.minTradeIncrement != 0) revert DFXF_InvalidTradeIncrement();

    _takeTotalPositionSnapshotPreTrade(manager, tradeId);
    _updateTotalPositions(manager, preBalance, adjustment.amount);
    _updateDirectionalPositions(manager, preBalance, adjustment.amount);

    _synchronizeVM(adjustment.acc, uint96(adjustment.subId), preBalance);

    finalBalance = preBalance + adjustment.amount;
    return (finalBalance, true);
  }

  function settleAccountVM(uint accountId, uint96 subId) external returns (int cashDelta) {
    if (msg.sender != address(subAccounts.manager(accountId))) revert DFXF_NotManager();

    int position = subAccounts.getBalance(accountId, this, subId);
    _synchronizeVM(accountId, subId, position);

    cashDelta = accountCashToSettle[accountId][subId];
    accountCashToSettle[accountId][subId] = 0;
  }

  function _synchronizeVM(uint accountId, uint96 subId, int oldPosition) internal {
    Series storage series = _series[subId];
    if (!series.listed) revert DFXF_UnknownSeries();

    int latest = series.cumulativeVMPerContract;
    int previous = accountLastCumulativeVM[accountId][subId];
    int diff = latest - previous;
    if (diff == 0) return;

    accountLastCumulativeVM[accountId][subId] = latest;

    int cashDelta = (oldPosition * diff) / 1e18;
    if (cashDelta != 0) {
      accountCashToSettle[accountId][subId] += cashDelta;
    }

    emit DeliverableFutureVMSynchronized(accountId, subId, cashDelta, latest);
  }

  function getSettlementAmounts(uint96 subId, int position) external view returns (uint baseAmount, uint quoteAmount) {
    return _getSettlementAmounts(subId, position);
  }

  function previewSettlement(uint accountId, uint96 subId) external view returns (SettlementPreview memory preview) {
    int position = subAccounts.getBalance(accountId, this, subId);
    (uint baseAmount, uint quoteAmount) = _getSettlementAmounts(subId, position);
    preview = SettlementPreview({
      position: position,
      absPosition: SignedMath.abs(position),
      baseAmount: baseAmount,
      quoteAmount: quoteAmount,
      canSettle: position != 0 && _series[subId].settlementPriceSet && block.timestamp >= _series[subId].expiry
    });
  }

  function _getSettlementAmounts(uint96 subId, int position) internal view returns (uint baseAmount, uint quoteAmount) {
    Series memory series = _series[subId];
    if (!series.listed) revert DFXF_UnknownSeries();

    baseAmount = (SignedMath.abs(position) * uint(series.contractSizeBase)) / 1e18;
    if (!series.settlementPriceSet) return (baseAmount, 0);
    quoteAmount = (baseAmount * uint(series.settlementPrice)) / 1e18;
  }

  function getSeries(uint96 subId) external view returns (Series memory) {
    return _series[subId];
  }

  function isTradingOpen(uint96 subId) external view returns (bool) {
    Series memory series = _series[subId];
    if (!series.listed) return false;
    return block.timestamp < series.lastTradeTime;
  }

  function _updateDirectionalPositions(IManager manager, int preBalance, int change) internal {
    int postBalance = preBalance + change;

    totalLongPosition[manager] = totalLongPosition[manager] + _positivePosition(postBalance) - _positivePosition(preBalance);
    totalShortPosition[manager] =
      totalShortPosition[manager] + _negativePosition(postBalance) - _negativePosition(preBalance);
  }

  function _positivePosition(int balance) internal pure returns (uint) {
    return balance > 0 ? uint(balance) : 0;
  }

  function _negativePosition(int balance) internal pure returns (uint) {
    return balance < 0 ? SignedMath.abs(balance) : 0;
  }
}
