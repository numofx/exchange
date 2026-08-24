// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/assets/WrappedERC20Asset.sol";
import "../../src/feeds/static/LyraStaticSpotFeed.sol";
import "../../src/interfaces/ISpotFeed.sol";
import "../../src/risk-managers/StandardManager.sol";
import {CNGNSpotBatch} from "../../scripts/cngn-spot-batch.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev CNGNSpotBatch.checkPreconditions is a library `internal` function, so it inlines into its
///      caller and produces no external call for vm.expectRevert to catch. Routing through this
///      harness makes each refusal observable as a real revert.
contract PreconditionHarness {
  function check(CNGNSpotBatch.Ctx memory ctx, address cngnToken, address liveCngnFeed, uint tolerancePct)
    external
    view
  {
    CNGNSpotBatch.checkPreconditions(ctx, cngnToken, liveCngnFeed, tolerancePct);
  }
}

/**
 * @dev Proves the generation script refuses to emit calldata for a stale or wrong world.
 *
 *      Each test breaks exactly one precondition against live Base state and asserts the specific
 *      revert. A guard nobody has watched fire is a guard nobody should trust: the orientation check
 *      in particular exists because the first version of this migration wired the DFXM feed
 *      (cNGN-per-USDC) into the SRM's USD-per-base slot and inflated mark-to-market by spot^2.
 */
contract FORK_TestCNGNSpotPreconditions is Test {
  uint internal constant CNGN_PER_USDC = 1500e18;
  uint internal constant USDC_PER_CNGN = 1e36 / CNGN_PER_USDC;
  uint internal constant TOLERANCE_PCT = 5;

  address internal vault;
  StandardManager internal srm;
  WrappedERC20Asset internal cngnAsset;
  IERC20Metadata internal cngn;
  ISpotFeed internal liveCngnFeed;
  address internal cngnToken;

  LyraStaticSpotFeed internal staticCngnFeed;
  LyraStaticSpotFeed internal staticStableFeed;
  PreconditionHarness internal harness;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));

    string memory root = vm.projectRoot();
    string memory coreJson = vm.readFile(string.concat(root, "/deployments/8453/core.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json"));

    srm = StandardManager(vm.parseJsonAddress(coreJson, ".srm"));
    cngnAsset = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    liveCngnFeed = ISpotFeed(vm.parseJsonAddress(cngnJson, ".spotFeed"));
    cngnToken = vm.parseJsonAddress(cngnJson, ".wrappedAsset");
    cngn = IERC20Metadata(cngnToken);
    vault = srm.owner();

    // pin the live feed so drift assertions are about the static value, not keeper timing
    vm.mockCall(address(liveCngnFeed), abi.encodeCall(ISpotFeed.getSpot, ()), abi.encode(CNGN_PER_USDC, 1e18));

    harness = new PreconditionHarness();

    staticCngnFeed = new LyraStaticSpotFeed();
    staticCngnFeed.setSpot(USDC_PER_CNGN, 1e18);
    staticCngnFeed.transferOwnership(vault);

    staticStableFeed = new LyraStaticSpotFeed();
    staticStableFeed.setSpot(1e18, 1e18);
    staticStableFeed.transferOwnership(vault);
  }

  function _ctx() internal view returns (CNGNSpotBatch.Ctx memory) {
    return CNGNSpotBatch.Ctx({
      srm: address(srm),
      wrappedCngn: address(cngnAsset),
      cngnFeed: address(staticCngnFeed),
      stableFeed: address(staticStableFeed),
      marketId: srm.lastMarketId() + 1,
      baseCap: 204_853_778e18
    });
  }

  function _check(CNGNSpotBatch.Ctx memory ctx) internal view {
    harness.check(ctx, cngnToken, address(liveCngnFeed), TOLERANCE_PCT);
  }

  /// @dev the happy path must pass, or every negative test below is vacuous
  function testFork_PreconditionsPassAgainstLiveState() public view {
    _check(_ctx());
  }

  /// @dev THE regression guard: the live DFXM feed is cNGN-per-USDC and must never be wired into
  ///      the SRM's USD-per-base slot
  function testFork_RefusesTheLiveFeedBecauseItIsInverted() public {
    LyraStaticSpotFeed wrongWayRound = new LyraStaticSpotFeed();
    wrongWayRound.setSpot(CNGN_PER_USDC, 1e18); // 1500e18 instead of ~0.000667e18
    wrongWayRound.transferOwnership(vault);

    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.cngnFeed = address(wrongWayRound);

    vm.expectRevert("PRE: cngn static feed looks inverted - expected USDC-per-cNGN");
    _check(ctx);
  }

  /// @dev a feed deployed weeks ago against a rate that has since moved
  function testFork_RefusesADriftedStaticPrice() public {
    LyraStaticSpotFeed drifted = new LyraStaticSpotFeed();
    drifted.setSpot(USDC_PER_CNGN * 80 / 100, 1e18); // 20% away, tolerance is 5%
    drifted.transferOwnership(vault);

    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.cngnFeed = address(drifted);

    vm.expectRevert("PRE: static feed has drifted from live - redeploy feeds");
    _check(ctx);
  }

  /// @dev within tolerance is fine: the point is to catch material drift, not to demand equality
  function testFork_AcceptsDriftInsideTolerance() public {
    LyraStaticSpotFeed nudged = new LyraStaticSpotFeed();
    nudged.setSpot(USDC_PER_CNGN * 98 / 100, 1e18); // 2%
    nudged.transferOwnership(vault);

    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.cngnFeed = address(nudged);
    _check(ctx);
  }

  /// @dev actions 8 and 9 are acceptOwnership(); without a pending transfer they revert mid-batch,
  ///      and a mid-batch revert on an EOA leaves partial state rather than rolling back
  function testFork_RefusesAFeedTheVaultCannotAccept() public {
    LyraStaticSpotFeed unowned = new LyraStaticSpotFeed();
    unowned.setSpot(USDC_PER_CNGN, 1e18); // never transferred

    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.cngnFeed = address(unowned);

    vm.expectRevert("PRE: vault is not pending owner of cngn feed");
    _check(ctx);
  }

  /// @dev if someone creates a market between resolving the id and signing, every later action in
  ///      the batch targets the wrong market
  function testFork_RefusesAStaleMarketId() public {
    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.marketId = srm.lastMarketId(); // already taken

    vm.expectRevert("PRE: marketId is stale - re-run");
    _check(ctx);
  }

  function testFork_RefusesAMarketThatAlreadyHasABaseAsset() public {
    // market 1 already exists on the live SRM with wrapped USDC as its base asset
    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.marketId = 1;

    // the stale-id guard fires first, which is itself the correct refusal
    vm.expectRevert("PRE: marketId is stale - re-run");
    _check(ctx);
  }

  function testFork_RefusesAStableFeedThatIsNotOne() public {
    LyraStaticSpotFeed wrong = new LyraStaticSpotFeed();
    wrong.setSpot(0.98e18, 1e18);
    wrong.transferOwnership(vault);

    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.stableFeed = address(wrong);

    vm.expectRevert("PRE: stable static feed is not 1e18");
    _check(ctx);
  }

  function testFork_RefusesAnUndeployedFeed() public {
    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.cngnFeed = address(0xdead);

    vm.expectRevert("PRE: cngn static feed has no code");
    _check(ctx);
  }

  function testFork_RefusesAZeroCap() public {
    CNGNSpotBatch.Ctx memory ctx = _ctx();
    ctx.baseCap = 0;

    vm.expectRevert("PRE: cap is 0");
    _check(ctx);
  }
}
