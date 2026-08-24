// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
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

interface IERC20Supply {
  function totalSupply() external view returns (uint);
}

/**
 * @title CNGNSpotBatch
 * @notice THE single definition of the USDCcNGN-SPOT vault batch.
 *
 * @dev Both sides of the guarantee call this and nothing else:
 *        - scripts/register-cngn-spot-srm.s.sol serialises build() into the artifact the vault signs
 *        - test/fork/CNGNSpotSRMBaseFork.t.sol executes build() against live Base state
 *      so the batch under test and the batch signed cannot diverge. Do not inline an action list
 *      anywhere else.
 *
 * @dev hash() pins the shape. test/scripts/CNGNSpotBatchShape.t.sol asserts it against a committed
 *      constant for a fixed context, so any edit to the ordering, targets or calldata trips a test
 *      and has to be acknowledged deliberately. The script also writes the hash of the real context
 *      into the artifact, so a signer can regenerate it and confirm the JSON in front of them is
 *      what this code produces.
 */
library CNGNSpotBatch {
  uint internal constant ACTION_COUNT = 11;

  struct Ctx {
    address srm;
    address wrappedCngn;
    address cngnFeed;
    address stableFeed;
    uint marketId;
    uint baseCap;
  }

  /// @dev Refuse to emit calldata for a world that has moved. Lives here rather than in the script
  ///      so it can be tested directly against a fork. Every check is either something that would
  ///      revert mid-batch -- and the batch is 11 separate EOA transactions, so a mid-batch revert
  ///      is real partial state, not an atomic rollback -- or something that would silently succeed
  ///      while doing the wrong thing.
  function checkPreconditions(Ctx memory ctx, address cngnToken, address liveCngnFeed, uint tolerancePct)
    internal
    view
  {
    address vault = IOwned(ctx.srm).owner();
    require(vault != address(0), "PRE: srm owner is zero");
    require(IOwned(ctx.wrappedCngn).owner() == vault, "PRE: srm and wrappedCngn have different owners");

    // createMarket assigns ++lastMarketId. If a market was created since this id was resolved, every
    // later action in the batch targets the wrong market.
    require(ctx.marketId == StandardManager(ctx.srm).lastMarketId() + 1, "PRE: marketId is stale - re-run");
    require(
      address(StandardManager(ctx.srm).assetMap(ctx.marketId, IStandardManager.AssetType.Base)) == address(0),
      "PRE: market already has a base asset"
    );

    require(ctx.cngnFeed.code.length > 0, "PRE: cngn static feed has no code");
    require(ctx.stableFeed.code.length > 0, "PRE: stable static feed has no code");

    // actions 8 and 9 are acceptOwnership(); they revert unless the vault is already pending owner
    require(IOwned(ctx.cngnFeed).pendingOwner() == vault, "PRE: vault is not pending owner of cngn feed");
    require(IOwned(ctx.stableFeed).pendingOwner() == vault, "PRE: vault is not pending owner of stable feed");

    (uint stablePrice,) = ISpotFeed(ctx.stableFeed).getSpot();
    require(stablePrice == 1e18, "PRE: stable static feed is not 1e18");

    // ORIENTATION. The SRM's Base convention is USD-per-base, so this must be USDC-per-cNGN, far
    // below 1e18. The live DFXM feed is cNGN-per-USDC (~1345e18); wiring it in inflates
    // mark-to-market by spot^2. This is the check that catches that substitution.
    (uint usdcPerCngn,) = ISpotFeed(ctx.cngnFeed).getSpot();
    require(usdcPerCngn > 0, "PRE: cngn static feed is 0");
    require(usdcPerCngn < 1e18, "PRE: cngn static feed looks inverted - expected USDC-per-cNGN");

    // DRIFT. The static price is frozen at deploy time; if cNGN has moved materially since, the
    // venue would launch marking against a rate nobody chose.
    (uint cngnPerUsdc,) = ISpotFeed(liveCngnFeed).getSpot();
    require(cngnPerUsdc > 0, "PRE: live cNGN feed returned 0");
    uint expected = 1e36 / cngnPerUsdc;
    uint diff = usdcPerCngn > expected ? usdcPerCngn - expected : expected - usdcPerCngn;
    require(diff * 100 <= expected * tolerancePct, "PRE: static feed has drifted from live - redeploy feeds");

    require(IERC20Supply(cngnToken).totalSupply() > 0, "PRE: cNGN totalSupply is 0");
    require(ctx.baseCap > 0, "PRE: cap is 0");
  }

  function build(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ACTION_COUNT);
    data = new bytes[](ACTION_COUNT);
    descriptions = new string[](ACTION_COUNT);

    // no oracle contingency: at marginFactor 0 the base margin is 0 and _getBaseMarginAndMtM returns
    // before the contingency penalty, so a non-zero threshold here would be inert config. This is
    // also why the static feeds' confidence value is never read on the spot path.
    IStandardManager.OracleContingencyParams memory ocParams =
      IStandardManager.OracleContingencyParams({perpThreshold: 0, optionThreshold: 0, baseThreshold: 0, OCFactor: 0});

    descriptions[0] = "srm.createMarket(CNGN)";
    to[0] = ctx.srm;
    data[0] = abi.encodeCall(StandardManager.createMarket, ("CNGN"));

    descriptions[1] = "wrappedCngn.setWhitelistManager(srm) [additive: DFXM stays whitelisted]";
    to[1] = ctx.wrappedCngn;
    data[1] = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (ctx.srm, true));

    descriptions[2] = "wrappedCngn.setTotalPositionCap(srm) [blocks deposits at cap, not trading]";
    to[2] = ctx.wrappedCngn;
    data[2] = abi.encodeCall(PositionTracking.setTotalPositionCap, (IManager(ctx.srm), ctx.baseCap));

    descriptions[3] = "srm.whitelistAsset(wrappedCngn, Base)";
    to[3] = ctx.srm;
    data[3] = abi.encodeCall(
      StandardManager.whitelistAsset, (IAsset(ctx.wrappedCngn), ctx.marketId, IStandardManager.AssetType.Base)
    );

    descriptions[4] = "srm.setOraclesForMarket(staticCngnFeed) [USDC-per-cNGN: SRM Base convention]";
    to[4] = ctx.srm;
    data[4] = abi.encodeCall(
      StandardManager.setOraclesForMarket,
      (ctx.marketId, ISpotFeed(ctx.cngnFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
    );

    descriptions[5] = "srm.setOracleContingencyParams(zeroed)";
    to[5] = ctx.srm;
    data[5] = abi.encodeCall(StandardManager.setOracleContingencyParams, (ctx.marketId, ocParams));

    descriptions[6] = "srm.setBaseAssetMarginFactor(0) [cNGN gives zero margin credit]";
    to[6] = ctx.srm;
    data[6] = abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, 0, 0));

    descriptions[7] = "srm.setBorrowingEnabled(false) [GLOBAL to the SRM, not per-market]";
    to[7] = ctx.srm;
    data[7] = abi.encodeCall(StandardManager.setBorrowingEnabled, (false));

    descriptions[8] = "staticCngnFeed.acceptOwnership() [must be the vault]";
    to[8] = ctx.cngnFeed;
    data[8] = abi.encodeCall(IOwnable2StepAccept.acceptOwnership, ());

    descriptions[9] = "staticStableFeed.acceptOwnership() [must be the vault]";
    to[9] = ctx.stableFeed;
    data[9] = abi.encodeCall(IOwnable2StepAccept.acceptOwnership, ());

    descriptions[10] = "srm.setStableFeed(staticStableFeed) [GLOBAL: also affects market 1]";
    to[10] = ctx.srm;
    data[10] = abi.encodeCall(StandardManager.setStableFeed, (ISpotFeed(ctx.stableFeed)));
  }

  /// @dev commits to targets, calldata and ordering. Descriptions are prose and deliberately
  ///      excluded: rewording a comment must not invalidate a signature.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);

    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    return keccak256(acc);
  }

  /// @dev The vault is an EOA (codesize 0), not a Safe: there is no MultiSend and no single proposed
  ///      payload. Each action is signed as its own transaction, so the unit a signer can actually
  ///      compare against what their MPC console displays is one (to, data) pair. This is that
  ///      digest. `value` is omitted because every action in this batch is value 0 and the verifier
  ///      asserts that separately.
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }
}
