// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SignedMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {IDeliverableFXFutureAsset} from "../interfaces/IDeliverableFXFutureAsset.sol";

contract DeliverableFXManagerHelper {
  ISubAccounts public immutable subAccounts;
  address public immutable manager;

  mapping(uint accountId => mapping(IAsset asset => uint amount)) internal _reservedBalance;
  mapping(uint accountId => mapping(IDeliverableFXFutureAsset future => mapping(uint96 subId => bool settled)))
    internal _accountSettled;

  error DFXMH_OnlyManager();

  modifier onlyManager() {
    if (msg.sender != manager) revert DFXMH_OnlyManager();
    _;
  }

  constructor(ISubAccounts subAccounts_) {
    subAccounts = subAccounts_;
    manager = msg.sender;
  }

  function reservedBalance(uint accountId, IAsset asset) external view returns (uint) {
    return _reservedBalance[accountId][asset];
  }

  function accountSettled(uint accountId, IDeliverableFXFutureAsset future, uint96 subId) external view returns (bool) {
    return _accountSettled[accountId][future][subId];
  }

  function getSettlementAmounts(IDeliverableFXFutureAsset future, uint accountId, uint96 subId)
    public
    view
    returns (int position, uint baseAmount, uint quoteAmount)
  {
    position = subAccounts.getBalance(accountId, future, subId);
    (baseAmount, quoteAmount) = future.getSettlementAmounts(subId, position);
  }

  function refreshReservation(IDeliverableFXFutureAsset future, uint accountId, uint96 subId) external onlyManager {
    IDeliverableFXFutureAsset.Series memory series = future.getSeries(subId);
    IAsset baseAsset = IAsset(series.baseAsset);
    IAsset quoteAsset = IAsset(series.quoteAsset);
    (int position, uint baseAmount, uint quoteAmount) = getSettlementAmounts(future, accountId, subId);

    _reservedBalance[accountId][baseAsset] = 0;
    _reservedBalance[accountId][quoteAsset] = 0;

    if (position > 0) {
      _reservedBalance[accountId][quoteAsset] = quoteAmount;
    } else if (position < 0) {
      _reservedBalance[accountId][baseAsset] = baseAmount;
    }
  }

  function clearReservation(uint accountId, IAsset asset) external onlyManager {
    _reservedBalance[accountId][asset] = 0;
  }

  function markSettled(uint accountId, IDeliverableFXFutureAsset future, uint96 subId) external onlyManager {
    _accountSettled[accountId][future][subId] = true;
  }

  function canSettle(IDeliverableFXFutureAsset future, uint accountId, uint96 subId, uint managerAccountId)
    external
    view
    returns (bool)
  {
    if (_accountSettled[accountId][future][subId]) return false;

    IDeliverableFXFutureAsset.Series memory series = future.getSeries(subId);
    if (!series.settlementPriceSet || block.timestamp < series.expiry) return false;

    (int position, uint baseAmount, uint quoteAmount) = getSettlementAmounts(future, accountId, subId);
    if (position == 0) return false;

    if (position > 0) {
      if (_reservedBalance[accountId][IAsset(series.quoteAsset)] < quoteAmount) return false;
      return subAccounts.getBalance(managerAccountId, IAsset(series.baseAsset), 0) >= int(baseAmount);
    }

    if (_reservedBalance[accountId][IAsset(series.baseAsset)] < baseAmount) return false;
    return subAccounts.getBalance(managerAccountId, IAsset(series.quoteAsset), 0) >= int(quoteAmount);
  }

  function hasDeliverableSufficiency(IDeliverableFXFutureAsset future, uint accountId, uint96 subId)
    external
    view
    returns (bool)
  {
    IDeliverableFXFutureAsset.Series memory series = future.getSeries(subId);
    if (block.timestamp < series.lastTradeTime) return true;

    (int position, uint baseAmount, uint quoteAmount) = getSettlementAmounts(future, accountId, subId);
    if (position == 0) return true;

    if (position > 0) {
      int totalQuote = subAccounts.getBalance(accountId, IAsset(series.quoteAsset), 0);
      return totalQuote >= 0 && uint(totalQuote) >= quoteAmount
        && _reservedBalance[accountId][IAsset(series.quoteAsset)] >= quoteAmount;
    }

    int totalBase = subAccounts.getBalance(accountId, IAsset(series.baseAsset), 0);
    return totalBase >= 0 && uint(totalBase) >= baseAmount
      && _reservedBalance[accountId][IAsset(series.baseAsset)] >= baseAmount;
  }
}
