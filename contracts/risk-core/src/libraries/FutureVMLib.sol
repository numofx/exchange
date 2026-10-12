// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/Math.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";

/**
 * @title FutureVMLib
 * @notice MarginEngine's variation margin for cNGN-settled futures, as an external library: delegatecalled, so it runs
 *         with the engine's address (SubAccounts.managerAdjustment accepts it as the manager) and keeps the engine under
 *         the contract size limit.
 * @dev    VM moves as the market's base asset (wrapped cNGN) through the engine's pool account: from the payer's base
 *         balance first, the remainder as cash. Base cannot go negative, so whatever a loser cannot pay in cNGN, and
 *         whatever the pool cannot pay out in cNGN, moves as cash instead; settlement never reverts on a shortfall.
 */
library FutureVMLib {
  using DecimalMath for uint;
  using SignedDecimalMath for int;
  using SafeCast for uint;
  using SafeCast for int;

  struct Accounts {
    ISubAccounts subAccounts;
    IAsset base;
    IAsset cash;
    ISpotFeed spotFeed;
    uint pool;
  }

  /// @dev The engine itself: delegatecalled, so address(this) is the MarginEngine, and its getters are read back.
  function _engine() private view returns (IMarginEngine) {
    return IMarginEngine(address(this));
  }

  /// @dev Where a market's VM moves: its base asset, the cash, its spot feed for a cash remainder, and the pool
  function _accounts(ISubAccounts subAccounts, IAsset cash, uint pool, uint marketId)
    private
    view
    returns (Accounts memory a)
  {
    (ISpotFeed spotFeed,,) = _engine().getMarketFeeds(marketId);
    a = Accounts({
      subAccounts: subAccounts,
      base: _engine().assetMap(marketId, IMarginEngine.AssetType.Base),
      cash: cash,
      spotFeed: spotFeed,
      pool: pool
    });
  }

  /// @notice Realise VM on every future the account holds, at spot.
  function settleAll(ISubAccounts subAccounts, IAsset cash, uint pool, uint accountId) external {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      IMarginEngine.AssetDetail memory detail = _engine().assetDetails(balances[i].asset);
      if (detail.assetType != IMarginEngine.AssetType.Future) continue;
      _settle(
        _accounts(subAccounts, cash, pool, detail.marketId),
        IFutureAsset(address(balances[i].asset)),
        accountId,
        uint96(balances[i].subId),
        0
      );
    }
  }

  /// @notice Realise VM on one series, at spot: a position an adjustment just closed, which settleAll no longer sees.
  function settleOne(
    ISubAccounts subAccounts,
    IAsset cash,
    uint pool,
    IFutureAsset future,
    uint accountId,
    uint96 subId
  ) external {
    uint marketId = _engine().assetDetails(future).marketId;
    _settle(_accounts(subAccounts, cash, pool, marketId), future, accountId, subId, 0);
  }

  /**
   * @notice Close out a settled series wherever it is listed: the series is found by its subId (its expiry) on each
   *         market's future, so the caller names no asset. Reverts if no market lists it, or it is not yet settled.
   */
  function closeOutAll(ISubAccounts subAccounts, IAsset cash, uint pool, uint accountId, uint96 subId) external {
    bool found;
    uint last = _engine().lastMarketId();
    for (uint id = 1; id <= last; ++id) {
      IFutureAsset future = IFutureAsset(address(_engine().assetMap(id, IMarginEngine.AssetType.Future)));
      if (address(future) == address(0)) continue;
      if (_closeOut(_accounts(subAccounts, cash, pool, id), future, accountId, subId)) found = true;
    }
    if (!found) revert IMarginEngine.ME_NotFuture();
  }

  /**
   * @dev Realise an account's VM on one series.
   * @param settlementPrice cNGN per USDC to convert any cash remainder at; 0 converts at the spot feed. Close-out passes
   *        the settlement price, so it depends on no live feed.
   */
  function _settle(Accounts memory a, IFutureAsset future, uint accountId, uint96 subId, uint settlementPrice)
    private
    returns (int cngnDelta, uint cngnMoved, uint cashMoved)
  {
    cngnDelta = future.settleAccountVM(accountId, subId);
    if (cngnDelta == 0) return (0, 0, 0);
    (cngnMoved, cashMoved) = cngnDelta > 0
      ? _pay(a, a.pool, accountId, uint(cngnDelta), false, settlementPrice)
      : _pay(a, accountId, a.pool, uint(-cngnDelta), true, settlementPrice);
    emit IMarginEngine.VMSettled(accountId, subId, cngnDelta, cngnMoved, cashMoved);
  }

  /**
   * @notice Margin for every futures position in a market, gross: the requirement on each, |position| x contractSize x
   *         requirement (a contract is a fixed USDC amount whatever its price), plus each position's unsettled VM.
   * @param  requirement the market's futures margin requirement, initial or maintenance, plus the depeg multiplier
   *         (initial margin only, 0 otherwise), both fractions of notional
   * @param  marginFactor the market's base margin factor, already scaled for initial margin by the caller
   * @return margin the margin contribution, normally negative
   * @return pendingMtM the unsettled VM at spot, at par, in stable
   */
  function marketMargin(
    IFutureAsset future,
    IMarginEngine.FuturePosition[] memory positions,
    uint accountId,
    uint spotPrice,
    uint requirement,
    uint marginFactor,
    ISpotFeed stableFeed
  ) external view returns (int margin, int pendingMtM) {
    uint size = future.contractSize();
    for (uint i = 0; i < positions.length; ++i) {
      uint notional = SignedMath.abs(positions[i].balance).multiplyDecimal(size);
      margin -= notional.multiplyDecimal(requirement).toInt256();
      (int m, int mtm) = _pendingValue(future, accountId, positions[i].subId, spotPrice, marginFactor);
      margin += m;
      pendingMtM += mtm;
    }
    // mark-to-market is denominated in stable, as StandardManager's base mark-to-market is
    if (pendingMtM != 0) {
      (uint stablePrice,) = stableFeed.getSpot();
      pendingMtM = pendingMtM.divideDecimal(stablePrice.toInt256());
    }
  }

  /**
   * @notice Close out one series on one future, if it is that future's: realise the last VM at the settlement price,
   *         then remove the position. Reverts if the series is listed but not yet settled.
   * @return listed whether `subId` is a series of `future` (if not, nothing was done)
   */
  function _closeOut(Accounts memory a, IFutureAsset future, uint accountId, uint96 subId)
    private
    returns (bool listed)
  {
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    if (!c.listed) return false;
    if (!c.settled) revert IMarginEngine.ME_NotSettled();
    // once settled, markPrice is the settlement price
    _settle(a, future, accountId, subId, c.markPrice);
    int position = a.subAccounts.getBalance(accountId, future, subId);
    if (position != 0) {
      a.subAccounts.managerAdjustment(ISubAccounts.AssetAdjustment(accountId, future, subId, -position, bytes32(0)));
      emit IMarginEngine.PositionClosedOut(accountId, subId, position);
    }
    return true;
  }

  /**
   * @notice An account's unsettled VM on one series, in margin and mark-to-market terms (cash units, 18dp).
   * @dev    Unsettled VM is cNGN not yet moved. Owed, it is a debt at par; due to the account, it counts at the base
   *         asset's margin factor, as held cNGN does, so cNGN counts the same settled or not.
   * @param  marginFactor the market's base margin factor, already scaled for initial margin by the caller
   * @return margin the margin contribution
   * @return markToMarket the value at spot, at par either way
   */
  function _pendingValue(IFutureAsset future, uint accountId, uint subId, uint spotPrice, uint marginFactor)
    internal
    view
    returns (int margin, int markToMarket)
  {
    int pending = future.getPendingVM(accountId, subId);
    if (pending == 0) return (0, 0);
    markToMarket = pending.multiplyDecimal(spotPrice.toInt256());
    margin = pending > 0 ? markToMarket.multiplyDecimal(marginFactor.toInt256()) : markToMarket;
  }

  /**
   * @dev Move `cngnOwed` from `from` to `to`: as much as `from` holds in base, the remainder as cash at
   *      `settlementPrice` (cNGN per USDC) if given, else at spot. The remainder rounds against the payer (up when the
   *      payer is a trader, down when it is the pool), so rounding never leaves the pool short.
   */
  function _pay(Accounts memory a, uint from, uint to, uint cngnOwed, bool roundUp, uint settlementPrice)
    internal
    returns (uint cngnMoved, uint cashMoved)
  {
    int held = a.subAccounts.getBalance(from, a.base, 0);
    cngnMoved = held > 0 ? Math.min(cngnOwed, uint(held)) : 0;
    if (cngnMoved != 0) _move(a.subAccounts, from, to, a.base, cngnMoved.toInt256());

    uint remainder = cngnOwed - cngnMoved;
    if (remainder == 0) return (cngnMoved, 0);

    Math.Rounding rounding = roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor;
    if (settlementPrice != 0) {
      cashMoved = Math.mulDiv(remainder, 1e18, settlementPrice, rounding);
    } else {
      (uint spot,) = a.spotFeed.getSpot();
      cashMoved = Math.mulDiv(remainder, spot, 1e18, rounding);
    }
    if (cashMoved != 0) _move(a.subAccounts, from, to, a.cash, cashMoved.toInt256());
  }

  /// @dev BaseManager._symmetricManagerAdjustment, for an asset with subId 0
  function _move(ISubAccounts subAccounts, uint from, uint to, IAsset asset, int amount) internal {
    subAccounts.managerAdjustment(
      ISubAccounts.AssetAdjustment({acc: from, asset: asset, subId: 0, amount: -amount, assetData: bytes32(0)})
    );
    subAccounts.managerAdjustment(
      ISubAccounts.AssetAdjustment({acc: to, asset: asset, subId: 0, amount: amount, assetData: bytes32(0)})
    );
  }
}
