// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {CNGNSpotBatch} from "../../scripts/cngn-spot-batch.sol";

/**
 * @dev Pins the shape of the USDCcNGN-SPOT vault batch.
 *
 *      scripts/register-cngn-spot-srm.s.sol serialises CNGNSpotBatch.build() into the artifact the
 *      vault signs, and test/fork/CNGNSpotSRMBaseFork.t.sol executes the same build() against live
 *      Base state. That makes the two agree by construction, but it does not stop someone editing
 *      the library and silently changing what gets signed.
 *
 *      This does. GOLDEN_BATCH_HASH commits to the targets, calldata and ordering for a fixed
 *      context. Any change to the action list fails here and has to be acknowledged by updating the
 *      constant in the same commit -- which puts the change in the diff a reviewer reads.
 *
 *      If this test fails and you did mean it: re-run, take the printed hash, update the constant,
 *      and say what changed in the commit message. Re-derive the artifact afterwards; a signature
 *      over the old batch is no longer valid for the new one.
 */
contract TestCNGNSpotBatchShape is Test {
  /// @dev arbitrary but fixed: the hash must not move because a real address or cap changed
  address internal constant SRM = address(0x1111111111111111111111111111111111111111);
  address internal constant WRAPPED_CNGN = address(0x2222222222222222222222222222222222222222);
  address internal constant CNGN_FEED = address(0x3333333333333333333333333333333333333333);
  address internal constant STABLE_FEED = address(0x4444444444444444444444444444444444444444);
  uint internal constant MARKET_ID = 2;
  uint internal constant BASE_CAP = 204_853_778e18;

  bytes32 internal constant GOLDEN_BATCH_HASH = 0x1efd2b127a8a85eb95996e95b959c6f349ede04ee5b799384fc8be4496665079;

  function _ctx() internal pure returns (CNGNSpotBatch.Ctx memory) {
    return CNGNSpotBatch.Ctx({
      srm: SRM,
      wrappedCngn: WRAPPED_CNGN,
      cngnFeed: CNGN_FEED,
      stableFeed: STABLE_FEED,
      marketId: MARKET_ID,
      baseCap: BASE_CAP
    });
  }

  function testBatchShapeIsPinned() public {
    bytes32 actual = CNGNSpotBatch.hash(_ctx());
    if (actual != GOLDEN_BATCH_HASH) {
      console2.log("batch shape changed. new hash:");
      console2.log(vm.toString(actual));
    }
    assertEq(actual, GOLDEN_BATCH_HASH, "vault batch shape changed - update GOLDEN_BATCH_HASH deliberately");
  }

  function testBatchIsElevenActionsInOrder() public {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = CNGNSpotBatch.build(_ctx());

    assertEq(to.length, 11, "batch must be 11 actions");
    assertEq(data.length, 11);
    assertEq(descriptions.length, 11);

    // the two acceptOwnership calls must target the feeds, not the SRM: they are the reason the
    // batch has to execute as the vault rather than a deployer
    assertEq(to[8], CNGN_FEED, "action 8 must accept ownership of the cngn feed");
    assertEq(to[9], STABLE_FEED, "action 9 must accept ownership of the stable feed");
    assertEq(data[8], abi.encodeWithSignature("acceptOwnership()"));
    assertEq(data[9], abi.encodeWithSignature("acceptOwnership()"));

    // createMarket must be first: every later action references the id it assigns
    assertEq(to[0], SRM);
    assertEq(data[0], abi.encodeWithSignature("createMarket(string)", "CNGN"));

    // the spot feed wired in must be the static one, never the live DFXM feed (wrong orientation)
    assertEq(to[4], SRM);
    assertEq(
      data[4],
      abi.encodeWithSignature(
        "setOraclesForMarket(uint256,address,address,address)", MARKET_ID, CNGN_FEED, address(0), address(0)
      )
    );

    // marginFactor 0 is the single thing containing the frozen price; assert it explicitly
    assertEq(data[6], abi.encodeWithSignature("setBaseAssetMarginFactor(uint256,uint256,uint256)", MARKET_ID, 0, 0));
  }

  /// @dev the hash must be sensitive to every field a signer cares about
  /// @dev per-action digests are what a signer compares against their MPC console: the vault is an
  ///      EOA, so each action is its own transaction rather than one MultiSend payload
  function testPerActionDigestsAreDistinctAndOrderIndependent() public {
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(_ctx());

    for (uint i = 0; i < to.length; ++i) {
      bytes32 di = CNGNSpotBatch.actionHash(to[i], data[i]);
      assertTrue(di != bytes32(0), "action digest must be non-zero");
      for (uint j = i + 1; j < to.length; ++j) {
        assertTrue(di != CNGNSpotBatch.actionHash(to[j], data[j]), "two actions must never share a digest");
      }
    }

    // an action's digest must depend on the target, not just the calldata: actions 8 and 9 are the
    // same acceptOwnership() calldata to different feeds
    assertEq(data[8], data[9], "8 and 9 are the same call");
    assertTrue(
      CNGNSpotBatch.actionHash(to[8], data[8]) != CNGNSpotBatch.actionHash(to[9], data[9]),
      "identical calldata to different targets must not collide"
    );
  }

  function testHashMovesWithEveryContextField() public {
    bytes32 base = CNGNSpotBatch.hash(_ctx());

    CNGNSpotBatch.Ctx memory c = _ctx();
    c.srm = address(0xdead);
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on srm");

    c = _ctx();
    c.cngnFeed = address(0xdead);
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on the spot feed");

    c = _ctx();
    c.stableFeed = address(0xdead);
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on the stable feed");

    c = _ctx();
    c.baseCap = BASE_CAP + 1;
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on the cap");

    c = _ctx();
    c.marketId = MARKET_ID + 1;
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on the market id");

    c = _ctx();
    c.wrappedCngn = address(0xdead);
    assertTrue(CNGNSpotBatch.hash(c) != base, "hash must depend on the wrapped asset");
  }
}
