// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/utils/math/Math.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {IDatedFutureAsset} from "../interfaces/IDatedFutureAsset.sol";
import {IERC20BasedAsset} from "../interfaces/IERC20BasedAsset.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {IBasePortfolioViewer} from "../interfaces/IBasePortfolioViewer.sol";
import {ILiquidatableManager} from "../interfaces/ILiquidatableManager.sol";
import {IBaseManager} from "../interfaces/IBaseManager.sol";

import {BaseManager} from "./BaseManager.sol";

/**
 * @title DatedFutureManager
 * @notice Standard risk manager for cNGN-settled USDC/cNGN dated futures.
 * @dev    Accounts hold USDC cash, wrapped cNGN, and positions in one DatedFutureAsset. Margin is
 *
 *             cash + value(cNGN held + cNGN VM pending) - requirement * sum(|position| * contractSize)
 *
 *         in USDC, with cNGN valued at the spot feed (haircut when held, at par when owed).
 *
 *         Variation margin moves as wrapped cNGN through the pool account `accId`, which this manager owns: losers pay
 *         into it, winners are paid from it. Settlement is per account and lazy, so a winner can be settled before the
 *         loser who funds them; the pool is seeded with a cNGN reserve to cover that gap. Wrapped cNGN cannot go
 *         negative, so whatever a loser cannot pay in cNGN, and whatever the pool cannot pay out in cNGN, moves as USDC
 *         cash at the spot price instead. Settlement therefore never reverts on a shortfall, and an account can always
 *         be settled and liquidated.
 */
contract DatedFutureManager is ILiquidatableManager, BaseManager, ReentrancyGuard {
  using DecimalMath for uint;
  using SignedDecimalMath for int;
  using SafeCast for uint;
  using SafeCast for int;

  struct MarginParams {
    /// @dev maintenance requirement, as a fraction of USDC notional
    uint mmReq;
    /// @dev initial requirement, as a fraction of USDC notional
    uint imReq;
    /// @dev fraction of cNGN's spot value that counts as maintenance margin when held
    uint cngnMarginFactor;
    /// @dev further scale applied to cngnMarginFactor for initial margin
    uint cngnIMScale;
  }

  ///////////////
  // Variables //
  ///////////////

  IDatedFutureAsset public immutable future;

  /// @dev wrapped cNGN: the asset variation margin settles in, and the only collateral besides cash
  IAsset public immutable cngnAsset;

  /// @dev USDC per cNGN
  ISpotFeed public spotFeed;

  MarginParams public marginParams;

  ////////////
  // Events //
  ////////////

  event SpotFeedSet(address spotFeed);
  event MarginParamsSet(uint mmReq, uint imReq, uint cngnMarginFactor, uint cngnIMScale);
  event VMSettled(uint indexed accountId, uint96 indexed subId, int cngnDelta, uint cngnMoved, uint cashMoved);
  event PositionClosedOut(uint indexed accountId, uint96 indexed subId, int position);

  ////////////
  // Errors //
  ////////////

  error DFM_UnsupportedAsset();
  error DFM_InvalidMarginParams();
  error DFM_NoNegativeCash();
  error DFM_PortfolioBelowMargin();
  error DFM_TooManyAssets();
  error DFM_PoolCannotHoldFutures();
  error DFM_NotSettled();
  error DFM_OptionsUnsupported();

  ////////////////////////
  //    Constructor     //
  ////////////////////////

  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction dutchAuction_,
    IBasePortfolioViewer viewer_,
    IDatedFutureAsset future_,
    IAsset cngnAsset_,
    ISpotFeed spotFeed_
  ) BaseManager(subAccounts_, cashAsset_, dutchAuction_, viewer_) {
    future = future_;
    cngnAsset = cngnAsset_;
    spotFeed = spotFeed_;
  }

  ///////////////////////
  //    Owner-Only     //
  ///////////////////////

  function setSpotFeed(ISpotFeed spotFeed_) external onlyOwner {
    spotFeed = spotFeed_;
    emit SpotFeedSet(address(spotFeed_));
  }

  function setMarginParams(MarginParams calldata params) external onlyOwner {
    if (
      params.mmReq == 0 || params.mmReq > params.imReq || params.imReq >= 1e18 || params.cngnMarginFactor > 1e18
        || params.cngnIMScale > 1e18
    ) {
      revert DFM_InvalidMarginParams();
    }
    marginParams = params;
    emit MarginParamsSet(params.mmReq, params.imReq, params.cngnMarginFactor, params.cngnIMScale);
  }

  /**
   * @notice Take cNGN or cash out of the VM pool. The pool is seeded with a cNGN reserve so winners can be paid before
   *         the losers who fund them are settled; this is how that reserve is rebalanced.
   */
  function withdrawFromPool(IERC20BasedAsset asset, uint amount, address recipient) external onlyOwner {
    asset.withdraw(accId, amount, recipient);
  }

  ///////////////////////
  //   Account Hooks   //
  ///////////////////////

  function handleAdjustment(
    uint accountId,
    uint tradeId,
    address caller,
    ISubAccounts.AssetDelta[] memory assetDeltas,
    bytes calldata managerData
  ) external override onlyAccounts nonReentrant {
    _preAdjustmentHooks(accountId, tradeId, caller, assetDeltas, managerData);
    _checkIfLiveAuction(accountId);

    // realise VM, including any this adjustment just booked at its fill price, before the risk check
    _settleAllVM(accountId);

    bool riskAdding;
    bool cashOut;
    bool futureIncreased;

    for (uint i = 0; i < assetDeltas.length; ++i) {
      IAsset asset = assetDeltas[i].asset;
      int delta = assetDeltas[i].delta;

      if (asset == cashAsset) {
        if (delta < 0) {
          riskAdding = true;
          cashOut = true;
        }
      } else if (asset == cngnAsset) {
        if (delta < 0) riskAdding = true;
      } else if (asset == IAsset(address(future))) {
        // A position this adjustment closed is no longer in the account's balances, so _settleAllVM did not see
        // it; settle it here or the VM realised at its fill price is stranded.
        _settleVM(accountId, uint96(assetDeltas[i].subId));
        // Every future change is checked: a reduction can realise a loss at its fill price.
        riskAdding = true;
        int position = subAccounts.getBalance(accountId, future, assetDeltas[i].subId);
        if (position != 0 && position * delta > 0) futureIncreased = true;
      } else {
        revert DFM_UnsupportedAsset();
      }
    }

    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    if (balances.length > maxAccountSize && viewer.getPreviousAssetsLength(balances, assetDeltas) < balances.length) {
      revert DFM_TooManyAssets();
    }

    if (!riskAdding) return;

    // Negative cash only ever comes from a VM shortfall. An account cannot draw cash below zero itself.
    if (cashOut && subAccounts.getBalance(accountId, cashAsset, 0) < 0) revert DFM_NoNegativeCash();

    // Trusted assessors, and accounts that only reduced futures exposure, are held to maintenance margin; everything
    // else to initial. A pure reduction is never blocked by IM, so an account can always deleverage above MM.
    bool isInitial = !trustedRiskAssessor[caller] && (futureIncreased || cashOut || _hasNegativeCngnDelta(assetDeltas));
    (int margin,) = _getMarginAndMarkToMarket(accountId, isInitial);
    if (margin < 0) revert DFM_PortfolioBelowMargin();
  }

  ///////////////////////
  //    Settlement     //
  ///////////////////////

  /// @notice Realise an account's VM. Anyone may call: the keeper sweeps every account after each mark.
  function settleAccount(uint accountId) external nonReentrant {
    _settleAllVM(accountId);
  }

  /**
   * @notice After the settlement price is fixed, realise the last VM and remove the position.
   * @dev    Anyone may call. The position leaves at the settlement price, so nothing but VM changes hands.
   */
  function closeOutExpired(uint accountId, uint96 subId) external nonReentrant {
    if (!future.futureContracts(subId).settled) revert DFM_NotSettled();
    _settleVM(accountId, subId);

    int position = subAccounts.getBalance(accountId, future, subId);
    if (position == 0) return;
    subAccounts.managerAdjustment(ISubAccounts.AssetAdjustment(accountId, future, subId, -position, bytes32(0)));
    emit PositionClosedOut(accountId, subId, position);
  }

  /// @dev The auction calls this before pricing an account; here it realises VM.
  function settlePerpsWithIndex(uint accountId) external nonReentrant {
    _settleAllVM(accountId);
  }

  function settleOptions(IOptionAsset, uint) external pure {
    revert DFM_OptionsUnsupported();
  }

  function executeBid(uint accountId, uint liquidatorId, uint portion, uint bidAmount, uint reservedCash)
    external
    override(IBaseManager, BaseManager)
    onlyLiquidations
    nonReentrant
  {
    if (liquidatorId == accId) revert DFM_PoolCannotHoldFutures();
    _settleAllVM(accountId);
    _settleAllVM(liquidatorId);
    _executeBid(accountId, liquidatorId, portion, bidAmount, reservedCash);
  }

  function _settleAllVM(uint accountId) internal {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (balances[i].asset != IAsset(address(future))) continue;
      _settleVM(accountId, uint96(balances[i].subId));
    }
  }

  function _settleVM(uint accountId, uint96 subId) internal {
    int cngnDelta = future.settleAccountVM(accountId, subId);
    if (cngnDelta == 0) return;

    (uint cngnMoved, uint cashMoved) =
      cngnDelta > 0 ? _pay(accId, accountId, uint(cngnDelta), false) : _pay(accountId, accId, uint(-cngnDelta), true);

    emit VMSettled(accountId, subId, cngnDelta, cngnMoved, cashMoved);
  }

  /**
   * @dev Move `cngnOwed` from `from` to `to`: as much as `from` holds in wrapped cNGN, and the remainder as cash at the
   *      spot price. The remainder rounds against the payer (`roundUp` when the payer is a trader, down when it is
   *      the pool), so rounding never leaves the pool short.
   */
  function _pay(uint from, uint to, uint cngnOwed, bool roundUp) internal returns (uint cngnMoved, uint cashMoved) {
    int held = subAccounts.getBalance(from, cngnAsset, 0);
    cngnMoved = held > 0 ? Math.min(cngnOwed, uint(held)) : 0;
    if (cngnMoved != 0) _symmetricManagerAdjustment(from, to, cngnAsset, 0, cngnMoved.toInt256());

    uint remainder = cngnOwed - cngnMoved;
    if (remainder == 0) return (cngnMoved, 0);

    (uint spot,) = spotFeed.getSpot();
    cashMoved = Math.mulDiv(remainder, spot, 1e18, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    if (cashMoved != 0) _symmetricManagerAdjustment(from, to, cashAsset, 0, cashMoved.toInt256());
  }

  function _chargeAllOIFee(address, uint, uint, ISubAccounts.AssetDelta[] memory) internal pure override {}

  ////////////////////////
  //       Margin       //
  ////////////////////////

  function getMargin(uint accountId, bool isInitial) external view returns (int margin) {
    (margin,) = _getMarginAndMarkToMarket(accountId, isInitial);
  }

  function getMarginAndMarkToMarket(uint accountId, bool isInitial, uint)
    external
    view
    returns (int margin, int markToMarket)
  {
    return _getMarginAndMarkToMarket(accountId, isInitial);
  }

  function _getMarginAndMarkToMarket(uint accountId, bool isInitial)
    internal
    view
    returns (int margin, int markToMarket)
  {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);

    int cash;
    int netCngn;
    uint notional;
    uint size = future.contractSize();

    for (uint i = 0; i < balances.length; ++i) {
      IAsset asset = balances[i].asset;
      if (asset == cashAsset) {
        cash = balances[i].balance;
      } else if (asset == cngnAsset) {
        netCngn += balances[i].balance;
      } else if (asset == IAsset(address(future))) {
        notional += SignedMath.abs(balances[i].balance).multiplyDecimal(size);
        netCngn += future.getPendingVM(accountId, balances[i].subId);
      }
    }

    MarginParams memory params = marginParams;
    int cngnValue;
    int cngnMargin;
    if (netCngn != 0) {
      // only read the feed when there is cNGN to value, so a cash-only account never depends on it
      (uint spot,) = spotFeed.getSpot();
      cngnValue = netCngn.multiplyDecimal(spot.toInt256());
      if (netCngn > 0) {
        uint factor = params.cngnMarginFactor;
        if (isInitial) factor = factor.multiplyDecimal(params.cngnIMScale);
        cngnMargin = cngnValue.multiplyDecimal(factor.toInt256());
      } else {
        // cNGN owed is a debt at par
        cngnMargin = cngnValue;
      }
    }

    uint requirement = notional.multiplyDecimal(isInitial ? params.imReq : params.mmReq);

    margin = cash + cngnMargin - requirement.toInt256();
    markToMarket = cash + cngnValue;
  }

  function _hasNegativeCngnDelta(ISubAccounts.AssetDelta[] memory assetDeltas) internal view returns (bool) {
    for (uint i = 0; i < assetDeltas.length; ++i) {
      if (assetDeltas[i].asset == cngnAsset && assetDeltas[i].delta < 0) return true;
    }
    return false;
  }
}
