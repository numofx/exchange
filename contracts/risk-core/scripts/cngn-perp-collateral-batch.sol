// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {ManagerWhitelist} from "../src/assets/utils/ManagerWhitelist.sol";
import {PositionTracking} from "../src/assets/utils/PositionTracking.sol";

interface IOwnable2StepAccept {
  function acceptOwnership() external;
}

interface IOwned {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

/**
 * @title CNGNPerpCollateralBatch
 * @notice THE single definition of the vault batch that lets cNGN be posted as margin on
 *         USDCcNGN-PERP: a dedicated cNGN escrow (WrappedERC20Asset) whitelisted on the perp SRM
 *         as a BASE asset, haircut by the margin factor the fork test sized, under a collateral
 *         cap. Both the deploy script (which serialises build() for MPCVault) and the fork test
 *         (which executes build() against live Base state) call this and nothing else.
 *
 * @dev Why cNGN margin is a haircut and not a price: cNGN collateral carries the very risk the perp
 *      trades. A long-naira account posting cNGN loses on the position AND on the collateral in
 *      the same move, so the factor must leave it solvent through the step the venue plans for
 *      (25%, the SecurityModule's own sizing case). test/fork/CngnPerpCollateralFork.t.sol finds
 *      the largest factor that does, and the deploy script refuses any other value.
 *
 * @dev Borrowing goes OFF in the same batch. Once cNGN counts as margin, `borrowingEnabled` is a
 *      USDC loan facility: an account may withdraw cash it does not have, down to initial margin,
 *      against its cNGN at the haircut, out of the pool's real USDC (the keeper's, the maker's, the
 *      SecurityModule's). Losses settle into negative cash and positions close with it off
 *      (CngnPerpStackFork pins that); the flag only decides whether the venue lends. It does not.
 *
 * @dev Ordering (six separate EOA transactions by the vault; every prefix is a safe place to stop):
 *      custody of the escrow first, borrowing off, then the SRM's view of the asset (factor, then
 *      whitelist), then the cap, and the escrow's own manager whitelist LAST -- nothing can be
 *      deposited until it.
 */
library CNGNPerpCollateralBatch {
  uint internal constant ACTION_COUNT = 6;

  struct Ctx {
    /// @dev Who executes the batch: the MPCVault on mainnet, the test contract on a fork.
    address vault;
    address srm;
    address escrow;
    address indexFeed;
    uint marketId;
    /// @dev 18dp: the share of the oracle value that counts as maintenance margin.
    uint marginFactor;
    /// @dev 18dp: multiplied in again for initial margin.
    uint imScale;
    /// @dev Whole cNGN, 18dp, summed over every account under the SRM: the collateral cap.
    uint cap;
  }

  /// @dev Refuse to emit calldata for a world that has moved. Every check is something that would
  ///      revert mid-batch, or succeed while margining against the wrong feed.
  function checkPreconditions(Ctx memory ctx) internal view {
    require(IOwned(ctx.srm).owner() == ctx.vault, "PRE: srm owner is not the recorded vault");
    require(
      IOwned(ctx.escrow).pendingOwner() == ctx.vault || IOwned(ctx.escrow).owner() == ctx.vault,
      "PRE: escrow is not nominated to the vault"
    );
    require(!ManagerWhitelist(ctx.escrow).whitelistedManager(ctx.srm), "PRE: escrow already open to the srm");
    (ISpotFeed spot,,) = StandardManager(ctx.srm).getMarketFeeds(ctx.marketId);
    require(address(spot) == ctx.indexFeed, "PRE: market spot feed is not the perp index feed");
    require(ctx.marginFactor > 0 && ctx.marginFactor <= 1e18, "PRE: margin factor out of range");
    require(ctx.imScale > 0 && ctx.imScale <= 1e18, "PRE: IM scale out of range");
    require(ctx.cap > 0, "PRE: a zero cap would whitelist an asset nobody can deposit");
  }

  function build(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ACTION_COUNT);
    data = new bytes[](ACTION_COUNT);
    descriptions = new string[](ACTION_COUNT);

    descriptions[0] = "cngnEscrow.acceptOwnership() [custody; the escrow was nominated at deploy]";
    to[0] = ctx.escrow;
    data[0] = abi.encodeCall(IOwnable2StepAccept.acceptOwnership, ());

    descriptions[1] = "srm.setBorrowingEnabled(false) [no USDC loans against cNGN; losses still settle]";
    to[1] = ctx.srm;
    data[1] = abi.encodeCall(StandardManager.setBorrowingEnabled, (false));

    descriptions[2] =
    "srm.setBaseAssetMarginFactor(marketId, factor, imScale) [the haircut, before the asset can count]";
    to[2] = ctx.srm;
    data[2] = abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, ctx.marginFactor, ctx.imScale));

    descriptions[3] = "srm.whitelistAsset(cngnEscrow, marketId, Base) [SRM side of the gate; escrow still shut]";
    to[3] = ctx.srm;
    data[3] = abi.encodeCall(
      StandardManager.whitelistAsset, (IAsset(ctx.escrow), ctx.marketId, IStandardManager.AssetType.Base)
    );

    descriptions[4] = "cngnEscrow.setTotalPositionCap(srm, cap) [collateral cap in place before deposits are possible]";
    to[4] = ctx.escrow;
    data[4] = abi.encodeCall(PositionTracking.setTotalPositionCap, (IManager(ctx.srm), ctx.cap));

    descriptions[5] = "cngnEscrow.setWhitelistManager(srm, true) [THE ENABLING SWITCH - nothing can enter before this]";
    to[5] = ctx.escrow;
    data[5] = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (ctx.srm, true));
  }

  /// @dev Commits to targets, calldata and ordering, not to the prose.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    return keccak256(acc);
  }

  /// @dev What MPCVault shows for one action: keccak256(abi.encodePacked(to, keccak256(data))).
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }

  /// @dev Executes the batch as the caller: the fork test's path (the test owns the contracts).
  function execute(Ctx memory ctx) internal {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      (bool ok, bytes memory ret) = to[i].call(data[i]);
      require(ok, string.concat("batch action failed: ", _revertReason(ret)));
    }
  }

  function _revertReason(bytes memory ret) private pure returns (string memory) {
    if (ret.length < 68) return "(no reason)";
    assembly {
      ret := add(ret, 0x04)
    }
    return abi.decode(ret, (string));
  }
}
