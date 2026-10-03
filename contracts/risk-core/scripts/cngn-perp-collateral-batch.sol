// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IInterestRateModel} from "../src/interfaces/IInterestRateModel.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {InterestRateModel} from "../src/assets/InterestRateModel.sol";
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
 * @notice THE single definition of the two vault batches that let cNGN be posted as margin on
 *         USDCcNGN-PERP: a dedicated cNGN escrow (WrappedERC20Asset) whitelisted on the perp SRM
 *         as a BASE asset, haircut by the margin factor the fork test sized, under a collateral
 *         cap, with the cash's rate model replaced by one with a higher floor. `build()` is the
 *         configuring batch; `buildEnable()` is the single action that opens cNGN deposits, signed
 *         on its own once the keeper, markets-service and app that enforce the venue's rules on
 *         cNGN accounts are live. Both the deploy script (which serialises them for MPCVault) and
 *         the fork test (which executes them against live Base state) call this and nothing else.
 *
 * @dev Why cNGN margin is a haircut and not a price: cNGN collateral carries the very risk the perp
 *      trades. A long-naira account posting cNGN loses on the position AND on the collateral in
 *      the same move, so the factor must leave it solvent through the step the venue plans for
 *      (25%, the SecurityModule's own sizing case). test/fork/CngnPerpCollateralFork.t.sol finds
 *      the largest factor that does, and the deploy script refuses any other value.
 *
 * @dev Borrowing stays ON, and the batch does not touch it. The SRM refuses any negative cash delta
 *      that lands below zero while borrowing is off, and an account holding only cNGN pays its
 *      taker fee from zero cash: with borrowing off it could not open, and after a settled loss it
 *      could not close (CngnPerpCollateralFork.testTakerFeeOnACngnOnlyAccountNeedsBorrowing). The
 *      same flag lets an account withdraw USDC against its cNGN down to initial margin on chain, so
 *      the batch bounds that three ways: the collateral cap (8M cNGN: ~$3k of borrowing at the
 *      haircut), a rate model with a higher floor, and -- off chain -- markets-service refusing a
 *      venue-routed withdrawal that would take cash below zero.
 *
 * @dev Ordering of build() (five separate EOA transactions by the vault; every prefix is a safe
 *      place to stop): custody of the escrow, the SRM's view of the asset (factor, then whitelist),
 *      the cap, the rate model. None of them lets cNGN in. buildEnable() is the escrow's own manager
 *      whitelist, the one action after which deposits are possible.
 */
library CNGNPerpCollateralBatch {
  uint internal constant ACTION_COUNT = 5;
  uint internal constant ENABLE_ACTION_COUNT = 1;

  struct Ctx {
    /// @dev Who executes the batch: the MPCVault on mainnet, the test contract on a fork.
    address vault;
    address srm;
    address escrow;
    /// @dev The perp's CashAsset, whose rate model the batch replaces.
    address cash;
    /// @dev The replacement InterestRateModel, deployed by the script with the higher floor.
    address rateModel;
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
    require(
      StandardManager(ctx.srm).borrowingEnabled(), "PRE: borrowing is off; a cNGN-only account could not pay its fee"
    );
    require(IOwned(ctx.cash).owner() == ctx.vault, "PRE: cash owner is not the recorded vault");
    require(address(CashAsset(ctx.cash).rateModel()) != ctx.rateModel, "PRE: the cash already uses this rate model");
    require(
      InterestRateModel(ctx.rateModel).minRate()
        > InterestRateModel(address(CashAsset(ctx.cash).rateModel())).minRate(),
      "PRE: the new rate model does not raise the floor"
    );
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

    descriptions[1] =
    "srm.setBaseAssetMarginFactor(marketId, factor, imScale) [the haircut, before the asset can count]";
    to[1] = ctx.srm;
    data[1] = abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, ctx.marginFactor, ctx.imScale));

    descriptions[2] = "srm.whitelistAsset(cngnEscrow, marketId, Base) [SRM side of the gate; escrow still shut]";
    to[2] = ctx.srm;
    data[2] = abi.encodeCall(
      StandardManager.whitelistAsset, (IAsset(ctx.escrow), ctx.marketId, IStandardManager.AssetType.Base)
    );

    descriptions[3] = "cngnEscrow.setTotalPositionCap(srm, cap) [collateral cap in place before deposits are possible]";
    to[3] = ctx.escrow;
    data[3] = abi.encodeCall(PositionTracking.setTotalPositionCap, (IManager(ctx.srm), ctx.cap));

    descriptions[4] = "cash.setInterestRateModel(rateModel) [the higher floor on borrowed cash]";
    to[4] = ctx.cash;
    data[4] = abi.encodeCall(CashAsset.setInterestRateModel, (IInterestRateModel(ctx.rateModel)));
  }

  /// @dev The one action that opens cNGN deposits. Its own batch: signed only once the keeper,
  ///      markets-service and app are deployed and the fork rehearsal has run a cNGN scenario
  ///      against the real escrow.
  function buildEnable(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ENABLE_ACTION_COUNT);
    data = new bytes[](ENABLE_ACTION_COUNT);
    descriptions = new string[](ENABLE_ACTION_COUNT);
    descriptions[0] = "cngnEscrow.setWhitelistManager(srm, true) [THE ENABLING SWITCH - cNGN deposits open here]";
    to[0] = ctx.escrow;
    data[0] = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (ctx.srm, true));
  }

  /// @dev Commits to targets, calldata and ordering of BOTH batches, not to the prose.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    (address[] memory enableTo, bytes[] memory enableData,) = buildEnable(ctx);
    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    for (uint i = 0; i < ENABLE_ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(enableTo[i], enableData[i]));
    }
    return keccak256(acc);
  }

  /// @dev What MPCVault shows for one action: keccak256(abi.encodePacked(to, keccak256(data))).
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }

  /// @dev Executes the configuring batch as the caller: the fork test's path (the test owns the contracts).
  function execute(Ctx memory ctx) internal {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      (bool ok, bytes memory ret) = to[i].call(data[i]);
      require(ok, string.concat("batch action failed: ", _revertReason(ret)));
    }
  }

  /// @dev Executes the enabling action as the caller.
  function executeEnable(Ctx memory ctx) internal {
    (address[] memory to, bytes[] memory data,) = buildEnable(ctx);
    for (uint i = 0; i < ENABLE_ACTION_COUNT; ++i) {
      (bool ok, bytes memory ret) = to[i].call(data[i]);
      require(ok, string.concat("enable action failed: ", _revertReason(ret)));
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
