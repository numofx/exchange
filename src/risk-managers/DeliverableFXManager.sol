// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IBasePortfolioViewer} from "../interfaces/IBasePortfolioViewer.sol";
import {IBaseManager} from "../interfaces/IBaseManager.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {ILiquidatableManager} from "../interfaces/ILiquidatableManager.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IDeliverableFXFutureAsset} from "../interfaces/IDeliverableFXFutureAsset.sol";
import {IStandardManager} from "../interfaces/IStandardManager.sol";
import {BaseManager} from "./BaseManager.sol";
import {DeliverableFXFutureAsset} from "../assets/DeliverableFXFutureAsset.sol";

contract DeliverableFXManager is ILiquidatableManager, BaseManager, ReentrancyGuard {
  using DecimalMath for uint;
  using SignedDecimalMath for int;
  using SafeCast for uint;

  struct MarginParams {
    uint normalIM;
    uint normalMM;
  }

  IDeliverableFXFutureAsset public futureAsset;
  IAsset public baseAsset;
  IAsset public quoteAsset;
  ISpotFeed public quoteSpotFeed;
  MarginParams public marginParams;

  mapping(uint accountId => mapping(IAsset asset => uint amount)) public reservedBalance;
  mapping(uint accountId => mapping(uint96 subId => bool settled)) public accountSettled;

  error DFXM_UnsupportedAsset();
  error DFXM_InvalidConfig();
  error DFXM_TooManyAssets();
  error DFXM_OptionsNotSupported();

  event DeliverableProductConfigured(address futureAsset, address baseAsset, address quoteAsset, address quoteSpotFeed);
  event DeliverableMarginParamsSet(uint normalIM, uint normalMM);

  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction liquidation_,
    IBasePortfolioViewer viewer_
  ) BaseManager(subAccounts_, cashAsset_, liquidation_, viewer_) {}

  function setProduct(
    IDeliverableFXFutureAsset futureAsset_,
    IAsset baseAsset_,
    IAsset quoteAsset_,
    ISpotFeed quoteSpotFeed_
  ) external onlyOwner {
    if (
      address(futureAsset_) == address(0) || address(baseAsset_) == address(0) || address(quoteAsset_) == address(0)
        || address(quoteSpotFeed_) == address(0)
    ) {
      revert DFXM_InvalidConfig();
    }

    futureAsset = futureAsset_;
    baseAsset = baseAsset_;
    quoteAsset = quoteAsset_;
    quoteSpotFeed = quoteSpotFeed_;

    emit DeliverableProductConfigured(address(futureAsset_), address(baseAsset_), address(quoteAsset_), address(quoteSpotFeed_));
  }

  function setMarginParams(uint normalIM, uint normalMM) external onlyOwner {
    if (normalMM > normalIM || normalIM >= 1e18 || normalMM >= 1e18) revert DFXM_InvalidConfig();
    marginParams = MarginParams({normalIM: normalIM, normalMM: normalMM});
    emit DeliverableMarginParamsSet(normalIM, normalMM);
  }

  function handleAdjustment(
    uint accountId,
    uint tradeId,
    address caller,
    ISubAccounts.AssetDelta[] memory assetDeltas,
    bytes calldata managerData
  ) external override onlyAccounts nonReentrant {
    _preAdjustmentHooks(accountId, tradeId, caller, assetDeltas, managerData);
    _checkIfLiveAuction(accountId);

    _settleAllDeliverableFXVM(accountId);
    _refreshReservations(accountId);

    bool needsRiskCheck;

    for (uint i = 0; i < assetDeltas.length; ++i) {
      IAsset asset = assetDeltas[i].asset;
      int delta = assetDeltas[i].delta;

      if (address(asset) == address(cashAsset)) {
        if (delta < 0) needsRiskCheck = true;
        continue;
      }

      if (asset == baseAsset || asset == quoteAsset) {
        if (delta < 0) needsRiskCheck = true;
        continue;
      }

      if (asset != IAsset(address(futureAsset))) revert DFXM_UnsupportedAsset();

      int currentPosition = subAccounts.getBalance(accountId, futureAsset, assetDeltas[i].subId);
      if (currentPosition == 0 || currentPosition * delta > 0) {
        needsRiskCheck = true;
      }
    }

    _checkAllDeliverableSufficiency(accountId);

    ISubAccounts.AssetBalance[] memory assetBalances = subAccounts.getAccountBalances(accountId);
    if (
      assetBalances.length > maxAccountSize
        && viewer.getPreviousAssetsLength(assetBalances, assetDeltas) < assetBalances.length
    ) {
      revert DFXM_TooManyAssets();
    }

    if (!needsRiskCheck) return;
    _assessRisk(caller, accountId);
  }

  function settlePerpsWithIndex(uint) external pure override {}

  function settleOptions(IOptionAsset, uint) external pure override {
    revert DFXM_OptionsNotSupported();
  }

  function getMargin(uint accountId, bool isInitial) external view override returns (int margin) {
    (margin,) = _getMarginAndMarkToMarket(accountId, isInitial);
  }

  function getMarginAndMarkToMarket(uint accountId, bool isInitial, uint)
    external
    view
    override
    returns (int margin, int markToMarket)
  {
    return _getMarginAndMarkToMarket(accountId, isInitial);
  }

  function refreshDeliverableReservation(IDeliverableFXFutureAsset future, uint accountId, uint96 subId) public {
    if (future != futureAsset) revert DFXM_UnsupportedAsset();
    _settleDeliverableFXVM(accountId, subId);
    _refreshReservations(accountId);
  }

  function canSettleDeliverableFuture(IDeliverableFXFutureAsset future, uint accountId, uint96 subId)
    public
    view
    returns (bool)
  {
    if (future != futureAsset) return false;
    if (accountSettled[accountId][subId]) return false;

    (int position, uint baseAmount, uint quoteAmount) = _getDeliveryAmounts(accountId, subId, true);
    if (position == 0) return false;

    IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(subId);
    if (!series.settlementPriceSet || block.timestamp < series.expiry) return false;

    if (!_hasAggregateDeliverableSufficiency(accountId)) return false;

    if (position > 0) {
      return _getManagerTokenBalance(baseAsset) >= int(baseAmount);
    }
    return _getManagerTokenBalance(quoteAsset) >= int(quoteAmount);
  }

  function settleDeliverableFuture(IDeliverableFXFutureAsset future, uint accountId, uint96 subId) public nonReentrant {
    if (future != futureAsset) revert DFXM_UnsupportedAsset();

    IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(subId);
    if (block.timestamp < series.expiry || !series.settlementPriceSet) revert IStandardManager.SRM_UnsupportedAsset();
    if (accountSettled[accountId][subId]) revert IStandardManager.SRM_UnsupportedAsset();

    _settleDeliverableFXVM(accountId, subId);

    (int position, uint baseAmount, uint quoteAmount) = _getDeliveryAmounts(accountId, subId, true);
    if (position == 0) revert IStandardManager.SRM_UnsupportedAsset();

    _refreshReservations(accountId);
    if (!_hasAggregateDeliverableSufficiency(accountId)) {
      revert IStandardManager.SRM_PortfolioBelowMargin();
    }

    if (position > 0) {
      if (_getManagerTokenBalance(baseAsset) < int(baseAmount)) revert IStandardManager.SRM_PortfolioBelowMargin();
    } else if (_getManagerTokenBalance(quoteAsset) < int(quoteAmount)) {
      revert IStandardManager.SRM_PortfolioBelowMargin();
    }

    IAsset owedAsset = position > 0 ? quoteAsset : baseAsset;
    if (reservedBalance[accountId][owedAsset] < (position > 0 ? quoteAmount : baseAmount)) {
      revert IStandardManager.SRM_PortfolioBelowMargin();
    }

    int fullPosition = subAccounts.getBalance(accountId, futureAsset, subId);
    subAccounts.managerAdjustment(ISubAccounts.AssetAdjustment(accountId, futureAsset, subId, -fullPosition, bytes32(0)));
    accountSettled[accountId][subId] = true;
    _refreshReservations(accountId);

    if (position > 0) {
      _symmetricManagerAdjustment(accountId, accId, quoteAsset, 0, int(quoteAmount));
      _symmetricManagerAdjustment(accId, accountId, baseAsset, 0, int(baseAmount));
    } else {
      _symmetricManagerAdjustment(accountId, accId, baseAsset, 0, int(baseAmount));
      _symmetricManagerAdjustment(accId, accountId, quoteAsset, 0, int(quoteAmount));
    }
  }

  function settleAllExpiredDeliverableFutures(uint accountId) external {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset))) continue;
      uint96 subId = uint96(balances[i].subId);
      if (canSettleDeliverableFuture(futureAsset, accountId, subId)) {
        settleDeliverableFuture(futureAsset, accountId, subId);
      }
    }
  }

  function executeBid(uint accountId, uint liquidatorId, uint portion, uint bidAmount, uint reservedCash)
    external
    override(IBaseManager, BaseManager)
    onlyLiquidations
  {
    _settleAllDeliverableFXVM(accountId);
    _settleAllDeliverableFXVM(liquidatorId);

    _executeBid(accountId, liquidatorId, portion, bidAmount, reservedCash);

    _refreshReservations(accountId);
    _refreshReservations(liquidatorId);
    _checkAllDeliverableSufficiency(liquidatorId);
  }

  function _chargeAllOIFee(address, uint, uint, ISubAccounts.AssetDelta[] memory) internal override {}

  function _assessRisk(address caller, uint accountId) internal view {
    if (trustedRiskAssessor[caller]) {
      (int postMM,) = _getMarginAndMarkToMarket(accountId, false);
      if (postMM >= 0) return;
    } else {
      (int postIM,) = _getMarginAndMarkToMarket(accountId, true);
      if (postIM >= 0) return;
    }

    revert IStandardManager.SRM_PortfolioBelowMargin();
  }

  function _getMarginAndMarkToMarket(uint accountId, bool isInitial) internal view returns (int margin, int markToMarket) {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    uint quotePrice = _getQuotePrice();
    uint requirementRatio = isInitial ? marginParams.normalIM : marginParams.normalMM;

    for (uint i = 0; i < balances.length; ++i) {
      ISubAccounts.AssetBalance memory balance = balances[i];
      if (address(balance.asset) == address(cashAsset)) {
        margin += balance.balance;
        markToMarket += balance.balance;
        continue;
      }

      if (balance.asset == baseAsset) {
        margin += balance.balance;
        markToMarket += balance.balance;
        continue;
      }

      if (balance.asset == quoteAsset) {
        int quoteValue = _quoteToCash(balance.balance, quotePrice);
        margin += quoteValue;
        markToMarket += quoteValue;
        continue;
      }

      if (balance.asset != IAsset(address(futureAsset))) revert DFXM_UnsupportedAsset();

      IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(uint96(balance.subId));
      uint baseNotional = (SignedMath.abs(balance.balance) * uint(series.contractSizeBase)) / 1e18;
      margin -= int(baseNotional.multiplyDecimal(requirementRatio));

      int pendingCash = _getPendingVM(accountId, uint96(balance.subId), balance.balance);
      margin += pendingCash;
      markToMarket += pendingCash;

    }

    (uint totalBaseRequired, uint totalQuoteRequired) = _getAggregateDeliveryRequirements(accountId, false);
    uint shortage = _getAggregateDeliveryShortage(accountId, totalBaseRequired, totalQuoteRequired, quotePrice);
    if (shortage != 0) {
      margin = SignedMath.min(margin, -int(shortage));
    }
  }

  function _settleAllDeliverableFXVM(uint accountId) internal {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset))) continue;
      _settleDeliverableFXVM(accountId, uint96(balances[i].subId));
    }
  }

  function _settleDeliverableFXVM(uint accountId, uint96 subId) internal {
    int cashDelta = futureAsset.settleAccountVM(accountId, subId);
    _applyCashDelta(accountId, cashDelta);
  }

  function _refreshReservations(uint accountId) internal {
    uint totalBaseRequired;
    uint totalQuoteRequired;

    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset))) continue;

      (int position, uint baseAmount, uint quoteAmount) = _getDeliveryAmounts(accountId, uint96(balances[i].subId), false);
      if (position > 0) {
        totalQuoteRequired += quoteAmount;
      } else if (position < 0) {
        totalBaseRequired += baseAmount;
      }
    }

    reservedBalance[accountId][baseAsset] = totalBaseRequired;
    reservedBalance[accountId][quoteAsset] = totalQuoteRequired;
  }

  function _checkAllDeliverableSufficiency(uint accountId) internal view {
    if (!_hasAggregateDeliverableSufficiency(accountId)) {
      revert IStandardManager.SRM_PortfolioBelowMargin();
    }
  }

  function _hasAggregateDeliverableSufficiency(uint accountId) internal view returns (bool) {
    (uint totalBaseRequired, uint totalQuoteRequired) = _getAggregateDeliveryRequirements(accountId, false);
    if (totalBaseRequired == 0 && totalQuoteRequired == 0) return true;

    int totalBaseBalance = subAccounts.getBalance(accountId, baseAsset, 0);
    int totalQuoteBalance = subAccounts.getBalance(accountId, quoteAsset, 0);

    return totalBaseBalance >= 0 && uint(totalBaseBalance) >= totalBaseRequired
      && totalQuoteBalance >= 0 && uint(totalQuoteBalance) >= totalQuoteRequired
      && reservedBalance[accountId][baseAsset] >= totalBaseRequired
      && reservedBalance[accountId][quoteAsset] >= totalQuoteRequired;
  }

  function _getAggregateDeliveryRequirements(uint accountId, bool requireSettlementPrice)
    internal
    view
    returns (uint totalBaseRequired, uint totalQuoteRequired)
  {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset))) continue;

      IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(uint96(balances[i].subId));
      if (block.timestamp < series.lastTradeTime) continue;

      (int position, uint baseAmount, uint quoteAmount) =
        _getDeliveryAmounts(accountId, uint96(balances[i].subId), requireSettlementPrice);
      if (position > 0) {
        totalQuoteRequired += quoteAmount;
      } else if (position < 0) {
        totalBaseRequired += baseAmount;
      }
    }
  }

  function _getDeliveryAmounts(uint accountId, uint96 subId, bool requireSettlementPrice)
    internal
    view
    returns (int position, uint baseAmount, uint quoteAmount)
  {
    position = subAccounts.getBalance(accountId, futureAsset, subId);
    IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(subId);
    baseAmount = (SignedMath.abs(position) * uint(series.contractSizeBase)) / 1e18;

    uint price = series.settlementPriceSet ? uint(series.settlementPrice) : uint(series.markPrice);
    if (requireSettlementPrice && !series.settlementPriceSet) {
      price = 0;
    }
    quoteAmount = (baseAmount * price) / 1e18;
  }

  function _getPendingVM(uint accountId, uint96 subId, int position) internal view returns (int) {
    IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(subId);
    DeliverableFXFutureAsset future = DeliverableFXFutureAsset(address(futureAsset));
    int latest = series.cumulativeVMPerContract;
    int previous = future.accountLastCumulativeVM(accountId, subId);
    int pending = future.accountCashToSettle(accountId, subId);
    return pending + (position * (latest - previous)) / 1e18;
  }

  function _getAggregateDeliveryShortage(uint accountId, uint totalBaseRequired, uint totalQuoteRequired, uint quotePrice)
    internal
    view
    returns (uint shortage)
  {
    int baseBalance = subAccounts.getBalance(accountId, baseAsset, 0);
    if (baseBalance < 0 || uint(baseBalance) < totalBaseRequired) {
      uint baseShortfall = baseBalance < 0 ? totalBaseRequired : totalBaseRequired - uint(baseBalance);
      shortage += baseShortfall;
    }

    int quoteBalance = subAccounts.getBalance(accountId, quoteAsset, 0);
    if (quoteBalance < 0 || uint(quoteBalance) < totalQuoteRequired) {
      uint quoteShortfall = quoteBalance < 0 ? totalQuoteRequired : totalQuoteRequired - uint(quoteBalance);
      shortage += quoteShortfall.divideDecimal(quotePrice);
    }

    if (shortage == 0 && (totalBaseRequired != 0 || totalQuoteRequired != 0)) {
      return 0;
    }
  }

  function _quoteToCash(int quoteBalance, uint quotePrice) internal pure returns (int) {
    if (quoteBalance == 0) return 0;

    uint absBalance = SignedMath.abs(quoteBalance);
    int cashValue = absBalance.divideDecimal(quotePrice).toInt256();
    return quoteBalance > 0 ? cashValue : -cashValue;
  }

  function _getQuotePrice() internal view returns (uint quotePrice) {
    (quotePrice,) = quoteSpotFeed.getSpot();
    if (quotePrice == 0) revert DFXM_InvalidConfig();
  }

  function _getManagerTokenBalance(IAsset asset) internal view returns (int) {
    return subAccounts.getBalance(accId, asset, 0);
  }
}
