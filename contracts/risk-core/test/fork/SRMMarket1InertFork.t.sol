// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface ISRMLike {
  function owner() external view returns (address);
  function getMargin(uint accountId, bool isInitial) external view returns (int);
  function getMarketFeeds(uint marketId) external view returns (address, address, address);
  function baseMarginParams(uint marketId) external view returns (uint, uint);
  function borrowingEnabled() external view returns (bool);
  function stableFeed() external view returns (address);
}

interface IWrappedLike {
  function deposit(uint recipientAccount, uint assetAmount) external;
  function withdraw(uint accountId, uint assetAmount, address recipient) external;
}

interface IERC20Like {
  function approve(address, uint) external returns (bool);
  function balanceOf(address) external view returns (uint);
}

interface ISubAccountsLike {
  function ownerOf(uint) external view returns (address);
  function getBalance(uint accountId, address asset, uint subId) external view returns (int);
}

interface IFeedLike {
  function getSpot() external view returns (uint, uint);
}

/**
 * Market 1 (wrapped USDC) made inert, by the two-action vault batch in
 * deployments/8453/MARKET1_INERT_VAULT_ACTIONS.json:
 *
 *   0. srm.setOraclesForMarket(1, staticStableFeed, 0, 0)  landed at block 51097293
 *   1. srm.setBaseAssetMarginFactor(1, 0, 0)               landed at block 51097344
 *
 * These are POST-STATE assertions against the live chain. That distinction is the whole
 * design of this file: an earlier version applied the batch itself with vm.prank and
 * asserted the result, which passed identically whether or not the batch had ever been
 * signed -- and its negative control started failing the moment the real transactions
 * landed. That is issue #29's failure mode, and it is why the two tests that need to see
 * the *old* world pin an explicit pre-batch block instead of describing it in a comment.
 *
 * Requires BASE_RPC_URL, like every other fork test here, and archive access for the two
 * pinned-block tests.
 */
contract SRMMarket1InertFork is Test {
  address constant SRM = 0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b;
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  address constant WUSDC = 0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant STATIC_STABLE_FEED = 0x507D645682737C6640dc73b5aC858654BcB9854f;
  address constant STATIC_CNGN_FEED = 0xec4ad7B2679f54eB3e971B10120cB56cF1c061A4;
  address constant LIVE_FEED = 0xDAe566adc61086535986AfBd80093B1DD8686797;

  uint constant ACCOUNT = 15; // SRM account holding 5,000 wrapped cNGN
  bytes4 constant DATA_TOO_OLD = 0x1141796d; // BLF_DataTooOld()

  /// The block immediately before action 0 landed. Everything about market 1 here is the
  /// world the batch was written to fix.
  uint constant PRE_BATCH_BLOCK = 51097292;

  // The exact calldata the vault sent, copied from the artifact. Kept so a hand edit to
  // either file is caught by testTheArtifactReproducesWhatLanded.
  bytes constant ACTION_0 =
    hex"675b0ebb0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000507d645682737c6640dc73b5ac858654bcb9854f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
  bytes constant ACTION_1 =
    hex"c27009e2000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
  }

  function _fundAccountWithWrappedUsdc(uint amount) internal {
    deal(USDC, address(this), amount);
    IERC20Like(USDC).approve(WUSDC, type(uint).max);
    IWrappedLike(WUSDC).deposit(ACCOUNT, amount);
  }

  // --- post-state: what the chain must look like now -------------------------------

  function testMarket1IsOnTheStaticFeedWithNoCollateralValue() public view {
    (address spot, address fwd, address vol) = ISRMLike(SRM).getMarketFeeds(1);
    assertEq(spot, STATIC_STABLE_FEED, "market 1 spot feed not repointed");
    assertEq(fwd, address(0), "market 1 forward feed should stay unset");
    assertEq(vol, address(0), "market 1 vol feed should stay unset");

    (uint mf, uint ims) = ISRMLike(SRM).baseMarginParams(1);
    assertEq(mf, 0, "market 1 margin factor not zeroed");
    assertEq(ims, 0, "market 1 IM scale not zeroed");
  }

  function testTheSrmReadsNoLiveFeedAtAll() public {
    // Market 2 and the globals were set by the earlier cNGN batch and must not have moved.
    (address spot2,,) = ISRMLike(SRM).getMarketFeeds(2);
    assertEq(spot2, STATIC_CNGN_FEED, "market 2 feed must not move");
    assertEq(ISRMLike(SRM).stableFeed(), STATIC_STABLE_FEED, "stable feed must not move");
    assertFalse(ISRMLike(SRM).borrowingEnabled(), "borrowing must stay disabled");

    // Hold both markets, so the margin walk touches every feed the SRM could consult.
    _fundAccountWithWrappedUsdc(10e6);

    // The claim in this test's name is about the SRM, so assert it through the SRM rather
    // than by reading the feeds directly: after a month with no publisher, margin must
    // still compute. Checking only that the two static feeds answer would leave the name
    // unearned -- it would not rule out a live feed being read somewhere else in the walk.
    vm.warp(block.timestamp + 30 days);
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, true), 0, "IM must survive a month of silence");
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, false), 0, "MM must survive a month of silence");

    // And the feed that used to be in that path is, by then, definitively dead.
    vm.expectRevert(DATA_TOO_OLD);
    IFeedLike(LIVE_FEED).getSpot();
  }

  function testStaleLiveFeedNoLongerHaltsWrappedUsdcAccounts() public {
    _fundAccountWithWrappedUsdc(10e6);
    vm.warp(block.timestamp + 7200); // well past the old feed's 3600s heartbeat

    vm.expectRevert(DATA_TOO_OLD); // the old feed really is stale...
    IFeedLike(LIVE_FEED).getSpot();

    // ...and the SRM no longer cares.
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, true), 0, "IM must be solvent");
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, false), 0, "MM must be solvent");
  }

  function testWithdrawalPassesRiskCheckWithStaleLiveFeed() public {
    _fundAccountWithWrappedUsdc(10e6);
    vm.warp(block.timestamp + 7200);

    // Partial, so a market-1 holding still exists at the moment of the risk check. A full
    // withdrawal empties the position and the SRM stops reading market 1 for a different
    // reason, which would make this test pass without proving anything.
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCOUNT);
    uint before = IERC20Like(USDC).balanceOf(owner);
    vm.prank(owner);
    IWrappedLike(WUSDC).withdraw(ACCOUNT, 4e6, owner);
    assertEq(IERC20Like(USDC).balanceOf(owner) - before, 4e6, "withdrawal must return the real USDC");
  }

  /// Zeroing the margin factor cannot make anyone insolvent, because every asset this SRM
  /// admits is non-negative: cash (borrowing disabled) and two WrappedERC20Assets.
  function testMarginRemainsNonNegativeForBothMarkets() public {
    _fundAccountWithWrappedUsdc(10e6);
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, true), 0, "IM with both wrapped assets held");
    assertGe(ISRMLike(SRM).getMargin(ACCOUNT, false), 0, "MM with both wrapped assets held");
  }

  /// Documents the asymmetry that makes a stale feed easy to miss: a pure deposit sets no
  /// negative delta, so handleAdjustment's `riskAdding` stays false and _assessRisk -- and
  /// with it every feed read -- is skipped. Funds go IN fine while the book is halted; only
  /// the paths that reduce a balance surface the staleness. Independent of this batch, which
  /// is why it is asserted at head rather than pinned.
  function testDepositBypassesTheRiskCheckEntirely() public {
    deal(USDC, address(this), 10e6);
    IERC20Like(USDC).approve(WUSDC, type(uint).max);
    vm.warp(block.timestamp + 7200);

    uint before = uint(ISubAccountsLike(SUB_ACCOUNTS).getBalance(ACCOUNT, WUSDC, 0));
    IWrappedLike(WUSDC).deposit(ACCOUNT, 10e6); // no revert even with LIVE_FEED stale

    // deposit() takes the token's native decimals and credits `to18Decimals(assetDecimals)`,
    // so 10 USDC (6dp) lands as 10e18 ledger units. Same 10 USDC, different scale -- worth
    // asserting explicitly, because "10e6 in, 10e6 out" is the assumption a reader brings.
    assertEq(
      uint(ISubAccountsLike(SUB_ACCOUNTS).getBalance(ACCOUNT, WUSDC, 0)) - before,
      10e18,
      "the deposit must actually credit the account, not merely fail to revert"
    );
  }

  // --- pre-batch: proof the batch was necessary, and that it is what landed ----------

  /// The negative control. Without it, every assertion above would also pass against a
  /// chain where the batch had never been signed.
  function testBeforeTheBatchAStaleFeedHaltedTheBook() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), PRE_BATCH_BLOCK);

    (address spot,,) = ISRMLike(SRM).getMarketFeeds(1);
    assertEq(spot, LIVE_FEED, "pinned block is not actually pre-batch");
    (uint mf,) = ISRMLike(SRM).baseMarginParams(1);
    assertEq(mf, 0.98e18, "pinned block is not actually pre-batch");

    _fundAccountWithWrappedUsdc(10e6);
    vm.warp(block.timestamp + 7200);

    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCOUNT);
    vm.prank(owner);
    vm.expectRevert(DATA_TOO_OLD);
    IWrappedLike(WUSDC).withdraw(ACCOUNT, 4e6, owner);
  }

  /// Replays the artifact's bytes against the pre-batch world and checks the result equals
  /// the state the real transactions produced. This is what ties the recorded calldata to
  /// what the vault actually sent -- an edit to either file breaks it.
  function testTheArtifactReproducesWhatLanded() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), PRE_BATCH_BLOCK);

    address o = ISRMLike(SRM).owner();
    vm.startPrank(o);
    (bool ok0,) = SRM.call(ACTION_0);
    require(ok0, "action 0 reverted");
    (bool ok1,) = SRM.call(ACTION_1);
    require(ok1, "action 1 reverted");
    vm.stopPrank();

    (address spot, address fwd, address vol) = ISRMLike(SRM).getMarketFeeds(1);
    assertEq(spot, STATIC_STABLE_FEED);
    assertEq(fwd, address(0));
    assertEq(vol, address(0));
    (uint mf, uint ims) = ISRMLike(SRM).baseMarginParams(1);
    assertEq(mf, 0);
    assertEq(ims, 0);
  }
}
