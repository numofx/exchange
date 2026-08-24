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

  bytes32 internal constant GOLDEN_BATCH_HASH = 0x1fba974f6e4e688fe4c70a7e0fee43c02eda1bc21af67a4574330ef1ff48aec2;

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

    // 0-1: custody first. The old ordering left these until action 8-9, so abandoning the batch
    // early stranded both feeds on the deployer key -- the lost-key mode this repo records once.
    assertEq(to[0], CNGN_FEED, "action 0 must accept ownership of the cngn feed");
    assertEq(to[1], STABLE_FEED, "action 1 must accept ownership of the stable feed");
    assertEq(data[0], abi.encodeWithSignature("acceptOwnership()"));
    assertEq(data[1], abi.encodeWithSignature("acceptOwnership()"));

    // 2: the old stable feed and its 3600s staleness halt must be gone before anything else
    assertEq(to[2], SRM);
    assertEq(data[2], abi.encodeWithSignature("setStableFeed(address)", STABLE_FEED));

    // 3: tightening globals precedes creating anything
    assertEq(data[3], abi.encodeWithSignature("setBorrowingEnabled(bool)", false));

    // 4: the market cannot exist before the four calls that require it
    assertEq(data[4], abi.encodeWithSignature("createMarket(string)", "CNGN"));

    // 5: marginFactor 0 is the single thing containing the frozen price, and it is pinned before
    // the asset is reachable rather than after
    assertEq(data[5], abi.encodeWithSignature("setBaseAssetMarginFactor(uint256,uint256,uint256)", MARKET_ID, 0, 0));

    // 7: the spot feed wired in must be the static one, never the live DFXM feed (wrong orientation)
    assertEq(
      data[7],
      abi.encodeWithSignature(
        "setOraclesForMarket(uint256,address,address,address)", MARKET_ID, CNGN_FEED, address(0), address(0)
      )
    );

    // 10: the enabling switch is last. Until the SRM is whitelisted on the asset, _checkManager
    // rejects every adjustment, so every earlier prefix is a venue that cannot be used.
    assertEq(to[10], WRAPPED_CNGN, "the last action must open the asset side");
    assertEq(data[10], abi.encodeWithSignature("setWhitelistManager(address,bool)", SRM, true));
  }

  /// @dev the property the ordering exists for: no prefix can be traded against. Both gates --
  ///      whitelistAsset on the SRM and setWhitelistManager on the asset -- are required for an
  ///      adjustment, and the second is the final action.
  function testNoPrefixBeforeTheLastActionCanBeTraded() public {
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(_ctx());

    bytes memory enabling = abi.encodeWithSignature("setWhitelistManager(address,bool)", SRM, true);
    for (uint i = 0; i < to.length - 1; ++i) {
      assertTrue(
        !(to[i] == WRAPPED_CNGN && keccak256(data[i]) == keccak256(enabling)),
        "the asset side must not open before the final action"
      );
    }
    assertEq(keccak256(data[10]), keccak256(enabling));
  }

  /// @dev custody is secured before anything functional changes
  function testOwnershipIsAcceptedBeforeAnyConfiguration() public {
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(_ctx());

    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    assertEq(keccak256(data[0]), keccak256(accept));
    assertEq(keccak256(data[1]), keccak256(accept));

    // and neither feed is left out
    assertTrue(
      (to[0] == CNGN_FEED && to[1] == STABLE_FEED) || (to[0] == STABLE_FEED && to[1] == CNGN_FEED),
      "both feeds must have ownership accepted in the first two actions"
    );
  }

  /// @dev scripts/ops/resolve_cngn_action6.py turns action 6's `done*` into a positive read by
  ///      decoding the market id out of the transaction's calldata -- the OracleContingencySet event
  ///      itself carries no market id. That resolver hardcodes the selector and assumes marketId is
  ///      the first word after it. Both assumptions are pinned here, so a signature change breaks a
  ///      test instead of silently making the resolver match nothing.
  function testActionSixCalldataShapeMatchesTheOpsResolver() public {
    (, bytes[] memory data,) = CNGNSpotBatch.build(_ctx());
    bytes memory raw = data[6];

    bytes4 selector;
    uint firstWord;
    assembly {
      selector := mload(add(raw, 0x20))
      firstWord := mload(add(raw, 0x24))
    }

    assertEq(
      selector,
      bytes4(keccak256("setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))")),
      "resolver selector would no longer match"
    );
    assertEq(firstWord, MARKET_ID, "resolver assumes marketId is the first word after the selector");

    // four static words, so nothing after marketId is a pointer the resolver would have to
    // follow. 4 + 32 + 4*32 = 164.
    assertEq(raw.length, 164, "contingency params must stay a static four-word struct");
  }

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

    // an action's digest must depend on the target, not just the calldata: actions 0 and 1 are the
    // same acceptOwnership() calldata to different feeds
    assertEq(data[0], data[1], "0 and 1 are the same call");
    assertTrue(
      CNGNSpotBatch.actionHash(to[0], data[0]) != CNGNSpotBatch.actionHash(to[1], data[1]),
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
