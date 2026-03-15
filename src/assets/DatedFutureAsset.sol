// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";

import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IDatedFutureAsset} from "../interfaces/IDatedFutureAsset.sol";

import {ManagerWhitelist} from "./utils/ManagerWhitelist.sol";
import {PositionTracking} from "./utils/PositionTracking.sol";

/**
 * @title DatedFutureAsset
 * @notice cNGN/USDC-only dated futures with daily variation margin bookkeeping.
 * @dev Settlement is realized lazily when the account is touched or explicitly settled by the manager.
 */
contract DatedFutureAsset is IDatedFutureAsset, PositionTracking, ManagerWhitelist {
  using SafeCast for uint;
  using SafeCast for int;
  using SignedDecimalMath for int;

  /// @dev Contract size in cNGN units (18 decimals) per 1 futures contract (18 decimals).
  uint public immutable contractSize;

  mapping(uint subId => FutureContract) internal _futureContracts;

  /// @dev accountId => subId => last settled cumulative VM per contract
  mapping(uint accountId => mapping(uint subId => int cumulative)) public accountLastCumulativeVM;

  /// @dev accountId => subId => pending cash not yet applied to CashAsset by manager
  mapping(uint accountId => mapping(uint subId => int cashToSettle)) public accountCashToSettle;

  constructor(ISubAccounts _subAccounts, uint _contractSize) ManagerWhitelist(_subAccounts) {
    if (_contractSize == 0) revert DFA_InvalidSchedule();
    contractSize = _contractSize;
  }

  //////////////////////////
  //      Owner-only      //
  //////////////////////////

  function setContract(uint64 expiry, uint64 lastTradeTime, uint initialMarkPrice) external onlyOwner returns (uint96 subId) {
    if (expiry <= block.timestamp || lastTradeTime >= expiry || initialMarkPrice == 0) {
      revert DFA_InvalidSchedule();
    }
    subId = getSubId(expiry);

    FutureContract storage market = _futureContracts[subId];
    if (market.listed) revert DFA_InvalidSchedule();

    _futureContracts[subId] = FutureContract({
      listed: true,
      expiry: expiry,
      lastTradeTime: lastTradeTime,
      lastMarkTime: uint64(block.timestamp),
      markPrice: initialMarkPrice,
      cumulativeDailyVMPerContract: 0
    });

    emit FutureContractSet(subId, expiry, lastTradeTime, initialMarkPrice);
  }

  function setDailyMark(uint96 subId, uint64 markTime, uint markPrice) external onlyOwner {
    if (markPrice == 0) revert DFA_InvalidMark();

    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert DFA_UnknownFuture();
    if (markTime <= market.lastMarkTime || markTime > market.expiry) revert DFA_InvalidMark();

    uint oldMarkPrice = market.markPrice;
    int delta = markPrice.toInt256() - oldMarkPrice.toInt256();

    market.cumulativeDailyVMPerContract += delta.multiplyDecimal(contractSize.toInt256());
    market.lastMarkTime = markTime;
    market.markPrice = markPrice;

    emit DailyMarkSet(subId, markTime, oldMarkPrice, markPrice, market.cumulativeDailyVMPerContract);
  }

  //////////////////////////
  //    Account Hooks     //
  //////////////////////////

  function handleAdjustment(
    ISubAccounts.AssetAdjustment memory adjustment,
    uint tradeId,
    int preBalance,
    IManager manager,
    address /*caller*/
  ) external onlyAccounts returns (int finalBalance, bool needAllowance) {
    FutureContract storage market = _futureContracts[adjustment.subId];
    if (!market.listed) revert DFA_UnknownFuture();
    if (uint96(adjustment.subId) != getSubId(market.expiry)) revert DFA_InvalidSubId();
    if (block.timestamp >= market.lastTradeTime && adjustment.amount != 0) revert DFA_TradingClosed();

    _checkManager(address(manager));

    _takeTotalPositionSnapshotPreTrade(manager, tradeId);
    _updateTotalPositions(manager, preBalance, adjustment.amount);

    _synchronizeDailyVM(adjustment.acc, adjustment.subId, preBalance);

    finalBalance = preBalance + adjustment.amount;

    // always require allowance for transfer-like adjustments
    return (finalBalance, true);
  }

  //////////////////////////
  //     Settlement       //
  //////////////////////////

  function settleAccount(uint accountId, uint subId) external returns (int cashDelta) {
    if (msg.sender != address(subAccounts.manager(accountId))) revert DFA_NotManager();

    int position = subAccounts.getBalance(accountId, this, subId);
    _synchronizeDailyVM(accountId, subId, position);

    cashDelta = accountCashToSettle[accountId][subId];
    accountCashToSettle[accountId][subId] = 0;
  }

  function _synchronizeDailyVM(uint accountId, uint subId, int position) internal {
    FutureContract storage market = _futureContracts[subId];
    if (!market.listed) revert DFA_UnknownFuture();

    int latest = market.cumulativeDailyVMPerContract;
    int previous = accountLastCumulativeVM[accountId][subId];
    int diff = latest - previous;
    if (diff == 0) return;

    accountLastCumulativeVM[accountId][subId] = latest;

    int cashDelta = position.multiplyDecimal(diff);
    if (cashDelta != 0) {
      accountCashToSettle[accountId][subId] += cashDelta;
    }

    emit FutureVMSynchronized(accountId, uint96(subId), cashDelta, latest);
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

  function getSubId(uint64 expiry) public pure returns (uint96) {
    return uint96(expiry);
  }

  function parseSubId(uint96 subId) external pure returns (uint64 expiry) {
    expiry = uint64(subId);
  }
}
