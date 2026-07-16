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

  /// max relative price change per mark/settlement update, 1e18-scaled fraction; 0 disables
  uint public maxMarkDeviation;
  /// max age of a submitted markTime in seconds; 0 disables
  uint public maxMarkDelay;

  constructor(ISubAccounts _subAccounts) ManagerWhitelist(_subAccounts) {}

  function setMarkBounds(uint _maxMarkDeviation, uint _maxMarkDelay) external onlyOwner {
    maxMarkDeviation = _maxMarkDeviation;
    maxMarkDelay = _maxMarkDelay;
    emit MarkBoundsSet(_maxMarkDeviation, _maxMarkDelay);
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
    if (series.settlementPriceSet) revert DFXF_SettlementPriceAlreadySet();
    if (markPrice == 0 || markTime <= series.lastMarkTime || markTime > series.expiry) revert DFXF_InvalidMark();
    if (maxMarkDelay != 0 && uint(markTime) + maxMarkDelay < block.timestamp) revert DFXF_StaleMark();

    uint oldMarkPrice = series.markPrice;
    _checkDeviation(oldMarkPrice, markPrice);
    int delta = int(markPrice) - int(oldMarkPrice);
    // VM accrues in cash (base/USDC) units: the quote-denominated PnL of the mark move
    // (delta * contractSizeBase) converted at the new mark price.
    series.cumulativeVMPerContract += (delta * int(uint(series.contractSizeBase))) / int(markPrice);
    series.markPrice = markPrice.toUint96();
    series.lastMarkTime = markTime;

    emit MarkPriceSet(subId, markTime, oldMarkPrice, markPrice, series.cumulativeVMPerContract);
  }

  function setSettlementPrice(uint96 subId, uint settlementPrice) external onlyOwner {
    Series storage series = _series[subId];
    if (!series.listed || settlementPrice == 0) revert DFXF_InvalidMark();
    if (series.settlementPriceSet) revert DFXF_SettlementPriceAlreadySet();

    uint oldMarkPrice = series.markPrice;
    _checkDeviation(oldMarkPrice, settlementPrice);

    // Accrue the final VM leg from the last mark to the fixing so trade-price
    // economics hold even when no final mark was pushed at the fixing.
    int delta = int(settlementPrice) - int(oldMarkPrice);
    series.cumulativeVMPerContract += (delta * int(uint(series.contractSizeBase))) / int(settlementPrice);
    series.markPrice = settlementPrice.toUint96();

    series.settlementPrice = settlementPrice.toUint96();
    series.settlementPriceSet = true;
    emit SettlementPriceSet(subId, settlementPrice, series.cumulativeVMPerContract);
  }

  function _checkDeviation(uint oldPrice, uint newPrice) internal view {
    if (maxMarkDeviation == 0) return;
    uint diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
    if (diff * 1e18 > oldPrice * maxMarkDeviation) revert DFXF_MarkDeviationExceeded();
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

    // 1. Settle all outstanding VM on pre-trade position up to current mark price
    _synchronizeVM(adjustment.acc, uint96(adjustment.subId), preBalance);

    finalBalance = preBalance + adjustment.amount;

    _blendVM(
      adjustment.acc,
      uint96(adjustment.subId),
      preBalance,
      finalBalance,
      uint(uint256(adjustment.assetData))
    );

    return (finalBalance, true);
  }

  function _blendVM(
    uint acc,
    uint96 subId,
    int preBalance,
    int finalBalance,
    uint tradePrice
  ) internal {
    if (tradePrice != 0 && finalBalance - preBalance != 0) {
      Series storage series = _series[subId];
      int latest = series.cumulativeVMPerContract;
      int amount = finalBalance - preBalance;
      // Cash (base/USDC) units. Like setMarkPrice accruals, the increment (mark -> tradePrice)
      // converts at its destination price, so marking to the trade price yields exactly zero VM.
      int deltaVM =
        (int(tradePrice) - int(uint(series.markPrice))) * int(uint(series.contractSizeBase)) / int(tradePrice);
      int entryVM = latest + deltaVM;

      if (preBalance == 0) {
        accountLastCumulativeVM[acc][subId] = entryVM;
      } else {
        bool sameSign = (preBalance > 0 && finalBalance > 0) || (preBalance < 0 && finalBalance < 0);
        bool absExposureIncreased = SignedMath.abs(finalBalance) > SignedMath.abs(preBalance);

        if (sameSign && absExposureIncreased) {
          accountLastCumulativeVM[acc][subId] =
            (preBalance * latest + amount * entryVM) / finalBalance;
        } else if (sameSign) {
          int realizedVM = (amount * (latest - entryVM)) / 1e18;
          accountCashToSettle[acc][subId] += realizedVM;
          accountLastCumulativeVM[acc][subId] = latest;
        } else {
          int realizedVM = (-preBalance * (latest - entryVM)) / 1e18;
          accountCashToSettle[acc][subId] += realizedVM;
          accountLastCumulativeVM[acc][subId] = entryVM;
        }
      }
    }
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
