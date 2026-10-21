// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/utils/math/Math.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";
import "lyra-utils/arrays/UnorderedMemoryArray.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IPerpAsset} from "../interfaces/IPerpAsset.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {IERC20BasedAsset} from "../interfaces/IERC20BasedAsset.sol";
import {IBaseManager} from "../interfaces/IBaseManager.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IMarginEnginePortfolioViewer} from "../interfaces/IMarginEnginePortfolioViewer.sol";
import {IForwardFeed} from "../interfaces/IForwardFeed.sol";
import {IVolFeed} from "../interfaces/IVolFeed.sol";
import {ILiquidatableManager} from "../interfaces/ILiquidatableManager.sol";

import {IDutchAuction} from "../interfaces/IDutchAuction.sol";

import {ISpotFeed} from "../interfaces/ISpotFeed.sol";

import {IManager} from "../interfaces/IManager.sol";
import {BaseManager} from "./BaseManager.sol";
import {MarginEngineOptionHelper as OptionMarginHelper} from "./MarginEngineOptionHelper.sol";
import {FutureVMLib} from "../libraries/FutureVMLib.sol";

/**
 * @title MarginEngine
 * @author Lyra (StandardManager), forked by Numo
 * @notice A fork of StandardManager that margins spot (the base asset), perps, options and American-terms dated futures
 *         (FutureAsset v2: USDC per cNGN, a cNGN contract, VM in USDC) in one account. Each market is margined as in
 *         StandardManager; positions are margined gross (no offsets).
 * @dev    v2. The v1 engine deployed at 0xA19E… (cNGN-per-USDC futures, VM in cNGN) is src/legacy/v1/MarginEngineV1.
 *         The fork's changes, against StandardManager:
 *         - The dated-future type is FutureAsset. Its VM moves as cash through this manager's pool account `accId`
 *           (FutureVMLib), and its notional is |position| x contractSize x mark.
 *         - Views count unsettled VM, as StandardManager counts unrealised perp PnL: at par.
 *         - VM is realised before every risk check, before an auction prices or takes a bid on an account (the auction
 *           calls settlePerpsWithIndex), by anyone through settleAccount, and at expiry by closeOutExpired at the
 *           settlement price. A bidder's VM on what it takes accrues in FutureAsset and is counted by the views.
 *         - A trade that only reduces futures is held to maintenance margin, so an account can always deleverage.
 *         - The viewer skips assets a trade did not touch in the cap check (MarginEnginePortfolioViewer).
 *         - The VM pool `accId` may run negative in cash: it is not risk checked, never auctioned, and so never blocks a
 *           transfer the engine makes through it (a liquidation fee, cash to an account under another manager).
 */
contract MarginEngine is IMarginEngine, ILiquidatableManager, BaseManager, ReentrancyGuard {
  using SignedDecimalMath for int;
  using DecimalMath for uint;
  using SafeCast for uint;
  using SafeCast for int;
  using UnorderedMemoryArray for uint[];

  ///////////////
  // Variables //
  ///////////////

  /// @dev if turned on, people can borrow cash from standard manager, aka have negative balance.
  bool public borrowingEnabled;

  /// @dev Increasing Market Id
  uint public lastMarketId = 0;

  /// @dev Oracle that returns stable / USD price
  ISpotFeed public stableFeed;

  /// @dev Depeg IM parameters: use to increase margin requirement if stablecoin depegs
  DepegParams public depegParams;

  /// @dev True if an IAsset address is whitelisted.
  mapping(IAsset asset => AssetDetail) internal _assetDetails;

  /// @dev Mapping from marketId to asset type to IAsset address
  mapping(uint marketId => mapping(AssetType assetType => IAsset)) public assetMap;

  /// @dev Perp Margin Requirements: maintenance and initial margin requirements
  mapping(uint marketId => PerpMarginRequirements) public perpMarginRequirements;

  /// @dev Dated futures margin requirements
  mapping(uint marketId => FutureMarginRequirements) public futureMarginRequirements;

  OptionMarginHelper internal immutable optionMarginHelper;

  /// @dev Option Margin Parameters. See getIsolatedMargin for how it is used in the formula
  mapping(uint marketId => OptionMarginParams) public optionMarginParams;

  /// @dev Base margin factor: each base asset be treated as "spot * discount_factor" amount of cash
  mapping(uint marketId => BaseMarginParams) public baseMarginParams;

  /// @dev Oracle Contingency parameters. used to increase margin requirement if oracle has low confidence
  mapping(uint marketId => OracleContingencyParams) public oracleContingencyParams;

  /// @dev Mapping from marketId to spot price oracle
  mapping(uint marketId => ISpotFeed) internal spotFeeds;

  /// @dev Mapping from marketId to forward price oracle
  mapping(uint marketId => IForwardFeed) internal forwardFeeds;

  /// @dev Mapping from marketId to vol oracle
  mapping(uint marketId => IVolFeed) internal volFeeds;

  ////////////////////////
  //    Constructor     //
  ////////////////////////

  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction _dutchAuction,
    IMarginEnginePortfolioViewer _viewer
  ) BaseManager(subAccounts_, cashAsset_, _dutchAuction, _viewer) {
    optionMarginHelper = new OptionMarginHelper();
  }

  ///////////////////////
  //    Owner-Only     //
  ///////////////////////

  function createMarket(string calldata _marketName) external onlyOwner returns (uint marketId) {
    marketId = ++lastMarketId;
    emit MarketCreated(marketId, _marketName);
  }

  /**
   * @notice Whitelist an asset to be used in Manager
   * @dev the standard manager supports option, perp, base, and dated futures assets
   */
  function whitelistAsset(IAsset _asset, uint _marketId, AssetType _type) external onlyOwner {
    _checkMarketExist(_marketId);

    IAsset previousAsset = assetMap[_marketId][_type];
    AssetDetail memory previousDetails = _assetDetails[previousAsset];

    delete _assetDetails[previousAsset];
    delete assetMap[previousDetails.marketId][previousDetails.assetType];

    _assetDetails[_asset] = AssetDetail({isWhitelisted: true, marketId: _marketId, assetType: _type});

    assetMap[_marketId][_type] = _asset;

    emit AssetWhitelisted(address(_asset), _marketId, _type);
  }

  /**
   * @notice enable borrowing (negative cash balance) for standard manager
   */
  function setBorrowingEnabled(bool enabled) external onlyOwner {
    borrowingEnabled = enabled;

    emit BorrowingEnabled(enabled);
  }

  /**
   * @notice Set the oracles for a market id
   */
  function setOraclesForMarket(uint marketId, ISpotFeed spotFeed, IForwardFeed forwardFeed, IVolFeed volFeed)
    external
    onlyOwner
  {
    _checkMarketExist(marketId);

    spotFeeds[marketId] = spotFeed;
    forwardFeeds[marketId] = forwardFeed;
    volFeeds[marketId] = volFeed;

    emit OraclesSet(marketId, address(spotFeed), address(forwardFeed), address(volFeed));
  }

  /**
   * @notice Set perp maintenance margin requirement for an market
   * @param _mmPerpReq new maintenance margin requirement
   * @param _imPerpReq new initial margin requirement
   */
  function setPerpMarginRequirements(uint marketId, uint _mmPerpReq, uint _imPerpReq) external onlyOwner {
    _checkMarketExist(marketId);

    if (_mmPerpReq > _imPerpReq || _mmPerpReq == 0 || _mmPerpReq >= 1e18 || _imPerpReq >= 1e18) {
      revert SRM_InvalidPerpMarginParams();
    }

    perpMarginRequirements[marketId] = PerpMarginRequirements(_mmPerpReq, _imPerpReq);

    emit PerpMarginRequirementsSet(marketId, _mmPerpReq, _imPerpReq);
  }

  /**
   * @notice Set dated futures maintenance and initial margin requirement for a market
   */
  function setFutureMarginRequirements(uint marketId, uint _mmFutureReq, uint _imFutureReq) external onlyOwner {
    _checkMarketExist(marketId);

    if (_mmFutureReq > _imFutureReq || _mmFutureReq == 0 || _mmFutureReq >= 1e18 || _imFutureReq >= 1e18) {
      revert SRM_InvalidPerpMarginParams();
    }

    futureMarginRequirements[marketId] = FutureMarginRequirements(_mmFutureReq, _imFutureReq);

    emit FutureMarginRequirementsSet(marketId, _mmFutureReq, _imFutureReq);
  }

  /**
   * @dev Set discount factor for base asset
   * @dev if this factor is 0 (unset), base asset won't contribute to margin
   */
  function setBaseAssetMarginFactor(uint marketId, uint marginFactor, uint initialMarginMultiplier) external onlyOwner {
    _checkMarketExist(marketId);

    if (marginFactor > 1e18 || initialMarginMultiplier > 1e18) {
      revert SRM_InvalidBaseDiscountFactor();
    }

    baseMarginParams[marketId] = BaseMarginParams({marginFactor: marginFactor, IMScale: initialMarginMultiplier});

    emit BaseMarginParamsSet(marketId, marginFactor, initialMarginMultiplier);
  }

  /**
   * @notice Set the option margin parameters for an market
   */
  function setOptionMarginParams(uint marketId, OptionMarginParams calldata params) external onlyOwner {
    _checkMarketExist(marketId);

    if (
      params.maxSpotReq > 1.2e18 // 0 <= x <= 1.2
        || params.minSpotReq > 1.2e18 // 0 <= x <= 1.2
        || params.mmCallSpotReq > 1e18 // 0 <= x <= 1
        || params.mmPutSpotReq > 1e18 // 0 <= x <= 1
        || params.MMPutMtMReq > 1e18 // 0 <= x <= 1
        || params.unpairedMMScale < 1e18 || params.unpairedMMScale > 3e18 // 1 <= x <= 3
        || params.unpairedIMScale < 1e18 || params.unpairedIMScale > 3e18 // 1 <= x <= 3
        || params.mmOffsetScale < 1e18 || params.mmOffsetScale > 3e18 // 1 <= x <= 3
    ) {
      revert SRM_InvalidOptionMarginParams();
    }

    optionMarginParams[marketId] = params;

    emit OptionMarginParamsSet(
      marketId,
      params.maxSpotReq,
      params.minSpotReq,
      params.mmCallSpotReq,
      params.mmPutSpotReq,
      params.MMPutMtMReq,
      params.unpairedMMScale,
      params.unpairedIMScale,
      params.mmOffsetScale
    );
  }

  /**
   * @notice Set the option margin parameters for an market
   */
  function setOracleContingencyParams(uint marketId, OracleContingencyParams memory params) external onlyOwner {
    _checkMarketExist(marketId);
    if (
      params.perpThreshold > 1e18 // 0 <= x < 1
        || params.optionThreshold > 1e18 // 0 <= x < 1
        || params.baseThreshold > 1e18 // 0 <= x < 1
        || params.OCFactor > 1e18
    ) {
      revert SRM_InvalidOracleContingencyParams();
    }
    oracleContingencyParams[marketId] = params;

    emit OracleContingencySet(params.perpThreshold, params.optionThreshold, params.baseThreshold, params.OCFactor);
  }

  /**
   * @notice Set the option margin parameters for an market
   *
   */
  function setDepegParameters(DepegParams calldata params) external onlyOwner {
    if (params.threshold > 1e18 || params.depegFactor > 3e18) revert SRM_InvalidDepegParams();
    depegParams = params;

    emit DepegParametersSet(params.threshold, params.depegFactor);
  }

  /**
   * @notice Set feed for stable / USD price
   *
   */
  function setStableFeed(ISpotFeed _stableFeed) external onlyOwner {
    stableFeed = _stableFeed;

    emit StableFeedUpdated(address(_stableFeed));
  }

  ///////////////////////
  //   Account Hooks   //
  ///////////////////////

  /**
   * @notice Ensures asset is valid and Max Loss margin is met.
   * @param accountId Account for which to check trade.
   */
  function handleAdjustment(
    uint accountId,
    uint tradeId,
    address caller,
    ISubAccounts.AssetDelta[] memory assetDeltas,
    bytes calldata managerData
  ) external override onlyAccounts nonReentrant {
    _preAdjustmentHooks(accountId, tradeId, caller, assetDeltas, managerData);

    // The VM pool is the engine's own account and may run negative in cash while it owes winners. Nothing but the engine
    // moves it: leaving it needs its owner's (the engine's) allowance, and FutureAsset and PerpAsset require an allowance
    // for any adjustment, so no position can be pushed in. It is not risk checked, never auctioned (see
    // _getMarginAndMarkToMarket), and so never blocks a transfer the engine makes through it: a liquidation fee to the
    // SecurityModule's account, under another manager, passes through it. The hooks above still apply: pause and caps.
    if (accountId == accId) return;

    // Block any transfers where an account is under liquidation
    _checkIfLiveAuction(accountId);

    // realise VM on every future the account holds before the risk check, including any this adjustment booked at
    // its fill price
    _settleAllFutureVM(accountId);

    // if account is only reduce perp position, increasing cash, or increasing option position, bypass check
    bool riskAdding = false;
    bool isPositiveCashDelta = true;
    // a futures reduction is not risk adding but can realise a loss at its fill price: held to maintenance margin
    bool futureReduced = false;

    // check assets are only cash or whitelisted perp and options
    for (uint i = 0; i < assetDeltas.length; i++) {
      if (address(assetDeltas[i].asset) == address(cashAsset)) {
        if (assetDeltas[i].delta < 0) {
          riskAdding = true;
          isPositiveCashDelta = false;
        }
        continue;
      }

      AssetDetail memory detail = _assetDetails[assetDeltas[i].asset];

      if (!detail.isWhitelisted) revert SRM_UnsupportedAsset();

      if (detail.assetType == AssetType.Perpetual) {
        IPerpAsset perp = IPerpAsset(address(assetDeltas[i].asset));
        // settle perp PNL into cash if the user traded perp in this tx.
        _settlePerpRealizedPNL(perp, accountId);

        if (!riskAdding) {
          // check if the delta and position has same sign
          // if so, we cannot bypass the risk check
          int perpPosition = subAccounts.getBalance(accountId, perp, 0);
          if (perpPosition != 0 && assetDeltas[i].delta * perpPosition > 0) {
            riskAdding = true;
          }
        }
      } else if (detail.assetType == AssetType.Future) {
        IFutureAsset futureAsset = IFutureAsset(address(assetDeltas[i].asset));
        // A position this adjustment closed is no longer in the account's balances, so _settleAllFutureVM did not see
        // it; settle it here or the VM realised at its fill price is stranded.
        _settleFutureVM(futureAsset, accountId, uint96(assetDeltas[i].subId));

        int futurePosition = subAccounts.getBalance(accountId, futureAsset, assetDeltas[i].subId);
        if (futurePosition != 0 && assetDeltas[i].delta * futurePosition > 0) {
          riskAdding = true;
        } else {
          futureReduced = true;
        }
      } else {
        // if the user is shorting more options, or removing collateral, we need to check margin
        if (assetDeltas[i].delta < 0) {
          riskAdding = true;
        }
      }
    }

    ISubAccounts.AssetBalance[] memory assetBalances = subAccounts.getAccountBalances(accountId);

    if (
      assetBalances.length > maxAccountSize //
        && viewer.getPreviousAssetsLength(assetBalances, assetDeltas) < assetBalances.length
    ) {
      revert SRM_TooManyAssets();
    }

    // only bypass risk check if we are only reducing perp position, increasing cash, or increasing option position
    // a futures reduction with nothing else risk adding is held to maintenance, so an account can always deleverage
    if (!riskAdding) {
      if (futureReduced) _assessRisk(caller, accountId, assetBalances, isPositiveCashDelta, true);
      return;
    }

    _assessRisk(caller, accountId, assetBalances, isPositiveCashDelta, false);
  }

  /**
   * @dev Perform a risk check on the account.
   */
  function _assessRisk(
    address caller,
    uint accountId,
    ISubAccounts.AssetBalance[] memory assetBalances,
    bool isPositiveCashDelta,
    bool maintenanceOnly
  ) internal view {
    MarginEnginePortfolio memory portfolio =
      IMarginEnginePortfolioViewer(address(viewer)).arrangeMarginEnginePortfolio(assetBalances);

    // account can only have negative cash if borrowing is enabled. However allow closing of negative positions if they
    // already had them.
    if (!borrowingEnabled && portfolio.cash < 0 && !isPositiveCashDelta) revert SRM_NoNegativeCash();

    if (maintenanceOnly || trustedRiskAssessor[caller]) {
      (int postMM,) = _getMarginAndMarkToMarket(accountId, portfolio, false);
      if (postMM >= 0) return;
    } else {
      (int postIM,) = _getMarginAndMarkToMarket(accountId, portfolio, true);
      if (postIM >= 0) return;
    }

    revert SRM_PortfolioBelowMargin();
  }

  /**
   * @notice Get the net margin for the option positions. This is expected to be negative
   * @param accountId Account Id for which to check
   * @return netMargin Net margin. If negative, the account is under margin requirement
   * @return totalMarkToMarket The mark-to-market value of the portfolio, should be positive unless portfolio is obviously insolvent
   */
  function _getMarginAndMarkToMarket(uint accountId, MarginEnginePortfolio memory portfolio, bool isInitial)
    internal
    view
    returns (int netMargin, int totalMarkToMarket)
  {
    uint depegMultiplier = _getDepegMultiplier(isInitial);

    // for each markets, get margin and sum it up
    for (uint i = 0; i < portfolio.marketHoldings.length; i++) {
      (int margin, int markToMarket) =
        _getMarketMargin(accountId, portfolio.marketHoldings[i], isInitial, depegMultiplier);
      netMargin += margin;
      totalMarkToMarket += markToMarket;
    }

    totalMarkToMarket += portfolio.cash;
    netMargin += portfolio.cash;

    // The pool is never liquidatable: its deficit is repaid as losers settle. Mark-to-market still reports it.
    if (accountId == accId) netMargin = 0;
  }

  /**
   * @dev If the stable feed for stable / USD return price lower than threshold, add extra amount to im
   * @return A positive multiplier that should be multiply to S * sum(shorts + perps)
   */
  function _getDepegMultiplier(bool isInitial) internal view returns (uint) {
    if (!isInitial) return 0;

    (uint stablePrice,) = stableFeed.getSpot();
    if (stablePrice >= depegParams.threshold) return 0;

    return (depegParams.threshold - stablePrice).multiplyDecimal(depegParams.depegFactor);
  }

  /**
   * @notice Return the margin for a specific market, including perp & option position
   * @dev This function should normally return a negative number, -100e18 means it requires $100 cash as margin
   *      it's possible that it return positive number because of unrealizedPNL from the perp position
   */
  function _getMarketMargin(uint accountId, MarketHolding memory marketHolding, bool isInitial, uint depegMultiplier)
    internal
    view
    returns (int margin, int markToMarket)
  {
    (uint spotPrice, uint spotConf) = _getSpotPrice(marketHolding.marketId);
    int optionMtm;
    int futureVMMtM;

    // scope locals to avoid stack-too-deep in this path
    {
      margin += _getNetPerpMargin(marketHolding, spotPrice, isInitial, spotConf);
      // futures, with unsettled VM counted as unrealised perp PnL is below; realised on every path that writes
      int futureMargin;
      (futureMargin, futureVMMtM) = _getFutureMarginAndMtM(accountId, marketHolding, isInitial, depegMultiplier);
      margin += futureMargin;
      int netOptionMargin;
      (netOptionMargin, optionMtm) = _getNetOptionMarginAndMtM(marketHolding, spotPrice, isInitial, spotConf);
      margin += netOptionMargin;
    }

    // apply depeg IM penalty
    if (depegMultiplier != 0) {
      // depeg multiplier should be 0 for maintenance margin, or when there is no depeg
      margin -= marketHolding.depegPenaltyPos.multiplyDecimal(depegMultiplier).multiplyDecimal(spotPrice).toInt256();
    }

    // base value is the mark to market value of ETH or BTC hold in the account
    int baseMtM;
    {
      int baseMargin;
      (baseMargin, baseMtM) =
        _getBaseMarginAndMtM(marketHolding.marketId, marketHolding.basePosition, spotPrice, spotConf, isInitial);
      margin += baseMargin;
    }

    int unrealizedPerpPNL;
    if (marketHolding.perpPosition != 0) {
      // if this function is called in handleAdjustment, unrealized perp pnl will always be 0 if this perp is traded
      // because it would have been settled.
      // If called as a view function or on perp assets didn't got traded in this tx, it will represent the value that
      // should be added as cash if it is settle now
      unrealizedPerpPNL = marketHolding.perp.getUnsettledAndUnrealizedCash(accountId);
    }

    margin += unrealizedPerpPNL;

    // unrealized pnl is the mark to market value of a perp position
    markToMarket = optionMtm + unrealizedPerpPNL + baseMtM + futureVMMtM;
  }

  /**
   * @notice Get the margin required for the perp position of an market
   * @param spotConf index confidence
   * @return netMargin for a perp position, always negative
   */
  function _getNetPerpMargin(MarketHolding memory marketHolding, uint spotPrice, bool isInitial, uint spotConf)
    internal
    view
    returns (int netMargin)
  {
    int position = marketHolding.perpPosition;
    if (position == 0) return 0;

    // while calculating margin for perp, we use the perp market price oracle
    (uint perpPrice, uint confidence) = marketHolding.perp.getPerpPrice();
    uint notional = SignedMath.abs(position).multiplyDecimal(perpPrice);
    uint requirement = isInitial
      ? perpMarginRequirements[marketHolding.marketId].imPerpReq
      : perpMarginRequirements[marketHolding.marketId].mmPerpReq;
    netMargin = -int(notional.multiplyDecimal(requirement));

    if (!isInitial) return netMargin;

    // if the min of two confidences is below threshold, apply penalty (becomes more negative)
    uint minConf = Math.min(confidence, spotConf);
    OracleContingencyParams memory ocParam = oracleContingencyParams[marketHolding.marketId];
    if (ocParam.perpThreshold != 0 && minConf < ocParam.perpThreshold) {
      uint diff = 1e18 - minConf;
      uint penalty =
        diff.multiplyDecimal(ocParam.OCFactor).multiplyDecimal(spotPrice).multiplyDecimal(SignedMath.abs(position));
      netMargin -= penalty.toInt256();
    }
  }

  /**
   * @notice Margin for every futures position in a market (FutureVMLib.marketMargin): the requirement and any depeg
   *         penalty, gross, on each position's USDC notional (|position| x contractSize x mark), plus unsettled VM,
   *         which is cash, at par. Mark-to-market is that VM.
   */
  function _getFutureMarginAndMtM(
    uint accountId,
    MarketHolding memory marketHolding,
    bool isInitial,
    uint depegMultiplier
  ) internal view returns (int margin, int markToMarket) {
    if (marketHolding.futurePositions.length == 0) return (0, 0);
    uint marketId = marketHolding.marketId;
    (margin, markToMarket) = FutureVMLib.marketMargin(
      FutureVMLib.MarketInputs({
        future: marketHolding.future,
        accountId: accountId,
        // the depeg penalty on the futures' own notional, as on a perp's (0 for maintenance)
        requirement: (isInitial ? futureMarginRequirements[marketId].imReq : futureMarginRequirements[marketId].mmReq)
          + depegMultiplier
      }),
      marketHolding.futurePositions
    );
  }

  /**
   * @notice Get the net margin for the option positions. This is expected to be negative
   * @param minConfidence minimum confidence of perp and index oracle. This will be used to compare with other oracles
   *        and if min of all confidence scores fall below a threshold, add a penalty to the margin
   */
  function _getNetOptionMarginAndMtM(
    MarketHolding memory marketHolding,
    uint spotPrice,
    bool isInitial,
    uint minConfidence
  ) internal view returns (int netMargin, int totalMarkToMarket) {
    for (uint i = 0; i < marketHolding.expiryHoldings.length; i++) {
      ExpiryHolding memory expiryHolding = marketHolding.expiryHoldings[i];
      (uint forwardPrice, uint localMinConf) = _getForwardPrice(marketHolding.marketId, expiryHolding.expiry);
      localMinConf = Math.min(minConfidence, localMinConf);
      uint volConf = volFeeds[marketHolding.marketId].getExpiryMinConfidence(uint64(expiryHolding.expiry));
      localMinConf = Math.min(localMinConf, volConf);
      OptionMarginHelper.ExpiryMarginInputs memory inputs =
        _getOptionExpiryInputs(marketHolding.marketId, expiryHolding, spotPrice, forwardPrice, isInitial, localMinConf);
      (int expiryMargin, int expiryMtm) = optionMarginHelper.getExpiryMargin(inputs);
      netMargin += expiryMargin;
      totalMarkToMarket += expiryMtm;
    }
  }

  function _getOptionExpiryInputs(
    uint marketId,
    ExpiryHolding memory expiryHolding,
    uint spotPrice,
    uint forwardPrice,
    bool isInitial,
    uint localMinConf
  ) internal view returns (OptionMarginHelper.ExpiryMarginInputs memory inputs) {
    inputs = OptionMarginHelper.ExpiryMarginInputs({
      expiryHolding: expiryHolding,
      params: optionMarginParams[marketId],
      ocParams: oracleContingencyParams[marketId],
      spotPrice: spotPrice,
      forwardPrice: forwardPrice,
      localMinConf: localMinConf,
      isInitial: isInitial,
      vols: _getOptionExpiryVols(marketId, expiryHolding)
    });
  }

  function _getOptionExpiryVols(uint marketId, ExpiryHolding memory expiryHolding)
    internal
    view
    returns (uint[] memory vols)
  {
    vols = new uint[](expiryHolding.options.length);
    for (uint j = 0; j < expiryHolding.options.length; ++j) {
      (uint vol,) = volFeeds[marketId].getVol(uint128(expiryHolding.options[j].strike), uint64(expiryHolding.expiry));
      vols[j] = vol;
    }
  }

  /**
   * @dev calculate the margin contributed by base asset, and the mark to market value
   */
  function _getBaseMarginAndMtM(uint marketId, uint position, uint spotPrice, uint spotConf, bool isInitial)
    internal
    view
    returns (int baseMargin, int baseMarkToMarket)
  {
    if (position == 0) return (0, 0);

    (uint stablePrice,) = stableFeed.getSpot();

    uint notional = position.multiplyDecimal(spotPrice);

    // the margin contributed by base asset is spot * positionSize * discount factor
    baseMargin = notional.multiplyDecimal(baseMarginParams[marketId].marginFactor).toInt256();

    // convert to denominate in stable
    baseMarkToMarket = notional.divideDecimal(stablePrice).toInt256();

    // add oracle contingency for spot asset, only for IM
    if (!isInitial) return (baseMargin, baseMarkToMarket);

    baseMargin = baseMargin.multiplyDecimal(baseMarginParams[marketId].IMScale.toInt256());

    if (baseMargin == 0) {
      return (0, baseMarkToMarket);
    }

    OracleContingencyParams memory ocParam = oracleContingencyParams[marketId];
    if (ocParam.baseThreshold != 0 && spotConf < uint(ocParam.baseThreshold)) {
      uint diff = 1e18 - spotConf;
      uint penalty = diff.multiplyDecimal(ocParam.OCFactor).multiplyDecimal(notional);
      baseMargin -= penalty.toInt256();
    }
  }

  /**
   * @notice Settle expired option positions in an account.
   * @dev This function can be called by anyone
   */
  function settleOptions(IOptionAsset option, uint accountId) external {
    if (!_assetDetails[option].isWhitelisted) revert SRM_UnsupportedAsset();
    _settleAccountOptions(option, accountId);
  }

  /**
   * @dev settle perp value with index price
   */
  function settlePerpsWithIndex(uint accountId) external {
    _settleAllFutureVM(accountId);

    for (uint id = 1; id <= lastMarketId; id++) {
      IPerpAsset perp = IPerpAsset(address(assetMap[id][AssetType.Perpetual]));
      if (address(perp) == address(0) || subAccounts.getBalance(accountId, perp, 0) == 0) continue;
      _settlePerpUnrealizedPNL(perp, accountId);
    }
  }

  /// @notice Realise an account's futures VM. Anyone may call: the keeper sweeps every holder after each mark.
  function settleAccount(uint accountId) external nonReentrant {
    _settleAllFutureVM(accountId);
  }

  /**
   * @notice After a future's settlement price is fixed, realise the last VM and remove the position. Anyone may call.
   * @dev    VM is USDC and was accrued to the settlement price by the asset, so close-out reads no feed: a stale or dead
   *         feed after expiry cannot hold positions open.
   */
  function closeOutExpired(uint accountId, uint96 subId) external nonReentrant {
    FutureVMLib.closeOutAll(subAccounts, cashAsset, accId, accountId, subId);
  }

  /**
   * @notice Take cash out of the VM pool. VM is zero-sum, so the pool nets to the dust of rounding once every holder is
   *         settled; this sweeps it, or anything sent to the pool by mistake.
   */
  function withdrawFromPool(IERC20BasedAsset asset, uint amount, address recipient) external onlyOwner {
    asset.withdraw(accId, amount, recipient);
  }

  /**
   * @dev The pool is the engine's own account: it takes no positions. The auction already refuses it (a bidder's owner
   *      must be the caller), so this is defence in depth. VM is realised before a bid by the auction itself, which calls
   *      settlePerpsWithIndex on the account first; a bidder's VM on what it takes accrues in FutureAsset.
   */
  function executeBid(uint accountId, uint liquidatorId, uint portion, uint bidAmount, uint reservedCash)
    external
    override(IBaseManager, BaseManager)
    onlyLiquidations
  {
    if (liquidatorId == accId) revert ME_PoolCannotBid();
    _executeBid(accountId, liquidatorId, portion, bidAmount, reservedCash);
  }

  ////////////////////////
  //   View Functions   //
  ////////////////////////

  /**
   * @dev Return the detail info of an asset. Should be empty if this is not trusted by standard manager
   */
  function assetDetails(IAsset asset) external view returns (AssetDetail memory) {
    return _assetDetails[asset];
  }

  /**
   * @dev Return the addresses of feeds for a specific market
   */
  function getMarketFeeds(uint marketId) external view returns (ISpotFeed, IForwardFeed, IVolFeed) {
    return (spotFeeds[marketId], forwardFeeds[marketId], volFeeds[marketId]);
  }

  /**
   * @dev Return the total net margin of an account
   * @return margin if it is negative, the account is insolvent
   */
  function getMargin(uint accountId, bool isInitial) external view returns (int margin) {
    // get portfolio from array of balances
    MarginEnginePortfolio memory portfolio =
      IMarginEnginePortfolioViewer(address(viewer)).getMarginEnginePortfolio(accountId);
    (margin,) = _getMarginAndMarkToMarket(accountId, portfolio, isInitial);
    return margin;
  }

  /**
   * @dev Return the total net margin and MtM in one function call
   */
  function getMarginAndMarkToMarket(uint accountId, bool isInitial, uint)
    external
    view
    returns (int margin, int markToMarket)
  {
    MarginEnginePortfolio memory portfolio =
      IMarginEnginePortfolioViewer(address(viewer)).getMarginEnginePortfolio(accountId);
    return _getMarginAndMarkToMarket(accountId, portfolio, isInitial);
  }

  /**
   * @dev Return the isolated margin for a single option position
   * @return margin negative number, indicate margin requirement for a position
   * @return markToMarket the estimated worth of this position
   */
  function getIsolatedMargin(uint marketId, uint strike, uint expiry, bool isCall, int balance, bool isInitial)
    external
    view
    returns (int margin, int markToMarket)
  {
    (uint spotPrice,) = _getSpotPrice(marketId);
    (uint forwardPrice,) = _getForwardPrice(marketId, expiry);
    Option memory optionPos = Option({strike: strike, isCall: isCall, balance: balance});
    (uint vol,) = volFeeds[marketId].getVol(uint128(strike), uint64(expiry));
    OptionMarginParams memory params = optionMarginParams[marketId];
    OptionMarginHelper.OptionComputationContext memory ctx = OptionMarginHelper.OptionComputationContext({
      expiry: expiry, spotPrice: spotPrice, forwardPrice: forwardPrice, vol: vol, isInitial: isInitial
    });
    OptionMarginHelper.IsolatedMarginInputs memory inputs =
      OptionMarginHelper.IsolatedMarginInputs({params: params, optionPos: optionPos, ctx: ctx});
    return optionMarginHelper.getIsolatedMargin(inputs);
  }

  //////////////////////////
  //       Internal       //
  //////////////////////////

  function _checkMarketExist(uint marketId) internal view {
    if (marketId > lastMarketId) revert SRM_MarketNotCreated();
  }

  /// @dev Realise VM on every future the account holds (FutureVMLib: base first through the pool, the rest in cash)
  function _settleAllFutureVM(uint accountId) internal {
    FutureVMLib.settleAll(subAccounts, cashAsset, accId, accountId);
  }

  /// @dev Realise VM on one series, at spot
  function _settleFutureVM(IFutureAsset future, uint accountId, uint96 subId) internal {
    FutureVMLib.settleOne(subAccounts, cashAsset, accId, future, accountId, subId);
  }

  function _chargeAllOIFee(address caller, uint accountId, uint tradeId, ISubAccounts.AssetDelta[] memory assetDeltas)
    internal
    override
  {
    if (feeBypassedCaller[caller]) return;

    uint fee;
    // iterate through all asset changes, if it's option asset, change if OI increased
    for (uint i; i < assetDeltas.length; i++) {
      AssetDetail memory detail = _assetDetails[assetDeltas[i].asset];
      if (detail.assetType == AssetType.Perpetual) {
        IPerpAsset perp = IPerpAsset(address(assetDeltas[i].asset));
        fee += _getPerpOIFee(perp, assetDeltas[i].delta, tradeId);
      } else if (detail.assetType == AssetType.Option) {
        IOptionAsset option = IOptionAsset(address(assetDeltas[i].asset));
        IForwardFeed forwardFeed = forwardFeeds[detail.marketId];
        fee += _getOptionOIFee(option, forwardFeed, assetDeltas[i].delta, assetDeltas[i].subId, tradeId);
      }
    }

    _payFee(accountId, fee);
  }

  /**
   * @dev Return index price for a market
   */
  function _getSpotPrice(uint marketId) internal view returns (uint, uint) {
    return spotFeeds[marketId].getSpot();
  }

  /**
   * @dev Return the forward price for a specific market and expiry timestamp
   */
  function _getForwardPrice(uint marketId, uint expiry) internal view returns (uint, uint) {
    (uint fwdPrice, uint confidence) = forwardFeeds[marketId].getForwardPrice(uint64(expiry));
    if (fwdPrice == 0) revert SRM_NoForwardPrice();
    return (fwdPrice, confidence);
  }
}
