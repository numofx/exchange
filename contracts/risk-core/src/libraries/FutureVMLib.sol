// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";

/**
 * @title FutureVMLib
 * @notice MarginEngine's variation margin for American-terms cNGN futures (FutureAsset v2: USDC per cNGN, a cNGN
 *         contract, VM in USDC), as an external library: delegatecalled, so it runs with the engine's address
 *         (SubAccounts.managerAdjustment accepts it as the manager) and keeps the engine under the contract size limit.
 * @dev    VM is USDC, so it moves as cash through the engine's pool account and nothing is converted: a loser pays the
 *         pool, the pool pays a winner. Cash may go negative on either side (a loser borrows, as on a perp's PnL; the
 *         pool is never risk checked), so settlement never reverts on a shortfall and the risk check that follows it
 *         is what catches an account that cannot pay.
 *
 *         v2. The v1 library (cNGN VM paid as base first, cash remainder at spot) is src/legacy/v1/FutureVMLibV1.
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
    /// @dev the futures margin requirement, initial or maintenance, plus the depeg multiplier (initial only), as
    ///      fractions of notional
    uint requirement;
  }

  /// @dev The engine itself: delegatecalled, so address(this) is the MarginEngine, and its getters are read back.
  function _engine() private view returns (IMarginEngine) {
    return IMarginEngine(address(this));
  }

  /// @notice Realise VM on every future the account holds.
  function settleAll(ISubAccounts subAccounts, IAsset cash, uint pool, uint accountId) external {
    ISubAccounts.AssetBalance[] memory balances = subAccounts.getAccountBalances(accountId);
    for (uint i = 0; i < balances.length; ++i) {
      if (_engine().assetDetails(balances[i].asset).assetType != IMarginEngine.AssetType.Future) continue;
      _settle(subAccounts, cash, pool, IFutureAsset(address(balances[i].asset)), accountId, uint96(balances[i].subId));
    }
  }

  /// @notice Realise VM on one series: a position an adjustment just closed, which settleAll no longer sees.
  function settleOne(
    ISubAccounts subAccounts,
    IAsset cash,
    uint pool,
    IFutureAsset future,
    uint accountId,
    uint96 subId
  ) external {
    _settle(subAccounts, cash, pool, future, accountId, subId);
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
      if (_closeOut(subAccounts, cash, pool, future, accountId, subId)) found = true;
    }
    if (!found) revert IMarginEngine.ME_NotFuture();
  }

  /// @dev Realise an account's VM on one series, as cash between it and the pool.
  function _settle(ISubAccounts subAccounts, IAsset cash, uint pool, IFutureAsset future, uint accountId, uint96 subId)
    private
  {
    int vmDelta = future.settleAccountVM(accountId, subId);
    if (vmDelta == 0) return;
    if (vmDelta > 0) _move(subAccounts, pool, accountId, cash, vmDelta);
    else _move(subAccounts, accountId, pool, cash, -vmDelta);
    emit IMarginEngine.VMSettled(accountId, subId, vmDelta, 0, SignedMath.abs(vmDelta));
  }

  /**
   * @notice Margin for every futures position in a market, gross: the requirement on each position's USDC notional,
   *         |position| x contractSize (cNGN) x mark (USDC per cNGN), plus its unsettled VM, which is cash, at par.
   * @dev    Notional is at the series' own mark, as StandardManager margins a dated future, so it moves with the price
   *         as a perp's does; once a series is settled its mark is the settlement price.
   * @return margin the margin contribution, normally negative
   * @return pendingMtM the unsettled VM, in cash
   */
  function marketMargin(MarketInputs memory m, IMarginEngine.FuturePosition[] memory positions)
    external
    view
    returns (int margin, int pendingMtM)
  {
    uint size = m.future.contractSize();
    for (uint i = 0; i < positions.length; ++i) {
      uint mark = m.future.futureContracts(positions[i].subId).markPrice;
      uint notional = SignedMath.abs(positions[i].balance).multiplyDecimal(size).multiplyDecimal(mark);
      margin -= notional.multiplyDecimal(m.requirement).toInt256();

      int pending = m.future.getPendingVM(m.accountId, positions[i].subId);
      pendingMtM += pending;
      margin += pending;
    }
  }

  /**
   * @notice Close out one series on one future, if it is that future's: realise the last VM (already accrued to the
   *         settlement price by the asset), then remove the position. Reverts if the series is listed but not settled.
   * @return listed whether `subId` is a series of `future` (if not, nothing was done)
   */
  function _closeOut(
    ISubAccounts subAccounts,
    IAsset cash,
    uint pool,
    IFutureAsset future,
    uint accountId,
    uint96 subId
  ) private returns (bool listed) {
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    if (!c.listed) return false;
    if (!c.settled) revert IMarginEngine.ME_NotSettled();
    _settle(subAccounts, cash, pool, future, accountId, subId);
    int position = subAccounts.getBalance(accountId, future, subId);
    if (position != 0) {
      subAccounts.managerAdjustment(ISubAccounts.AssetAdjustment(accountId, future, subId, -position, bytes32(0)));
      emit IMarginEngine.PositionClosedOut(accountId, subId, position);
    }
    return true;
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
