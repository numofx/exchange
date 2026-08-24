// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/SubAccounts.sol";
import "../../src/assets/WrappedERC20Asset.sol";
import "../../src/feeds/static/LyraStaticSpotFeed.sol";
import "../../src/interfaces/IStandardManager.sol";
import "../../src/risk-managers/StandardManager.sol";
import {CNGNSpotBatch} from "../../scripts/cngn-spot-batch.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @dev Executes every prefix of the batch against live Base state and asserts two things about each:
 *
 *      1. RESUME REPORTING is right — statuses() plus resolve() name exactly the prefix that ran.
 *      2. THE PREFIX IS SAFE — nothing can be deposited or traded until the final action.
 *
 *      (2) is why the ordering was changed. Under the old ordering, stopping early stranded both
 *      static feeds on the deployer key and left the old 3600s stableFeed wired in.
 */
contract FORK_TestCNGNSpotResume is Test {
  uint internal constant CNGN_PER_USDC = 1500e18;
  uint internal constant USDC_PER_CNGN = 1e36 / CNGN_PER_USDC;

  address internal vault;
  SubAccounts internal subAccounts;
  StandardManager internal srm;
  WrappedERC20Asset internal cngnAsset;
  IERC20Metadata internal cngn;
  LyraStaticSpotFeed internal staticCngnFeed;
  LyraStaticSpotFeed internal staticStableFeed;
  uint internal marketId;
  uint internal baseCap;
  uint internal cngnScale;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));

    string memory root = vm.projectRoot();
    string memory coreJson = vm.readFile(string.concat(root, "/deployments/8453/core.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json"));

    subAccounts = SubAccounts(vm.parseJsonAddress(coreJson, ".subAccounts"));
    srm = StandardManager(vm.parseJsonAddress(coreJson, ".srm"));
    cngnAsset = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    cngn = IERC20Metadata(vm.parseJsonAddress(cngnJson, ".wrappedAsset"));
    vault = srm.owner();

    marketId = srm.lastMarketId() + 1;
    cngnScale = 10 ** (18 - cngn.decimals());
    baseCap = cngn.totalSupply() * cngnScale * 10 / 100;

    staticCngnFeed = new LyraStaticSpotFeed();
    staticCngnFeed.setSpot(USDC_PER_CNGN, 1e18);
    staticCngnFeed.transferOwnership(vault);

    staticStableFeed = new LyraStaticSpotFeed();
    staticStableFeed.setSpot(1e18, 1e18);
    staticStableFeed.transferOwnership(vault);

    deal(address(cngn), address(this), 1_000_000_000e6);
    cngn.approve(address(cngnAsset), type(uint).max);
  }

  function _ctx() internal view returns (CNGNSpotBatch.Ctx memory) {
    return CNGNSpotBatch.Ctx({
      srm: address(srm),
      wrappedCngn: address(cngnAsset),
      cngnFeed: address(staticCngnFeed),
      stableFeed: address(staticStableFeed),
      marketId: marketId,
      baseCap: baseCap
    });
  }

  /// @dev run actions [0, n) as the vault
  function _executePrefix(uint n) internal {
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(_ctx());
    for (uint i = 0; i < n; ++i) {
      vm.prank(vault);
      (bool ok,) = to[i].call(data[i]);
      assertTrue(ok, string.concat("action failed at ", vm.toString(i)));
    }
  }

  function _resolved() internal view returns (CNGNSpotBatch.Status[] memory) {
    return CNGNSpotBatch.resolve(CNGNSpotBatch.statuses(_ctx()));
  }

  /// @dev nothing run yet: every action pending, nothing claimed done
  function testFork_NothingExecutedReportsAllPending() public view {
    CNGNSpotBatch.Status[] memory st = _resolved();
    for (uint i = 0; i < st.length; ++i) {
      assertTrue(st[i] != CNGNSpotBatch.Status.Done, "nothing should read as done");
      assertTrue(st[i] != CNGNSpotBatch.Status.Diverged, "nothing should read as diverged");
    }
  }

  /// @dev the core resume property, across every prefix
  function testFork_EveryPrefixIsReportedExactly() public {
    for (uint n = 1; n <= 11; ++n) {
      uint snapshot = vm.snapshotState();

      _executePrefix(n);
      CNGNSpotBatch.Status[] memory st = _resolved();

      for (uint i = 0; i < n; ++i) {
        // an executed action must NEVER read pending -- that is what would make a signer re-send it
        assertTrue(
          st[i] != CNGNSpotBatch.Status.Pending,
          string.concat("executed action ", vm.toString(i), " read pending after prefix ", vm.toString(n))
        );
        assertTrue(st[i] != CNGNSpotBatch.Status.Diverged, "executed action must not read diverged");

        // everything except the two all-zeros writes is positively observable
        if (i != 5 && i != 6) {
          assertEq(
            uint(st[i]),
            uint(CNGNSpotBatch.Status.Done),
            string.concat("action ", vm.toString(i), " should be done after prefix ", vm.toString(n))
          );
        }
      }
      for (uint i = n; i < 11; ++i) {
        assertTrue(
          st[i] != CNGNSpotBatch.Status.Done,
          string.concat("action ", vm.toString(i), " must not read done after prefix ", vm.toString(n))
        );
        assertTrue(st[i] != CNGNSpotBatch.Status.Diverged, "unrun actions must not read diverged");
      }

      vm.revertToState(snapshot);
    }
  }

  /// @dev the all-zeros postconditions (5, 6) are resolved by a later DONE rather than guessed at.
  ///      Before action 7 lands there is genuinely no way to tell them from an untouched market.
  function testFork_AmbiguousActionsAreResolvedOnlyByALaterDoneAction() public {
    uint snapshot = vm.snapshotState();

    // stop at 5: actions 5 and 6 have not run, and their postcondition is indistinguishable
    _executePrefix(5);
    CNGNSpotBatch.Status[] memory raw = CNGNSpotBatch.statuses(_ctx());
    assertEq(uint(raw[5]), uint(CNGNSpotBatch.Status.Ambiguous), "5 must be ambiguous, not done");
    assertEq(uint(raw[6]), uint(CNGNSpotBatch.Status.Ambiguous), "6 must be ambiguous, not done");
    // and resolve() must not promote them: no later action is done
    CNGNSpotBatch.Status[] memory st = CNGNSpotBatch.resolve(raw);
    assertTrue(st[5] != CNGNSpotBatch.Status.Done, "ambiguous must not be rounded up to done");

    vm.revertToState(snapshot);

    // once action 7 lands, nonce ordering proves 5 and 6 did too
    _executePrefix(8);
    st = _resolved();
    assertEq(uint(st[5]), uint(CNGNSpotBatch.Status.Done), "a later done action resolves 5");
    assertEq(uint(st[6]), uint(CNGNSpotBatch.Status.Done), "a later done action resolves 6");
  }

  /// @dev a third party wiring a different feed must read DIVERGED, not pending
  function testFork_ForeignConfigurationReportsDiverged() public {
    _executePrefix(7); // market created, oracles not yet set

    LyraStaticSpotFeed impostor = new LyraStaticSpotFeed();
    impostor.setSpot(USDC_PER_CNGN, 1e18);
    vm.prank(vault);
    srm.setOraclesForMarket(marketId, ISpotFeed(address(impostor)), IForwardFeed(address(0)), IVolFeed(address(0)));

    CNGNSpotBatch.Status[] memory st = _resolved();
    assertEq(uint(st[7]), uint(CNGNSpotBatch.Status.Diverged), "a foreign spot feed must read diverged");
  }

  /// @dev THE reason for the reordering: every prefix short of the last is unusable, so abandoning
  ///      the batch anywhere leaves a venue that cannot be traded rather than a half-open one
  function testFork_NoPrefixBeforeTheLastActionPermitsADeposit() public {
    uint acc = subAccounts.createAccountWithApproval(address(this), address(this), srm);

    for (uint n = 0; n < 11; ++n) {
      uint snapshot = vm.snapshotState();
      _executePrefix(n);

      vm.expectRevert();
      cngnAsset.deposit(acc, 1_000e18 / cngnScale);

      vm.revertToState(snapshot);
    }

    // and after the final action it works
    _executePrefix(11);
    cngnAsset.deposit(acc, 1_000e18 / cngnScale);
    assertEq(subAccounts.getBalance(acc, cngnAsset, 0), 1_000e18);
  }

  /// @dev custody is secured by the first two actions, so no prefix leaves a feed on the deployer key
  function testFork_CustodyIsSecuredByTheFirstTwoActions() public {
    _executePrefix(2);
    assertEq(staticCngnFeed.owner(), vault, "cngn feed must be vault-owned after action 0");
    assertEq(staticStableFeed.owner(), vault, "stable feed must be vault-owned after action 1");
  }
}
