// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IPerpAsset} from "../interfaces/IPerpAsset.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {ILiquidatableManager} from "../interfaces/ILiquidatableManager.sol";
import {IBasePortfolioViewer} from "../interfaces/IBasePortfolioViewer.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {BaseManager} from "./BaseManager.sol";
import {SquaredPerpAsset} from "../assets/SquaredPerpAsset.sol";

/**
 * @title SquaredPerpManager
 * @author Lyra
 * @notice Isolated-risk manager for squared perps and adjacent perp books.
 *         It intentionally sums isolated requirements and does not apply portfolio offsets.
 */
contract SquaredPerpManager is ILiquidatableManager, BaseManager, ReentrancyGuard {
  using SafeCast for uint;
  using SafeCast for int;
  using DecimalMath for uint;
  using SignedDecimalMath for int;

  struct PerpRiskParams {
    bool isWhitelisted;
    bool isSquared;
    uint initialMarginRatio;
    uint maintenanceMarginRatio;
    uint initialMaxLeverage;
    uint maintenanceMaxLeverage;
    uint initialSpotShockUp;
    uint initialSpotShockDown;
    uint maintenanceSpotShockUp;
    uint maintenanceSpotShockDown;
  }

  mapping(IPerpAsset => PerpRiskParams) public perpRiskParams;
  IPerpAsset[] public supportedPerps;
  mapping(IPerpAsset => bool) internal isTrackedPerp;

  event PerpRiskParamsSet(address perp, bool isSquared);

  error SPM_UnsupportedAsset();
  error SPM_InvalidRiskParams();
  error SPM_OptionsNotSupported();
  error SPM_TooManyAssets();
  error SPM_PortfolioBelowMargin();

  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction liquidation_,
    IBasePortfolioViewer viewer_
  ) BaseManager(subAccounts_, cashAsset_, liquidation_, viewer_) {}

  function setPerpRiskParams(IPerpAsset perp, PerpRiskParams calldata params) external onlyOwner {
    if (
      params.maintenanceMarginRatio > params.initialMarginRatio
        || params.initialMarginRatio >= 1e18
        || params.maintenanceMarginRatio >= 1e18
        || params.initialMaxLeverage < 1e18
        || params.maintenanceMaxLeverage < 1e18
        || params.initialMaxLeverage > params.maintenanceMaxLeverage
        || params.initialSpotShockUp >= 1e18
        || params.initialSpotShockDown >= 1e18
        || params.maintenanceSpotShockUp >= 1e18
        || params.maintenanceSpotShockDown >= 1e18
    ) {
      revert SPM_InvalidRiskParams();
    }

    perpRiskParams[perp] = params;
    if (params.isWhitelisted && !isTrackedPerp[perp]) {
      supportedPerps.push(perp);
      isTrackedPerp[perp] = true;
    }

    emit PerpRiskParamsSet(address(perp), params.isSquared);
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

    bool needsRiskCheck = false;

    for (uint i = 0; i < assetDeltas.length; i++) {
      if (address(assetDeltas[i].asset) == address(cashAsset)) {
        if (assetDeltas[i].delta < 0) {
          needsRiskCheck = true;
        }
        continue;
      }

      PerpRiskParams memory params = perpRiskParams[IPerpAsset(address(assetDeltas[i].asset))];
      if (!params.isWhitelisted) revert SPM_UnsupportedAsset();

      _settlePerpRealizedPNL(IPerpAsset(address(assetDeltas[i].asset)), accountId);
      needsRiskCheck = true;
    }

    ISubAccounts.AssetBalance[] memory assetBalances = subAccounts.getAccountBalances(accountId);
    if (
      assetBalances.length > maxAccountSize
        && viewer.getPreviousAssetsLength(assetBalances, assetDeltas) < assetBalances.length
    ) {
      revert SPM_TooManyAssets();
    }

    if (!needsRiskCheck) return;
    _assessRisk(caller, accountId);
  }

  function settlePerpsWithIndex(uint accountId) external override {
    for (uint i = 0; i < supportedPerps.length; i++) {
      IPerpAsset perp = supportedPerps[i];
      if (!perpRiskParams[perp].isWhitelisted) continue;
      if (subAccounts.getBalance(accountId, perp, 0) == 0) continue;
      _settlePerpUnrealizedPNL(perp, accountId);
    }
  }

  function settleOptions(IOptionAsset, uint) external pure override {
    revert SPM_OptionsNotSupported();
  }

  function getMargin(uint accountId, bool isInitial) external view override returns (int margin) {
    (margin,) = _getMarginAndMarkToMarket(accountId, isInitial, 0);
  }

  function getMarginAndMarkToMarket(uint accountId, bool isInitial, uint scenarioId)
    external
    view
    override
    returns (int margin, int markToMarket)
  {
    return _getMarginAndMarkToMarket(accountId, isInitial, scenarioId);
  }

  function getIsolatedRisk(IPerpAsset perp, uint accountId, bool isInitial, uint scenarioId)
    external
    view
    returns (uint requirement, int unrealizedPnl, uint scenarioLoss)
  {
    int position = subAccounts.getBalance(accountId, perp, 0);
    PerpRiskParams memory params = perpRiskParams[perp];
    if (!params.isWhitelisted || position == 0) {
      return (0, 0, 0);
    }

    return _getPositionRisk(perp, params, position, accountId, isInitial, scenarioId);
  }

  function _assessRisk(address caller, uint accountId) internal view {
    if (trustedRiskAssessor[caller]) {
      (int postMM,) = _getMarginAndMarkToMarket(accountId, false, 0);
      if (postMM >= 0) return;
    } else {
      (int postIM,) = _getMarginAndMarkToMarket(accountId, true, 0);
      if (postIM >= 0) return;
    }

    revert SPM_PortfolioBelowMargin();
  }

  function _getMarginAndMarkToMarket(uint accountId, bool isInitial, uint scenarioId)
    internal
    view
    returns (int margin, int markToMarket)
  {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);

    for (uint i = 0; i < balances.length; i++) {
      ISubAccounts.AssetBalance memory balance = balances[i];
      if (address(balance.asset) == address(cashAsset)) {
        margin += balance.balance;
        continue;
      }

      IPerpAsset perp = IPerpAsset(address(balance.asset));
      PerpRiskParams memory params = perpRiskParams[perp];
      if (!params.isWhitelisted) revert SPM_UnsupportedAsset();

      (uint requirement, int unrealizedPnl,) =
        _getPositionRisk(perp, params, balance.balance, accountId, isInitial, scenarioId);
      margin += unrealizedPnl - requirement.toInt256();
      markToMarket += unrealizedPnl;
    }
  }

  function _getPositionRisk(
    IPerpAsset perp,
    PerpRiskParams memory params,
    int position,
    uint accountId,
    bool isInitial,
    uint scenarioId
  ) internal view returns (uint requirement, int unrealizedPnl, uint scenarioLoss) {
    if (position == 0) return (0, 0, 0);

    unrealizedPnl = perp.getUnsettledAndUnrealizedCash(accountId);

    (uint currentMark,) = perp.getPerpPrice();
    uint notional = SignedMath.abs(position).multiplyDecimal(currentMark);

    uint ratioRequirement = notional.multiplyDecimal(
      isInitial ? params.initialMarginRatio : params.maintenanceMarginRatio
    );
    uint leverageRequirement = notional.divideDecimal(
      isInitial ? params.initialMaxLeverage : params.maintenanceMaxLeverage
    );
    scenarioLoss = _getScenarioLoss(perp, params, position, isInitial, scenarioId, currentMark);

    requirement = ratioRequirement;
    if (leverageRequirement > requirement) requirement = leverageRequirement;
    if (scenarioLoss > requirement) requirement = scenarioLoss;
  }

  function _getScenarioLoss(
    IPerpAsset perp,
    PerpRiskParams memory params,
    int position,
    bool isInitial,
    uint scenarioId,
    uint currentMark
  ) internal view returns (uint) {
    if (scenarioId == 1) {
      return _getScenarioLossForDirection(perp, params, position, isInitial, true, currentMark);
    }
    if (scenarioId == 2) {
      return _getScenarioLossForDirection(perp, params, position, isInitial, false, currentMark);
    }

    uint lossUp = _getScenarioLossForDirection(perp, params, position, isInitial, true, currentMark);
    uint lossDown = _getScenarioLossForDirection(perp, params, position, isInitial, false, currentMark);
    return lossUp > lossDown ? lossUp : lossDown;
  }

  function _getScenarioLossForDirection(
    IPerpAsset perp,
    PerpRiskParams memory params,
    int position,
    bool isInitial,
    bool isUp,
    uint currentMark
  ) internal view returns (uint loss) {
    uint shock = _getShock(params, isInitial, isUp);
    if (shock == 0) return 0;

    uint shockedPrice = _getShockedPrice(perp, params, shock, isUp);
    int pnl = (shockedPrice.toInt256() - currentMark.toInt256()).multiplyDecimal(position);
    if (pnl < 0) {
      loss = (-pnl).toUint256();
    }
  }

  function _getShock(PerpRiskParams memory params, bool isInitial, bool isUp) internal pure returns (uint) {
    if (isInitial) {
      return isUp ? params.initialSpotShockUp : params.initialSpotShockDown;
    }
    return isUp ? params.maintenanceSpotShockUp : params.maintenanceSpotShockDown;
  }

  function _getShockedPrice(IPerpAsset perp, PerpRiskParams memory params, uint shock, bool isUp)
    internal
    view
    returns (uint)
  {
    if (params.isSquared) {
      (uint spotPrice,) = SquaredPerpAsset(address(perp)).spotFeed().getSpot();
      uint shockedUnderlying =
        isUp ? spotPrice.multiplyDecimal(DecimalMath.UNIT + shock) : spotPrice.multiplyDecimal(DecimalMath.UNIT - shock);
      return shockedUnderlying.multiplyDecimal(shockedUnderlying);
    }

    (uint indexPrice,) = perp.getIndexPrice();
    return isUp ? indexPrice.multiplyDecimal(DecimalMath.UNIT + shock) : indexPrice.multiplyDecimal(DecimalMath.UNIT - shock);
  }

  function _chargeAllOIFee(address caller, uint accountId, uint tradeId, ISubAccounts.AssetDelta[] memory assetDeltas)
    internal
    override
  {
    if (feeBypassedCaller[caller]) return;

    uint fee;
    for (uint i = 0; i < assetDeltas.length; i++) {
      if (address(assetDeltas[i].asset) == address(cashAsset)) continue;

      IPerpAsset perp = IPerpAsset(address(assetDeltas[i].asset));
      if (!perpRiskParams[perp].isWhitelisted) revert SPM_UnsupportedAsset();
      fee += _getPerpOIFee(perp, assetDeltas[i].delta, tradeId);
    }

    _payFee(accountId, fee);
  }
}
