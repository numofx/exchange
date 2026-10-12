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

  /// @dev What marketMargin needs about the account and its market
  struct MarketInputs {
    IFutureAsset future;
    uint accountId;
    uint spotPrice;
    /// @dev the futures margin requirement, initial or maintenance, plus the depeg multiplier (initial only), as
    ///      fractions of notional
    uint requirement;
    /// @dev the market's base margin factor, already scaled for initial margin
    uint marginFactor;
    /// @dev the base the account holds in the market, which its losses are paid from first
    uint heldBase;
    ISpotFeed stableFeed;
  }

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
   *         requirement (a contract is a fixed USDC amount whatever its price), plus each position's unsettled VM, valued
   *         as settlement will pay it.
   * @dev    Series are taken in the order settlement takes them (the account's balance order). A loss is paid from the
   *         base the account holds first: that part costs its margin only the base factor (held base was counted at
   *         it), the rest is cash at par. So for losses, margin before settlement equals margin after.
   *         A gain counts at the base factor, as the base the pool pays it in. If the pool is short, settlement pays the
   *         rest in cash at par: then the view is below what settlement gives, never above. It is not exact there
   *         because the pool is shared: which winner gets base depends on who settles first. For the same reason a
   *         gain is not counted as base that later losses in the view could spend.
   * @return margin the margin contribution, normally negative
   * @return pendingMtM the unsettled VM at spot, at par, in stable
   */
  function marketMargin(MarketInputs memory m, IMarginEngine.FuturePosition[] memory positions)
    external
    view
    returns (int margin, int pendingMtM)
  {
    uint size = m.future.contractSize();
    for (uint i = 0; i < positions.length; ++i) {
      uint notional = SignedMath.abs(positions[i].balance).multiplyDecimal(size);
      margin -= notional.multiplyDecimal(m.requirement).toInt256();

      int pending = m.future.getPendingVM(m.accountId, positions[i].subId);
      if (pending == 0) continue;
      pendingMtM += pending.multiplyDecimal(m.spotPrice.toInt256());
      margin += _pendingMargin(m, pending);
    }
    // mark-to-market is denominated in stable, as StandardManager's base mark-to-market is
    if (pendingMtM != 0) {
      (uint stablePrice,) = m.stableFeed.getSpot();
      pendingMtM = pendingMtM.divideDecimal(stablePrice.toInt256());
    }
  }

  /// @dev One series' unsettled VM as settlement will pay it; a loss spends `m.heldBase`, so later losses see less.
  function _pendingMargin(MarketInputs memory m, int pending) private pure returns (int) {
    if (pending > 0) return uint(pending).multiplyDecimal(m.spotPrice).multiplyDecimal(m.marginFactor).toInt256();
    uint owed = uint(-pending);
    uint fromHeld = owed < m.heldBase ? owed : m.heldBase;
    m.heldBase -= fromHeld;
    return -(fromHeld.multiplyDecimal(m.spotPrice).multiplyDecimal(m.marginFactor)
        + (owed - fromHeld).multiplyDecimal(m.spotPrice))
    .toInt256();
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
