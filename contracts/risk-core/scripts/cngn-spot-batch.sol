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
      acc = abi.encodePacked(acc, to[i], keccak256(data[i]));
    }
    return keccak256(acc);
  }
}
