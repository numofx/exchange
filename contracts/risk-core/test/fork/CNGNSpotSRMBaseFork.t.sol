// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/SubAccounts.sol";
import "../../src/assets/CashAsset.sol";
import "../../src/assets/WrappedERC20Asset.sol";
import "../../src/interfaces/IAsset.sol";
import "../../src/interfaces/IForwardFeed.sol";
import "../../src/interfaces/ISpotFeed.sol";
import "../../src/interfaces/IStandardManager.sol";
import "../../src/interfaces/IVolFeed.sol";
import "../../src/interfaces/IWrappedERC20Asset.sol";
import "../../src/assets/utils/ManagerWhitelist.sol";
import "../../src/assets/utils/PositionTracking.sol";
import "../../src/feeds/static/LyraStaticSpotFeed.sol";
import "../../src/risk-managers/StandardManager.sol";
import {CNGNSpotBatch} from "../../scripts/cngn-spot-batch.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @dev Builds the USDCcNGN-SPOT vault batch exactly as scripts/register-cngn-spot-srm.s.sol does,
 *      executes it against live Base state AS THE VAULT, then trades the way the venue would.
 *
 * @dev The batch is constructed here rather than read from a committed JSON because two of the
 *      eleven actions target static feeds that do not exist until they are deployed. The feeds are
 *      deployed in setUp with the same values the deploy script uses, so the action list under test
 *      is the same shape and ordering the vault will sign. Keep this list and the script in step.
 */
contract FORK_TestCNGNSpotOnSRMBase is Test {
  uint internal constant CNGN_PER_USDC = 1500e18;
  /// @dev what the deploy script writes into the static feed: the inverse, in the SRM's Base
  ///      convention of USD-per-base. 1e36 / 1500e18 = 666666666666666.
  uint internal constant USDC_PER_CNGN = 1e36 / CNGN_PER_USDC;
  uint internal constant CAP_PCT = 10;

  address internal vault;

  SubAccounts internal subAccounts;
  CashAsset internal cash;
  StandardManager internal srm;
  WrappedERC20Asset internal cngnAsset;
  ISpotFeed internal liveCngnFeed;

  LyraStaticSpotFeed internal staticCngnFeed;
  LyraStaticSpotFeed internal staticStableFeed;

  IERC20Metadata internal usdc;
  IERC20Metadata internal cngn;

  address internal dfxManager;
  uint internal marketId;
  uint internal baseCap;
  /// @dev 10**(18 - cngn.decimals()), resolved once. Kept out of the helpers because an external
  ///      call inside an argument expression consumes a pending vm.prank / vm.expectRevert.
  uint internal cngnScale;

  address internal alice = address(0xaa02);
  address internal bob = address(0xbb02);
  address internal feeTaker = address(0xfee2);
  uint internal aliceAcc;
  uint internal bobAcc;
  uint internal feeAcc;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));

    string memory root = vm.projectRoot();
    string memory coreJson = vm.readFile(string.concat(root, "/deployments/8453/core.json"));
    string memory sharedJson = vm.readFile(string.concat(root, "/deployments/8453/shared.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json"));
    string memory futureJson = vm.readFile(string.concat(root, "/deployments/8453/CNGN_SEP16_2026_FUTURE.json"));

    subAccounts = SubAccounts(vm.parseJsonAddress(coreJson, ".subAccounts"));
    cash = CashAsset(vm.parseJsonAddress(coreJson, ".cash"));
    srm = StandardManager(vm.parseJsonAddress(coreJson, ".srm"));
    usdc = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".usdc"));
    cngn = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".cngn"));
    cngnAsset = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    liveCngnFeed = ISpotFeed(vm.parseJsonAddress(cngnJson, ".spotFeed"));
    dfxManager = vm.parseJsonAddress(futureJson, ".manager");

    vault = srm.owner();
    assertEq(cngnAsset.owner(), vault, "srm and wrapped cngn must share an owner for one vault batch");

    marketId = srm.lastMarketId() + 1;
    baseCap = _resolveCap();

    _deployStaticFeeds();
    _executeVaultActions();

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), srm);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), srm);
    feeAcc = subAccounts.createAccountWithApproval(feeTaker, address(this), srm);

    deal(address(usdc), address(this), 1_000_000 * 1e6);
    deal(address(cngn), address(this), 1_000_000_000e6);
    usdc.approve(address(cash), type(uint).max);
    cngn.approve(address(cngnAsset), type(uint).max);
    cngnScale = 10 ** (18 - cngn.decimals());
  }

  // ---------------------------------------------------------------------------------------------
  // config
  // ---------------------------------------------------------------------------------------------

  /// @dev the vault batch registers the market and leaves the deliverable stack intact
  function testFork_VaultActionsRegisterSpotMarket() public {
    assertEq(address(srm.assetMap(marketId, IStandardManager.AssetType.Base)), address(cngnAsset));

    (uint marginFactor, uint imScale) = srm.baseMarginParams(marketId);
    assertEq(marginFactor, 0, "cngn must contribute no margin");
    assertEq(imScale, 0);

    assertFalse(srm.borrowingEnabled(), "borrowing must be off");
    assertTrue(cngnAsset.whitelistedManager(address(srm)), "srm must be whitelisted on wrapped cngn");
    // the deliverable stack keeps working if a dated series is ever relisted
    assertTrue(cngnAsset.whitelistedManager(dfxManager), "dfx manager must stay whitelisted");

    // both feeds are now static and vault-owned
    assertEq(address(srm.stableFeed()), address(staticStableFeed), "stable feed must be the static one");
    assertEq(staticCngnFeed.owner(), vault, "vault must own the cngn static feed");
    assertEq(staticStableFeed.owner(), vault, "vault must own the stable static feed");
  }

  /// @dev cap is a share of live supply, and it gates deposits rather than trading
  function testFork_CapIsShareOfLiveSupplyAndBlocksDepositsOnly() public {
    uint supply18 = cngn.totalSupply() * cngnScale;
    assertEq(baseCap, supply18 * CAP_PCT / 100, "cap must be derived from live supply");
    assertEq(cngnAsset.totalPositionCap(IManager(address(srm))), baseCap);

    // tighten the cap to a level this test can fill exactly, then prove the two behaviours apart
    vm.prank(vault);
    cngnAsset.setTotalPositionCap(IManager(address(srm)), 1_500_000e18);

    _fundCNGN(bobAcc, 1_500_000e18); // exactly at the cap
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _fundCNGN(aliceAcc, 1e18); // one more cNGN cannot enter

    // but the book keeps matching: an account-to-account transfer of a non-negative asset leaves
    // totalPosition unchanged, so _checkAssetCap's `preTradePos < postTradePos` is never true
    _fundCash(aliceAcc, 10_000 * 1e6);
    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);
    assertEq(_cngnBalance(aliceAcc), 1_500_000e18, "trading must continue at the cap");
  }

  // ---------------------------------------------------------------------------------------------
  // oracle independence
  // ---------------------------------------------------------------------------------------------

  /// @dev the whole point of the static feeds: no keeper, no staleness, no halt. The live cNGN feed
  ///      has a 180s heartbeat and the previous stable feed 3600s; both revert once stale, which
  ///      would stop a fully-funded book whose solvency does not depend on either price.
  function testFork_TradesWithNoLiveOracleAfterHeartbeatsWouldHaveExpired() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    // far past any heartbeat the keeper-driven feeds enforce
    vm.warp(block.timestamp + 30 days);

    vm.expectRevert();
    liveCngnFeed.getSpot(); // the old feed is stale and would have halted the venue

    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);
    assertEq(_cngnBalance(aliceAcc), 1_500_000e18, "spot must settle with no live oracle");
  }

  /// @dev with the inverted static feed the reported MtM is finally in the right units. The old
  ///      configuration reused the DFXM feed (cNGN-per-USDC) in a USD-per-base slot and inflated
  ///      MtM by spot^2 -- contained only by marginFactor == 0.
  function testFork_MarkToMarketIsCorrectlyOriented() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);
    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);

    int cashBal = subAccounts.getBalance(aliceAcc, cash, 0);
    (int netMargin, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, marketId);

    // solvency: still exactly cash, the cNGN contributes nothing at marginFactor 0
    assertEq(netMargin, cashBal, "netMargin must equal cash for a spot-only account");

    // reporting: 1.5m cNGN bought for 1_000 cash marks at ~1_000, not at 2.25e9
    assertApproxEqAbs(mtm, cashBal + 1_000e18, 1e6, "MtM must value cNGN at ~its purchase price");
  }

  // ---------------------------------------------------------------------------------------------
  // fully-funded spot, both directions
  // ---------------------------------------------------------------------------------------------

  function testFork_FundedSpotBuySettles() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);

    assertEq(_cngnBalance(aliceAcc), 1_500_000e18);
    assertEq(subAccounts.getBalance(aliceAcc, cash, 0), 9_000e18);
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 1_000e18);
  }

  function testFork_UnfundedSpotBuyReverts() public {
    _fundCash(aliceAcc, 1_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _spotTrade(bobAcc, 3_000_000e18, aliceAcc, 2_000e18);
  }

  function testFork_SellingCNGNFromCashFreeAccountSettles() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 0);
    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 1_000e18);
  }

  function testFork_CannotSellMoreCNGNThanHeld() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 1_500_000e18);

    vm.expectRevert(IWrappedERC20Asset.WERC_CannotBeNegative.selector);
    _spotTrade(bobAcc, 3_000_000e18, aliceAcc, 2_000e18);
  }

  function testFork_CanWithdrawCNGNWithNoCash() public {
    _fundCNGN(aliceAcc, 1_500_000e18);
    // resolve the decimals scaling BEFORE the prank: argument expressions are evaluated first, and
    // an external call in one of them consumes the prank before withdraw is ever invoked
    uint amount = 1_500_000e18 / cngnScale;
    vm.prank(alice);
    cngnAsset.withdraw(aliceAcc, amount, alice);
    assertEq(_cngnBalance(aliceAcc), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // fees: cash >= 0 is checked on the NET adjustment, so the fee is part of what a buyer must fund
  // ---------------------------------------------------------------------------------------------

  /// @dev TradeModule._addAssetTransfers puts the fee in as a third quote-asset transfer in the same
  ///      batch, so the buyer's net cash delta is -(notional + fee). An order funded to exactly the
  ///      notional is rejected. The matcher must reserve notional + fee or it will emit orders that
  ///      cannot settle.
  function testFork_BuyerFundedToExactlyNotionalIsRejectedByFee() public {
    _fundCash(aliceAcc, 1_000 * 1e6); // exactly the notional, no fee headroom
    _fundCNGN(bobAcc, 15_000_000e18);

    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _spotTradeWithFee(bobAcc, 1_500_000e18, aliceAcc, 1_000e18, 1e18, aliceAcc);
  }

  /// @dev the same order funded to notional + fee settles, and the fee lands on the recipient
  function testFork_BuyerFundedToNotionalPlusFeeSettles() public {
    _fundCash(aliceAcc, 1_001 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    _spotTradeWithFee(bobAcc, 1_500_000e18, aliceAcc, 1_000e18, 1e18, aliceAcc);

    assertEq(subAccounts.getBalance(aliceAcc, cash, 0), 0, "buyer is drained to exactly zero");
    assertEq(subAccounts.getBalance(feeAcc, cash, 0), 1e18, "fee recipient is paid");
    assertEq(_cngnBalance(aliceAcc), 1_500_000e18);
  }

  /// @dev the seller pays a cash fee too, but out of proceeds received in the same adjustment. The
  ///      SRM checks the NET delta, so a seller holding no cash at all still settles while
  ///      notional > fee -- the gross outflow never has to be pre-funded.
  function testFork_CashFreeSellerSettlesOnNetDelta() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 0, "seller starts with no cash");

    _spotTradeWithFee(bobAcc, 1_500_000e18, aliceAcc, 1_000e18, 40e18, bobAcc);

    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 960e18, "seller keeps notional minus fee");
    assertEq(subAccounts.getBalance(feeAcc, cash, 0), 40e18);

    // and the boundary: a fee exceeding proceeds makes the net delta negative, which is refused
    _fundCNGN(aliceAcc, 15_000_000e18);
    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _spotTradeWithFee(aliceAcc, 1_500_000e18, bobAcc, 1_000e18, 2_000e18, aliceAcc);
  }

  // ---------------------------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------------------------

  function _resolveCap() internal view returns (uint) {
    uint supply18 = cngn.totalSupply() * (10 ** (18 - cngn.decimals()));
    return supply18 * CAP_PCT / 100;
  }

  /// @dev mirrors scripts/deploy-cngn-spot-static-feeds.s.sol
  function _deployStaticFeeds() internal {
    staticCngnFeed = new LyraStaticSpotFeed();
    staticCngnFeed.setSpot(USDC_PER_CNGN, 1e18);
    staticCngnFeed.transferOwnership(vault);

    staticStableFeed = new LyraStaticSpotFeed();
    staticStableFeed.setSpot(1e18, 1e18);
    staticStableFeed.transferOwnership(vault);
  }

  /// @dev executes CNGNSpotBatch.build() -- the same library scripts/register-cngn-spot-srm.s.sol
  ///      serialises into the artifact the vault signs. Nothing is re-declared here, so the batch
  ///      proven by this suite and the batch signed cannot drift apart.
  function _executeVaultActions() internal {
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(_batchCtx());

    for (uint i = 0; i < to.length; ++i) {
      vm.prank(vault);
      (bool ok,) = to[i].call(data[i]);
      assertTrue(ok, string.concat("vault action failed at index ", vm.toString(i)));
    }
  }

  function _batchCtx() internal view returns (CNGNSpotBatch.Ctx memory) {
    return CNGNSpotBatch.Ctx({
      srm: address(srm),
      wrappedCngn: address(cngnAsset),
      cngnFeed: address(staticCngnFeed),
      stableFeed: address(staticStableFeed),
      marketId: marketId,
      baseCap: baseCap
    });
  }

  function _fundCash(uint accountId, uint underlyingUsdc) internal {
    cash.deposit(accountId, underlyingUsdc);
  }

  /// @dev takes the 18-decimal sub-account amount; cNGN is 6dp on Base
  function _fundCNGN(uint accountId, uint amount18) internal {
    cngnAsset.deposit(accountId, amount18 / cngnScale);
  }

  /// @dev the venue's spot fill: cNGN one way, internal cash the other
  function _spotTrade(uint cngnFrom, uint cngnAmount, uint cashFrom, uint cashAmount) internal {
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](2);
    batch[0] = ISubAccounts.AssetTransfer({
      fromAcc: cngnFrom, toAcc: cashFrom, asset: cngnAsset, subId: 0, amount: int(cngnAmount), assetData: bytes32(0)
    });
    batch[1] = ISubAccounts.AssetTransfer({
      fromAcc: cashFrom, toAcc: cngnFrom, asset: cash, subId: 0, amount: int(cashAmount), assetData: bytes32(0)
    });
    subAccounts.submitTransfers(batch, "");
  }

  /// @dev same fill plus the fee leg TradeModule appends: a third quote-asset transfer in the same
  ///      batch, so the payer's margin check sees one net cash delta
  function _spotTradeWithFee(uint cngnFrom, uint cngnAmount, uint cashFrom, uint cashAmount, uint fee, uint feePayer)
    internal
  {
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](3);
    batch[0] = ISubAccounts.AssetTransfer({
      fromAcc: cngnFrom, toAcc: cashFrom, asset: cngnAsset, subId: 0, amount: int(cngnAmount), assetData: bytes32(0)
    });
    batch[1] = ISubAccounts.AssetTransfer({
      fromAcc: cashFrom, toAcc: cngnFrom, asset: cash, subId: 0, amount: int(cashAmount), assetData: bytes32(0)
    });
    batch[2] = ISubAccounts.AssetTransfer({
      fromAcc: feePayer, toAcc: feeAcc, asset: cash, subId: 0, amount: int(fee), assetData: bytes32(0)
    });
    subAccounts.submitTransfers(batch, "");
  }

  function _cngnBalance(uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, cngnAsset, 0);
  }
}
