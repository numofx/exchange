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
import {IManager} from "../interfaces/IManager.sol";
import {BaseManager} from "./BaseManager.sol";
import {DeliverableFXFutureAsset} from "../assets/DeliverableFXFutureAsset.sol";

contract DeliverableFXManager is ILiquidatableManager, BaseManager, ReentrancyGuard {
  using DecimalMath for uint;
  using SignedDecimalMath for int;
  using SafeCast for uint;
  using SafeCast for int;

  struct MarginParams {
    uint normalIM;
    uint normalMM;
  }

  struct LifecycleParams {
    uint64 rampDuration;
    uint rampIM;
    uint rampMM;
  }

  struct PositionLimitParams {
    uint maxSeriesNotional;
    uint maxAccountNotional;
    uint maxAccountLongNotional;
    uint maxAccountShortNotional;
    uint maxMarketOI;
    uint maxMarketLongOI;
    uint maxMarketShortOI;
  }

  struct DeliveryReadiness {
    bool ready;
    bool inDeliveryPhase;
    uint requiredBase;
    uint requiredQuote;
    uint reservedBase;
    uint reservedQuote;
    uint availableBase;
    uint availableQuote;
    uint freeBase;
    uint freeQuote;
    uint baseBalanceShortfall;
    uint quoteBalanceShortfall;
    uint baseReservationShortfall;
    uint quoteReservationShortfall;
  }

  IDeliverableFXFutureAsset public futureAsset;
  IAsset public baseAsset;
  IAsset public quoteAsset;
  ISpotFeed public quoteSpotFeed;
  MarginParams public marginParams;
  LifecycleParams public lifecycleParams;
  PositionLimitParams public positionLimits;

  mapping(uint accountId => mapping(IAsset asset => uint amount)) public reservedBalance;
  mapping(uint accountId => mapping(uint96 subId => bool settled)) public accountSettled;

  error DFXM_UnsupportedAsset();
  error DFXM_InvalidConfig();
  error DFXM_TooManyAssets();
  error DFXM_OptionsNotSupported();
  error DFXM_LeverageIncreaseBlocked();
  error DFXM_PositionLimitExceeded();
  error DFXM_DeliveryReadinessNotImproved();

  event DeliverableProductConfigured(address futureAsset, address baseAsset, address quoteAsset, address quoteSpotFeed);
  event DeliverableMarginParamsSet(uint normalIM, uint normalMM);
  event DeliverableLifecycleParamsSet(uint64 rampDuration, uint rampIM, uint rampMM);
  event DeliverablePositionLimitsSet(
    uint maxSeriesNotional,
    uint maxAccountNotional,
    uint maxAccountLongNotional,
    uint maxAccountShortNotional,
    uint maxMarketOI,
    uint maxMarketLongOI,
    uint maxMarketShortOI
  );

  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction liquidation_,
    IBasePortfolioViewer viewer_
  ) BaseManager(subAccounts_, cashAsset_, liquidation_, viewer_) {
    lifecycleParams = LifecycleParams({rampDuration: 3 days, rampIM: 1e18, rampMM: 1e18});
    positionLimits = PositionLimitParams({
      maxSeriesNotional: type(uint).max,
      maxAccountNotional: type(uint).max,
      maxAccountLongNotional: type(uint).max,
      maxAccountShortNotional: type(uint).max,
      maxMarketOI: type(uint).max,
      maxMarketLongOI: type(uint).max,
      maxMarketShortOI: type(uint).max
    });
  }

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

  function setLifecycleParams(uint64 rampDuration, uint rampIM, uint rampMM) external onlyOwner {
    if (rampDuration == 0 || rampMM > rampIM || rampIM < marginParams.normalIM || rampMM < marginParams.normalMM || rampIM > 1e18)
    {
      revert DFXM_InvalidConfig();
    }

    lifecycleParams = LifecycleParams({rampDuration: rampDuration, rampIM: rampIM, rampMM: rampMM});
    emit DeliverableLifecycleParamsSet(rampDuration, rampIM, rampMM);
  }

  function setPositionLimits(
    uint maxSeriesNotional,
    uint maxAccountNotional,
    uint maxAccountLongNotional,
    uint maxAccountShortNotional,
    uint maxMarketOI,
    uint maxMarketLongOI,
    uint maxMarketShortOI
  ) external onlyOwner {
    if (
      maxSeriesNotional == 0 || maxAccountNotional < maxSeriesNotional || maxAccountLongNotional == 0
        || maxAccountShortNotional == 0 || maxAccountLongNotional > maxAccountNotional
        || maxAccountShortNotional > maxAccountNotional || maxMarketOI == 0 || maxMarketLongOI == 0
        || maxMarketShortOI == 0 || maxMarketLongOI > maxMarketOI || maxMarketShortOI > maxMarketOI
    ) revert DFXM_InvalidConfig();
    positionLimits = PositionLimitParams({
      maxSeriesNotional: maxSeriesNotional,
      maxAccountNotional: maxAccountNotional,
      maxAccountLongNotional: maxAccountLongNotional,
      maxAccountShortNotional: maxAccountShortNotional,
      maxMarketOI: maxMarketOI,
      maxMarketLongOI: maxMarketLongOI,
      maxMarketShortOI: maxMarketShortOI
    });
    emit DeliverablePositionLimitsSet(
      maxSeriesNotional,
      maxAccountNotional,
      maxAccountLongNotional,
      maxAccountShortNotional,
      maxMarketOI,
      maxMarketLongOI,
      maxMarketShortOI
    );
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
    DeliveryReadiness memory readinessBefore = _getDeliveryReadiness(accountId);

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
      IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(uint96(assetDeltas[i].subId));
      if (_isInRamp(series) && _increasesAbsoluteExposure(currentPosition, assetDeltas[i].delta)) {
        revert DFXM_LeverageIncreaseBlocked();
      }
      if (currentPosition == 0 || currentPosition * delta > 0) {
        needsRiskCheck = true;
      }
    }

    ISubAccounts.AssetBalance[] memory assetBalances = subAccounts.getAccountBalances(accountId);
    _checkPositionLimits(assetBalances);
    if (
      assetBalances.length > maxAccountSize
        && viewer.getPreviousAssetsLength(assetBalances, assetDeltas) < assetBalances.length
    ) {
      revert DFXM_TooManyAssets();
    }

    DeliveryReadiness memory readinessAfter = _getDeliveryReadiness(accountId);
    if (readinessAfter.inDeliveryPhase && !readinessAfter.ready) {
      revert IStandardManager.SRM_PortfolioBelowMargin();
    }

    if (!needsRiskCheck) return;
    if (!readinessBefore.inDeliveryPhase) {
      _assessRisk(caller, accountId);
    }
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

  function isDeliveryReady(uint accountId) external view returns (bool) {
    return _getDeliveryReadiness(accountId).ready;
  }

  function getDeliveryReadiness(uint accountId) external view returns (DeliveryReadiness memory) {
    return _getDeliveryReadiness(accountId);
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
    DeliveryReadiness memory accountReadinessBefore = _getDeliveryReadiness(accountId);
    _settleAllDeliverableFXVM(accountId);
    _settleAllDeliverableFXVM(liquidatorId);

    _executeBid(accountId, liquidatorId, portion, bidAmount, reservedCash);

    _refreshReservations(accountId);
    _refreshReservations(liquidatorId);
    _checkAllDeliverableSufficiency(liquidatorId);

    DeliveryReadiness memory accountReadinessAfter = _getDeliveryReadiness(accountId);
    if (
      accountReadinessBefore.inDeliveryPhase && !accountReadinessBefore.ready && !accountReadinessAfter.ready
        && _totalDeliveryShortfall(accountReadinessAfter) >= _totalDeliveryShortfall(accountReadinessBefore)
    ) {
      revert DFXM_DeliveryReadinessNotImproved();
    }
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
      uint requirementRatio = _getMarginRequirementRatio(series, isInitial);
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
    if (!_getDeliveryReadiness(accountId).ready) {
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

  function _getMarginRequirementRatio(IDeliverableFXFutureAsset.Series memory series, bool isInitial)
    internal
    view
    returns (uint)
  {
    uint normalRatio = isInitial ? marginParams.normalIM : marginParams.normalMM;
    uint rampRatio = isInitial ? lifecycleParams.rampIM : lifecycleParams.rampMM;

    if (block.timestamp >= series.lastTradeTime) {
      return rampRatio;
    }

    uint64 rampDuration = lifecycleParams.rampDuration;
    if (rampDuration == 0 || series.lastTradeTime <= rampDuration) return normalRatio;

    uint64 rampStart = series.lastTradeTime - rampDuration;
    if (block.timestamp <= rampStart || rampRatio <= normalRatio) return normalRatio;

    uint elapsed = block.timestamp - rampStart;
    return normalRatio + ((rampRatio - normalRatio) * elapsed) / rampDuration;
  }

  function _getDeliveryReadiness(uint accountId) internal view returns (DeliveryReadiness memory readiness) {
    (uint requiredBase, uint requiredQuote) = _getAggregateDeliveryRequirements(accountId, false);
    uint reservedBase = reservedBalance[accountId][baseAsset];
    uint reservedQuote = reservedBalance[accountId][quoteAsset];
    uint availableBase = _getPositiveBalance(accountId, baseAsset);
    uint availableQuote = _getPositiveBalance(accountId, quoteAsset);
    uint freeBase = availableBase > reservedBase ? availableBase - reservedBase : 0;
    uint freeQuote = availableQuote > reservedQuote ? availableQuote - reservedQuote : 0;

    readiness = DeliveryReadiness({
      ready: false,
      inDeliveryPhase: _hasFrozenSeries(accountId),
      requiredBase: requiredBase,
      requiredQuote: requiredQuote,
      reservedBase: reservedBase,
      reservedQuote: reservedQuote,
      availableBase: availableBase,
      availableQuote: availableQuote,
      freeBase: freeBase,
      freeQuote: freeQuote,
      baseBalanceShortfall: availableBase >= requiredBase ? 0 : requiredBase - availableBase,
      quoteBalanceShortfall: availableQuote >= requiredQuote ? 0 : requiredQuote - availableQuote,
      baseReservationShortfall: reservedBase >= requiredBase ? 0 : requiredBase - reservedBase,
      quoteReservationShortfall: reservedQuote >= requiredQuote ? 0 : requiredQuote - reservedQuote
    });

    readiness.ready = readiness.baseBalanceShortfall == 0 && readiness.quoteBalanceShortfall == 0
      && readiness.baseReservationShortfall == 0 && readiness.quoteReservationShortfall == 0;
  }

  function _hasFrozenSeries(uint accountId) internal view returns (bool) {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset)) || balances[i].balance == 0) continue;
      IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(uint96(balances[i].subId));
      if (block.timestamp >= series.lastTradeTime) return true;
    }
    return false;
  }

  function _isInRamp(IDeliverableFXFutureAsset.Series memory series) internal view returns (bool) {
    if (block.timestamp >= series.lastTradeTime) return false;
    uint64 rampDuration = lifecycleParams.rampDuration;
    if (rampDuration == 0 || series.lastTradeTime <= rampDuration) return false;
    return block.timestamp >= series.lastTradeTime - rampDuration;
  }

  function _increasesAbsoluteExposure(int currentPosition, int delta) internal pure returns (bool) {
    if (delta == 0) return false;
    int nextPosition = currentPosition + delta;
    return SignedMath.abs(nextPosition) > SignedMath.abs(currentPosition);
  }

  function _checkPositionLimits(ISubAccounts.AssetBalance[] memory balances) internal view {
    uint totalAccountNotional;
    uint accountLongNotional;
    uint accountShortNotional;
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(futureAsset)) || balances[i].balance == 0) continue;
      IDeliverableFXFutureAsset.Series memory series = futureAsset.getSeries(uint96(balances[i].subId));
      uint seriesNotional = (SignedMath.abs(balances[i].balance) * uint(series.contractSizeBase)) / 1e18;
      if (seriesNotional > positionLimits.maxSeriesNotional) revert DFXM_PositionLimitExceeded();
      totalAccountNotional += seriesNotional;
      if (balances[i].balance > 0) {
        accountLongNotional += seriesNotional;
      } else {
        accountShortNotional += seriesNotional;
      }
    }

    if (totalAccountNotional > positionLimits.maxAccountNotional) revert DFXM_PositionLimitExceeded();
    if (accountLongNotional > positionLimits.maxAccountLongNotional) revert DFXM_PositionLimitExceeded();
    if (accountShortNotional > positionLimits.maxAccountShortNotional) revert DFXM_PositionLimitExceeded();
    if (futureAsset.totalPosition(IManager(address(this))) > positionLimits.maxMarketOI) revert DFXM_PositionLimitExceeded();
    if (futureAsset.totalLongPosition(IManager(address(this))) > positionLimits.maxMarketLongOI) {
      revert DFXM_PositionLimitExceeded();
    }
    if (futureAsset.totalShortPosition(IManager(address(this))) > positionLimits.maxMarketShortOI) {
      revert DFXM_PositionLimitExceeded();
    }
  }

  function _getPositiveBalance(uint accountId, IAsset asset) internal view returns (uint) {
    int balance = subAccounts.getBalance(accountId, asset, 0);
    if (balance <= 0) return 0;
    return uint(balance);
  }

  function _totalDeliveryShortfall(DeliveryReadiness memory readiness) internal pure returns (uint) {
    return readiness.baseBalanceShortfall + readiness.quoteBalanceShortfall + readiness.baseReservationShortfall
      + readiness.quoteReservationShortfall;
  }
}
