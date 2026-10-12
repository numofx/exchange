// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "openzeppelin/utils/math/Math.sol";

import "../../../../src/SubAccounts.sol";
import "../../../../src/risk-managers/MarginEnginePortfolioViewer.sol";
import "../../../../src/risk-managers/MarginEngine.sol";
import {IMarginEngine} from "../../../../src/interfaces/IMarginEngine.sol";
import {IVolFeed} from "../../../../src/interfaces/IVolFeed.sol";
import "../../../../src/assets/WrappedERC20Asset.sol";
import "../../../../src/assets/FutureAsset.sol";
import {IAsset} from "../../../../src/interfaces/IAsset.sol";
import {ICashAsset} from "../../../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../../../src/interfaces/IDutchAuction.sol";
import {IFutureAsset} from "../../../../src/interfaces/IFutureAsset.sol";
import {IERC20BasedAsset} from "../../../../src/interfaces/IERC20BasedAsset.sol";
import {ISpotFeed} from "../../../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../../../src/interfaces/IForwardFeed.sol";

import "../../../shared/mocks/MockERC20.sol";
import "../../../shared/mocks/MockFeeds.sol";
import "../../../shared/mocks/MockCash.sol";
import "../../../shared/mocks/MockPerp.sol";
import {IBaseManager} from "../../../../src/interfaces/IBaseManager.sol";
import "../../mocks/MockDutchAuction.sol";

/**
 * FutureManager's suite, ported to MarginEngine: the same FutureAsset, now one asset type among spot and perps in a
 * StandardManager-style market. Margin parameters are the engine's per-market ones; errors are the engine's.
 *
 * Prices are cNGN per USDC. The spot feed is USDC per cNGN. The numbers are chosen to be consistent and round:
 * mark 1000 cNGN/USDC, spot 0.001 USDC/cNGN, one contract = 1,000 USDC, so a 10 cNGN move in the mark is
 * 10,000 cNGN (10 USDC) of VM per contract.
 */
contract TestMarginEngine_Future is Test {
  SubAccounts subAccounts;
  MarginEngine manager;
  MarginEnginePortfolioViewer viewer;
  MockFeeds stableFeed;
  uint marketId;
  MockDutchAuction auction;

  MockCash cash;
  MockERC20 usdc;
  MockERC20 cngn;
  WrappedERC20Asset cngnAsset;
  FutureAsset future;
  MockFeeds spotFeed;

  uint aliceAcc;
  uint bobAcc;
  uint pool;
  address alice = address(0xaa);
  address bob = address(0xbb);

  uint96 subId;
  uint expiry;
  uint lastTradeTime;

  uint constant CONTRACT_SIZE = 1000e18;
  uint constant MARK = 1000e18;
  uint constant SPOT = 0.001e18;

  function setUp() public {
    vm.warp(1_790_000_000);
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    usdc = new MockERC20("USDC", "USDC");
    cngn = new MockERC20("cNGN", "cNGN");
    usdc.setDecimals(6);
    cngn.setDecimals(6);

    cash = new MockCash(usdc, subAccounts);
    viewer = new MarginEnginePortfolioViewer(subAccounts, cash);
    auction = new MockDutchAuction();
    cngnAsset = new WrappedERC20Asset(subAccounts, cngn);
    future = new FutureAsset(subAccounts, CONTRACT_SIZE);
    spotFeed = new MockFeeds();
    spotFeed.setSpot(SPOT, 1e18);

    manager = new MarginEngine(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), viewer);
    viewer.setMarginEngine(manager);
    marketId = manager.createMarket("cngn");
    manager.whitelistAsset(cngnAsset, marketId, IMarginEngine.AssetType.Base);
    manager.whitelistAsset(future, marketId, IMarginEngine.AssetType.Future);
    manager.setOraclesForMarket(marketId, ISpotFeed(address(spotFeed)), IForwardFeed(address(0)), IVolFeed(address(0)));
    stableFeed = new MockFeeds();
    stableFeed.setSpot(1e18, 1e18);
    manager.setStableFeed(stableFeed);
    _setFutureMargin(0.1e18, 0.2e18);
    pool = manager.accId();

    cngnAsset.setWhitelistManager(address(manager), true);
    future.setWhitelistManager(address(manager), true);
    cngnAsset.setTotalPositionCap(manager, 1e36);
    future.setTotalPositionCap(manager, 1e36);

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);

    expiry = block.timestamp + 30 days;
    lastTradeTime = expiry - 1 hours;
    subId = future.setContract(uint64(expiry), uint64(lastTradeTime), MARK);

    usdc.approve(address(cash), type(uint).max);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  /// @dev FutureManager's MarginParams, as the engine's per-market settings: cNGN at a 0.5 factor, no extra IM haircut
  function _setFutureMargin(uint mm, uint im) internal {
    manager.setFutureMarginRequirements(marketId, mm, im);
    manager.setBaseAssetMarginFactor(marketId, 0.5e18, 1e18);
  }

  function _fundCash(uint acc, uint amount18) internal {
    usdc.mint(address(this), amount18);
    cash.deposit(acc, amount18);
  }

  function _depositCngn(uint acc, uint amount18) internal {
    uint native = amount18 / 1e12;
    cngn.mint(address(this), native);
    cngn.approve(address(cngnAsset), native);
    cngnAsset.deposit(acc, native);
  }

  /// @dev bob sells `amount` contracts to alice at `price`, carried in assetData as the trade module does.
  function _trade(uint seller, uint buyer, int amount, uint price) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: future, subId: subId, amount: amount, assetData: bytes32(price)
      }),
      ""
    );
  }

  function _mark(uint price) internal {
    vm.warp(block.timestamp + 1 days);
    future.setMark(subId, uint64(block.timestamp), price);
  }

  function _cngn(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cngnAsset, 0);
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  function _position(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, future, subId);
  }

  /// @dev both traders funded well above IM, the pool seeded with a cNGN reserve, one contract open at the mark.
  function _openAtMark() internal {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(aliceAcc, 100_000e18);
    _depositCngn(bobAcc, 100_000e18);
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
  }

  ///////////////////
  //  settlement   //
  ///////////////////

  function testTradeAtMarkAccruesNothing() public {
    _openAtMark();
    assertEq(_position(aliceAcc), 1e18);
    assertEq(_position(bobAcc), -1e18);
    assertEq(future.getPendingVM(aliceAcc, subId), 0);
    assertEq(future.getPendingVM(bobAcc, subId), 0);
    assertEq(_cngn(aliceAcc), 100_000e18);
    assertEq(_cngn(bobAcc), 100_000e18);
  }

  function testMarkUpPaysTheLongInCngn() public {
    _openAtMark();
    _mark(1010e18); // +10 cNGN per USDC: long gains 10,000 cNGN

    assertEq(future.getPendingVM(aliceAcc, subId), 10_000e18);
    assertEq(future.getPendingVM(bobAcc, subId), -10_000e18);

    manager.settleAccount(bobAcc);
    manager.settleAccount(aliceAcc);

    assertEq(_cngn(aliceAcc), 110_000e18);
    assertEq(_cngn(bobAcc), 90_000e18);
    assertEq(_cngn(pool), 100_000e18, "pool back to its reserve");
    // nothing moved as cash
    assertEq(_cash(aliceAcc), 1_000e18);
    assertEq(_cash(bobAcc), 1_000e18);
    assertEq(_cash(pool), 0);
  }

  function testMarkDownPaysTheShortInCngn() public {
    _openAtMark();
    _mark(990e18);

    manager.settleAccount(aliceAcc);
    manager.settleAccount(bobAcc);

    assertEq(_cngn(aliceAcc), 90_000e18);
    assertEq(_cngn(bobAcc), 110_000e18);
    assertEq(_cngn(pool), 100_000e18);
  }

  function testWinnerSettledFirstIsPaidFromTheReserve() public {
    _openAtMark();
    _mark(1010e18);

    manager.settleAccount(aliceAcc);
    assertEq(_cngn(aliceAcc), 110_000e18);
    assertEq(_cngn(pool), 90_000e18, "reserve fronted the winner");

    manager.settleAccount(bobAcc);
    assertEq(_cngn(pool), 100_000e18, "loser refilled it");
  }

  function testEmptyPoolPaysTheWinnerInUsdc() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(bobAcc, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);

    manager.settleAccount(aliceAcc); // pool holds no cNGN
    assertEq(_cngn(aliceAcc), 0);
    assertEq(_cash(aliceAcc), 1_010e18, "10,000 cNGN at 0.001 = 10 USDC");
    assertEq(_cash(pool), -10e18);

    manager.settleAccount(bobAcc);
    assertEq(_cngn(pool), 10_000e18, "the pool now holds the cNGN and owes the cash: treasury rebalances");
  }

  function testLoserShortOfCngnPaysTheRemainderInUsdc() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(bobAcc, 4_000e18);
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18); // bob owes 10,000 cNGN, holds 4,000

    manager.settleAccount(bobAcc);
    assertEq(_cngn(bobAcc), 0);
    assertEq(_cash(bobAcc), 1_000e18 - 6e18, "6,000 cNGN at 0.001 = 6 USDC");
    assertEq(_cngn(pool), 104_000e18);
    assertEq(_cash(pool), 6e18);
  }

  function testRemainderRoundsAgainstTheTrader() public {
    spotFeed.setSpot(SPOT + 1, 1e18);
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1000e18 + 1); // 1,000 wei of cNGN owed: 1,000 * (0.001e18 + 1) / 1e18 is not whole

    manager.settleAccount(bobAcc);
    assertEq(_cash(pool), 2, "ceil(1000 * 1000000000000001 / 1e18) = 2 wei");
  }

  function testInsolventLoserStillSettles() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 300e18);
    _depositCngn(pool, 1_000_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    for (uint i; i < 10; ++i) {
      _mark(MARK + (i + 1) * 50e18); // 5% steps up to 1500: bob owes 500,000 cNGN = 500 USDC
    }

    manager.settleAccount(bobAcc);
    assertEq(_cash(bobAcc), 300e18 - 500e18, "cash goes negative instead of reverting");
    assertLt(manager.getMargin(bobAcc, false), 0);
  }

  ///////////////////
  //  fill prices  //
  ///////////////////

  function testFillAboveTheMarkChargesTheBuyerImmediately() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(aliceAcc, 100_000e18);
    _depositCngn(bobAcc, 100_000e18);
    _depositCngn(pool, 100_000e18);

    _trade(bobAcc, aliceAcc, 1e18, 1010e18); // bought 10 above the mark

    assertEq(_cngn(aliceAcc), 90_000e18);
    assertEq(_cngn(bobAcc), 110_000e18);
    assertEq(_cngn(pool), 100_000e18);

    // marked to the fill price, the trade is flat again
    _mark(1010e18);
    manager.settleAccount(aliceAcc);
    manager.settleAccount(bobAcc);
    assertEq(_cngn(aliceAcc), 100_000e18);
    assertEq(_cngn(bobAcc), 100_000e18);
  }

  function testReducingAtAFillRealisesOnlyTheClosedPart() public {
    _openAtMark();
    _trade(bobAcc, aliceAcc, 1e18, MARK); // alice long 2, bob short 2, at the mark

    // alice sells 1 back to bob at 1020, mark still 1000: alice realises +20,000 on the closed contract
    _trade(aliceAcc, bobAcc, 1e18, 1020e18);
    assertEq(_cngn(aliceAcc), 120_000e18);
    assertEq(_cngn(bobAcc), 80_000e18);
    assertEq(_position(aliceAcc), 1e18);

    // the remaining contract still runs from the mark
    _mark(1010e18);
    assertEq(future.getPendingVM(aliceAcc, subId), 10_000e18);
  }

  function testClosingFullyAtAFillPaysOut() public {
    _openAtMark();
    // alice sells her only contract back at 1020: the position leaves her balances, the VM must still land
    _trade(aliceAcc, bobAcc, 1e18, 1020e18);
    assertEq(_position(aliceAcc), 0);
    assertEq(_position(bobAcc), 0);
    assertEq(_cngn(aliceAcc), 120_000e18);
    assertEq(_cngn(bobAcc), 80_000e18);
    assertEq(future.accountCngnToSettle(aliceAcc, subId), 0, "nothing stranded");
    assertEq(future.accountCngnToSettle(bobAcc, subId), 0, "nothing stranded");
  }

  function testTransferWithoutAPriceMovesAtTheMark() public {
    _openAtMark();
    _mark(1010e18);
    uint charlieAcc = subAccounts.createAccountWithApproval(address(0xcc), address(this), manager);
    _fundCash(charlieAcc, 1_000e18);

    // alice hands her contract to charlie with no price: alice keeps the VM to date, charlie starts at the mark
    _trade(aliceAcc, charlieAcc, 1e18, 0);
    assertEq(_cngn(aliceAcc), 110_000e18);
    assertEq(future.getPendingVM(charlieAcc, subId), 0);
  }

  ///////////////////
  //    margin     //
  ///////////////////

  function testMarginIsCashPlusHaircutCngnLessRequirement() public {
    _openAtMark();
    // alice: 1,000 cash + 100,000 cNGN * 0.001 * 0.5 = 50, less 20% of 1,000 USDC notional
    assertEq(manager.getMargin(aliceAcc, true), 1_000e18 + 50e18 - 200e18);
    assertEq(manager.getMargin(aliceAcc, false), 1_000e18 + 50e18 - 100e18);
    (, int mtm) = manager.getMarginAndMarkToMarket(aliceAcc, true, 0);
    assertEq(mtm, 1_000e18 + 100e18, "mark to market values cNGN at par");
  }

  function testPendingLossCountsAtPar() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);

    // bob owes 10,000 cNGN he has not paid: counted as -10 USDC, not haircut
    assertEq(manager.getMargin(bobAcc, false), 1_000e18 - 10e18 - 100e18);
  }

  function testCannotOpenBelowInitialMargin() public {
    _fundCash(aliceAcc, 199e18);
    _fundCash(bobAcc, 1_000e18);
    vm.expectRevert(IMarginEngine.SRM_PortfolioBelowMargin.selector);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
  }

  function testCngnCountsTowardsInitialMargin() public {
    _fundCash(aliceAcc, 150e18);
    _depositCngn(aliceAcc, 100_000e18); // worth 50 after the haircut: 200 total
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    assertEq(_position(aliceAcc), 1e18);
  }

  function testReductionIsHeldToMaintenanceOnly() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 400e18);
    _depositCngn(pool, 1_000_000e18);
    _trade(bobAcc, aliceAcc, 2e18, MARK); // bob short 2: IM 400
    _mark(1050e18); // bob owes 100,000 cNGN = 100 USDC: margin 300 vs IM 400, MM 200

    assertLt(manager.getMargin(bobAcc, true), 0);
    assertGt(manager.getMargin(bobAcc, false), 0);

    // bob may still buy one back
    _trade(aliceAcc, bobAcc, 1e18, 1050e18);
    assertEq(_position(bobAcc), -1e18);
  }

  /// @dev Between MM and IM after the reduction: only a maintenance check lets it through. (The test above ends above
  ///      IM, so it cannot tell the two apart.)
  function testReductionBelowInitialIsAllowedAtMaintenance() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 400e18);
    _depositCngn(pool, 1_000_000e18);
    _trade(bobAcc, aliceAcc, 2e18, MARK); // bob short 2: IM 400, MM 200
    _mark(1120e18); // bob owes 240 USDC of VM: 160 left against MM 200, below maintenance

    _trade(aliceAcc, bobAcc, 1e18, 1120e18); // bob buys one back
    assertEq(_position(bobAcc), -1e18);
    assertEq(manager.getMargin(bobAcc, false), 160e18 - 100e18, "above maintenance once reduced");
    assertEq(manager.getMargin(bobAcc, true), 160e18 - 200e18, "still below initial: an IM check would refuse it");
  }

  function testCannotDrawCashBelowZero() public {
    _fundCash(aliceAcc, 100e18);
    vm.prank(alice);
    vm.expectRevert(IMarginEngine.SRM_NoNegativeCash.selector);
    cash.withdraw(aliceAcc, 101e18, alice);
  }

  /// @dev The pool is owned by the manager, which grants no allowances, so a transfer cannot reach it. The one path
  ///      that could put a position there without an allowance is a liquidation bid naming it as the liquidator.
  function testPoolCannotBeTheLiquidator() public {
    vm.prank(address(auction));
    vm.expectRevert(IMarginEngine.ME_PoolCannotBid.selector);
    manager.executeBid(bobAcc, pool, 1e18, 0, 0);
  }

  function testRejectsOtherAssets() public {
    WrappedERC20Asset other = new WrappedERC20Asset(subAccounts, usdc);
    other.setWhitelistManager(address(manager), true);
    other.setTotalPositionCap(manager, 1e36);
    usdc.mint(address(this), 1e6);
    usdc.approve(address(other), 1e6);
    vm.expectRevert(IMarginEngine.SRM_UnsupportedAsset.selector);
    other.deposit(aliceAcc, 1e6);
  }

  ///////////////////
  //     marks     //
  ///////////////////

  function testMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAsset.FA_MarkDeviationExceeded.selector);
    future.setMark(subId, uint64(block.timestamp), 1051e18);
    future.setMark(subId, uint64(block.timestamp), 1050e18);
  }

  function testStaleMarkIsRejected() public {
    future.setMarkBounds(0, 600);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAsset.FA_StaleMark.selector);
    future.setMark(subId, uint64(block.timestamp - 601), 1001e18);
  }

  function testMarkCannotBeInTheFuture() public {
    vm.expectRevert(IFutureAsset.FA_InvalidMark.selector);
    future.setMark(subId, uint64(block.timestamp + 1), 1001e18);
  }

  function testOnlyOwnerMarks() public {
    vm.warp(block.timestamp + 1 days);
    vm.prank(alice);
    vm.expectRevert();
    future.setMark(subId, uint64(block.timestamp), 1001e18);
  }

  ///////////////////
  //    expiry     //
  ///////////////////

  function testTradingClosesAtLastTradeTime() public {
    _openAtMark();
    vm.warp(lastTradeTime);
    vm.expectRevert(IFutureAsset.FA_TradingClosed.selector);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
  }

  function testSettlementPriceOnlyAfterExpiry() public {
    vm.warp(expiry - 1);
    vm.expectRevert(IFutureAsset.FA_NotExpired.selector);
    future.setSettlementPrice(subId, 1001e18);
  }

  function testCloseOutBeforeSettlementReverts() public {
    _openAtMark();
    vm.warp(expiry);
    vm.expectRevert(IMarginEngine.ME_NotSettled.selector);
    manager.closeOutExpired(aliceAcc, subId);
  }

  function testCloseOutAfterSettlementRemovesPositionsAndPaysTheLastLeg() public {
    _openAtMark();
    _useIndex();
    _mark(1010e18); // reads the index (1000) as the fallback's reference
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1015e18); // last leg +5 on top of +10, 1.5% from the reference

    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);

    assertEq(_position(aliceAcc), 0);
    assertEq(_position(bobAcc), 0);
    assertEq(_cngn(aliceAcc), 115_000e18);
    assertEq(_cngn(bobAcc), 85_000e18);
    assertEq(_cngn(pool), 100_000e18);
    assertEq(future.totalPosition(manager), 0, "open interest is zero");

    // once closed, the accounts are cash and cNGN only, and free to withdraw
    vm.prank(alice);
    cngnAsset.withdraw(aliceAcc, 115_000e6, alice);
    assertEq(cngn.balanceOf(alice), 115_000e6);
  }

  function testNoMarksAfterSettlement() public {
    _useIndex();
    _mark(1001e18);
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1001e18);
    vm.expectRevert(IFutureAsset.FA_AlreadySettled.selector);
    future.setSettlementPrice(subId, 1002e18);
    vm.expectRevert(IFutureAsset.FA_AlreadySettled.selector);
    future.setMark(subId, uint64(block.timestamp), 1002e18);
  }

  ///////////////////
  // index, fixing //
  ///////////////////

  uint constant WINDOW = 1 hours;
  uint constant GAP = 15 minutes;
  uint constant FALLBACK = 24 hours;
  uint constant NARROWING = 14 days;

  /// @dev the index feed is USDC per cNGN; 0.001 is 1000 cNGN per USDC, the mark
  function _useIndex() internal {
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, NARROWING, WINDOW, GAP, FALLBACK);
  }

  /// @dev sample every 15 minutes across the window: 1000 for the first half, 1250 (0.0008) for the second
  function _sampleWindow() internal {
    uint start = expiry - WINDOW;
    for (uint i; i < 4; ++i) {
      vm.warp(start + i * GAP);
      spotFeed.setSpot(i < 2 ? SPOT : 0.0008e18, 1e18);
      future.recordFixingSample(subId);
    }
    vm.warp(expiry);
  }

  function testMarkMustSitInsideTheIndexBand() public {
    _useIndex();
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1101e18);
    future.setMark(subId, uint64(block.timestamp), 1100e18); // exactly 10% over
  }

  function testIndexParamsAreValidated() public {
    vm.expectRevert(IFutureAsset.FA_InvalidIndexParams.selector);
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, NARROWING, WINDOW, WINDOW + 1, FALLBACK);
    vm.expectRevert(IFutureAsset.FA_InvalidIndexParams.selector);
    future.setIndexParams(ISpotFeed(address(0)), 0.1e18, 0.01e18, NARROWING, WINDOW, GAP, FALLBACK);
    vm.expectRevert(IFutureAsset.FA_InvalidIndexParams.selector);
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.11e18, NARROWING, WINDOW, GAP, FALLBACK);
  }

  function testFixingIsTheTimeWeightedIndex() public {
    _useIndex();
    _sampleWindow();
    future.fixSettlementFromIndex(subId);

    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    assertTrue(c.settled);
    assertEq(c.markPrice, 1125e18, "half the window at 1000, half at 1250");
  }

  function testFixingPaysTheLastLegAndClosesOut() public {
    _openAtMark();
    _useIndex();
    _sampleWindow();
    future.fixSettlementFromIndex(subId);

    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);
    assertEq(_cngn(aliceAcc), 225_000e18, "long gains 125 cNGN per USDC on 1,000 USDC");
    assertEq(_cngn(bobAcc), 0);
    assertEq(_position(aliceAcc), 0);
  }

  function testFixingIsNotHeldToTheMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    _useIndex();
    _sampleWindow(); // 12.5% from the last mark
    future.fixSettlementFromIndex(subId);
    assertTrue(future.futureContracts(subId).settled);
  }

  function testAnyoneMayFix() public {
    _useIndex();
    _sampleWindow();
    vm.prank(address(0xdead));
    future.fixSettlementFromIndex(subId);
    assertTrue(future.futureContracts(subId).settled);
  }

  function testFixingRefusedBeforeExpiry() public {
    _useIndex();
    vm.warp(expiry - 1);
    future.recordFixingSample(subId);
    vm.expectRevert(IFutureAsset.FA_NotExpired.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testFixingRefusedWithAGap() public {
    _useIndex();
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId);
    vm.warp(start + GAP + 1); // one second too late
    future.recordFixingSample(subId);
    vm.warp(start + 2 * GAP);
    future.recordFixingSample(subId);
    vm.warp(start + 3 * GAP);
    future.recordFixingSample(subId);
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testFixingRefusedWhenTheWindowStartsUnsampled() public {
    _useIndex();
    // densely sampled from one second past the allowed start right through to expiry: only the start is uncovered
    for (uint t = expiry - WINDOW + GAP + 1; t <= expiry; t += 60) {
      vm.warp(t);
      future.recordFixingSample(subId);
    }
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  /// @dev uneven spacing, where a time weighting and a per-sample average disagree
  function testFixingWeightsEachSampleByHowLongItHeld() public {
    _useIndex();
    uint start = expiry - WINDOW;
    uint[5] memory at = [uint(0), 5 minutes, 15 minutes, 30 minutes, 45 minutes];
    for (uint i; i < 5; ++i) {
      vm.warp(start + at[i]);
      spotFeed.setSpot(i == 0 ? SPOT : 0.0008e18, 1e18);
      future.recordFixingSample(subId);
    }
    vm.warp(expiry);
    future.fixSettlementFromIndex(subId);
    // 1000 for 5 minutes, 1250 for 55: (1000 * 300 + 1250 * 3300) / 3600; a per-sample mean would be 1200
    assertEq(future.futureContracts(subId).markPrice, uint(1000e18 * 300 + 1250e18 * 3300) / 3600);
  }

  function testFixingRefusedWhenTheWindowEndsUnsampled() public {
    _useIndex();
    vm.warp(expiry - WINDOW);
    future.recordFixingSample(subId);
    vm.warp(expiry - WINDOW + GAP);
    future.recordFixingSample(subId);
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testSamplesOnlyInsideTheWindow() public {
    _useIndex();
    vm.warp(expiry - WINDOW - 1);
    vm.expectRevert(IFutureAsset.FA_OutsideFixingWindow.selector);
    future.recordFixingSample(subId);
    vm.warp(expiry + 1);
    vm.expectRevert(IFutureAsset.FA_OutsideFixingWindow.selector);
    future.recordFixingSample(subId);
  }

  function testParamsCannotMoveAWindowUnderWay() public {
    _useIndex();
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId);
    // widening the gap limit mid-window does not loosen this fixing
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, NARROWING, WINDOW, WINDOW, FALLBACK);
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testOwnerFallbackOnlyAfterTheDelayAndOnlyWithoutAFixing() public {
    _useIndex();
    _mark(1001e18); // the fallback needs a reference: this mark reads the index
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_NotExpired.selector);
    future.setSettlementPrice(subId, 1001e18);

    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1001e18); // nothing was sampled; bounded by the index the mark read
    assertEq(future.futureContracts(subId).markPrice, 1001e18);
  }

  /// @dev two samples, then the index goes stale: the reference is their TWAP, the last held for one gap limit
  function _sampleThenGoStale() internal {
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId); // 1000
    vm.warp(start + GAP);
    spotFeed.setSpot(0.0008e18, 1e18);
    future.recordFixingSample(subId); // 1250
  }

  function testFallbackInsideTheBandOfTheSampleTwap() public {
    _useIndex();
    _sampleThenGoStale();
    vm.warp(expiry + FALLBACK);
    assertEq(future.fallbackReference(subId), 1125e18, "1000 for 15 minutes, 1250 for its 15-minute limit");
    future.setSettlementPrice(subId, 1147e18); // 1.96% over
    assertEq(future.futureContracts(subId).markPrice, 1147e18);
  }

  function testFallbackOutsideTheBandOfTheSampleTwapIsRefused() public {
    _useIndex();
    _sampleThenGoStale();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 1148e18); // 2.04% over
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 1102e18); // 2.04% under
  }

  function testFallbackWithoutSamplesIsBoundedByTheLastIndexRead() public {
    _useIndex();
    _mark(1001e18); // reads 1000
    spotFeed.setSpot(0.0008e18, 1e18); // the live index moves to 1250 afterwards: the last READ one is the reference
    vm.warp(expiry + FALLBACK);
    assertEq(future.fallbackReference(subId), 1000e18);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 1021e18);
    future.setSettlementPrice(subId, 1020e18);
    assertTrue(future.futureContracts(subId).settled);
  }

  function testFallbackWithNoReferenceIsRefused() public {
    _useIndex();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_NoSettlementReference.selector);
    future.setSettlementPrice(subId, 1000e18);
  }

  /// @dev the reference bound replaces the mark deviation bound, which would otherwise block settling at the index
  function testFallbackIsNotHeldToTheMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    _useIndex();
    _mark(1050e18);
    _mark(1100e18); // both inside the 10% index band; the last index read is 1000
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1000e18); // 9% from the last mark, at the reference
    assertTrue(future.futureContracts(subId).settled);
  }

  function testOwnerCannotOverrideACompleteFixing() public {
    _useIndex();
    _sampleWindow();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_FixingAvailable.selector);
    future.setSettlementPrice(subId, 1001e18);
  }

  ///////////////////
  // expiry, no feed //
  ///////////////////

  /// @dev alice long 1, bob short 1, both cash only, no pool reserve; marked 1010 (reading the index at 1000), then
  ///      the feed dies and the fallback settles at `price` once the delay has run.
  function _settleWithADeadFeed(uint price) internal {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);
    vm.mockCallRevert(address(spotFeed), abi.encodeWithSelector(ISpotFeed.getSpot.selector), "stale");
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, price);
  }

  function testCloseOutConvertsAtTheSettlementPriceWithADeadFeed() public {
    _settleWithADeadFeed(1015e18);

    // bob owes 15 cNGN per USDC on 1,000 USDC and holds no cNGN: he pays its USDC value at 1015, rounded up
    uint owedCngn = 15_000e18;
    uint bobPays = Math.mulDiv(owedCngn, 1e18, 1015e18, Math.Rounding.Ceil);
    manager.closeOutExpired(bobAcc, subId);
    assertEq(_position(bobAcc), 0, "bob closed out");
    assertEq(_cash(bobAcc), 1_000e18 - int(bobPays), "in USDC at the settlement price");

    // the pool has no cNGN either, so alice is paid in USDC at the same price, rounded down
    uint alicePaid = Math.mulDiv(owedCngn, 1e18, 1015e18, Math.Rounding.Floor);
    manager.closeOutExpired(aliceAcc, subId);
    assertEq(_position(aliceAcc), 0, "alice closed out");
    assertEq(_cash(aliceAcc), 1_000e18 + int(alicePaid));
    assertEq(future.totalPosition(manager), 0, "no open interest left");
  }

  function testCloseOutRoundingNeverFavoursTheTrader() public {
    // 15,000 cNGN at 1015 cNGN per USDC is 14.77832512315270935960... USDC: not a whole number of wei
    _settleWithADeadFeed(1015e18);
    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);

    uint owed = 15_000e18;
    uint price = 1015e18;
    uint exact = owed * 1e18 / price;
    assertTrue(owed * 1e18 % price != 0, "the conversion has a remainder");
    assertEq(_cash(bobAcc), 1_000e18 - int(exact) - 1, "the loser pays the extra wei");
    assertEq(_cash(aliceAcc), 1_000e18 + int(exact), "the winner gets the floor");
    assertEq(_cash(pool), 1, "the pool keeps the wei and is never short");
  }

  function testPreExpirySettlementStillUsesTheFeed() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);
    vm.mockCallRevert(address(spotFeed), abi.encodeWithSelector(ISpotFeed.getSpot.selector), "stale");
    // bob owes 10,000 cNGN with none held: converting it before expiry needs the feed
    vm.expectRevert(bytes("stale"));
    manager.settleAccount(bobAcc);
  }

  ///////////////////
  //  IM boundary  //
  ///////////////////

  /// @dev at the launch margin, IM 25% of 1,000 USDC is 250 USDC: one wei either side of it
  function testOpeningAtTheLaunchIMBoundary() public {
    _setFutureMargin(0.15e18, 0.25e18);
    _fundCash(bobAcc, 10_000e18);

    uint above = subAccounts.createAccountWithApproval(address(0xa1), address(this), manager);
    _fundCash(above, 250e18 + 1);
    _trade(bobAcc, above, 1e18, MARK);
    assertEq(_position(above), 1e18, "just above IM opens");
    assertEq(manager.getMargin(above, true), 1, "with one wei to spare");

    uint below = subAccounts.createAccountWithApproval(address(0xa2), address(this), manager);
    _fundCash(below, 250e18 - 1);
    vm.expectRevert(IMarginEngine.SRM_PortfolioBelowMargin.selector);
    _trade(bobAcc, below, 1e18, MARK);
  }

  ///////////////////
  //  band, feed   //
  ///////////////////

  function _markAt(uint t, uint price) internal {
    vm.warp(t);
    future.setMark(subId, uint64(t), price);
  }

  function testBandIsFullUntilTheNarrowingPeriod() public {
    _useIndex();
    assertEq(future.markIndexBand(uint64(expiry)), 0.1e18);
    _markAt(expiry - NARROWING, 1100e18); // exactly at the start of narrowing: still 10%
  }

  function testBandNarrowsLinearlyToOnePercentAtExpiry() public {
    _useIndex();
    vm.warp(expiry - NARROWING / 2);
    assertEq(future.markIndexBand(uint64(expiry)), 0.055e18, "halfway: 1% + 9% / 2");
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1056e18);
    future.setMark(subId, uint64(block.timestamp), 1055e18);

    vm.warp(expiry);
    assertEq(future.markIndexBand(uint64(expiry)), 0.01e18, "1% at expiry");
  }

  function testBandNearExpiryRefusesAMarkTheFullBandWouldTake() public {
    _useIndex();
    _markAt(expiry - 1 hours, 1010e18); // band ~1.03%: 1% inside it
    vm.warp(expiry - 30 minutes);
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1050e18); // inside 10%, outside ~1%
  }

  function testNoNarrowingWhenThePeriodIsZero() public {
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, 0, WINDOW, GAP, FALLBACK);
    vm.warp(expiry - 1);
    assertEq(future.markIndexBand(uint64(expiry)), 0.1e18);
  }

  /// @dev forward of 0.000990099... USDC per cNGN: a mark of ~1010 cNGN per USDC
  uint constant FORWARD = 990099009900990;

  function _useForward() internal {
    _useIndex();
    future.setForwardFeed(IForwardFeed(address(spotFeed)), 1 hours);
    spotFeed.setForwardPrice(expiry, FORWARD, 1e18);
  }

  function testAnyoneMayPullTheMarkFromTheForwardFeed() public {
    _useForward();
    _openAtMark();
    vm.warp(block.timestamp + 1 hours);
    vm.prank(address(0xbeef));
    future.pullMark(subId);

    uint mark = 1e36 / FORWARD;
    assertEq(future.futureContracts(subId).markPrice, mark, "the inverse of the forward");
    assertEq(future.futureContracts(subId).lastMarkTime, block.timestamp);
    assertEq(future.getPendingVM(aliceAcc, subId), int((mark - MARK) * CONTRACT_SIZE / 1e18), "VM accrues from it");
  }

  function testPullsAreRateLimited() public {
    _useForward();
    vm.warp(block.timestamp + 1 hours);
    future.pullMark(subId);
    vm.warp(block.timestamp + 1 hours - 1);
    vm.expectRevert(IFutureAsset.FA_MarkTooSoon.selector);
    future.pullMark(subId);
    vm.warp(block.timestamp + 1);
    future.pullMark(subId);
  }

  function testPulledMarkIsHeldToTheIndexBandAndMoveLimit() public {
    _useForward();
    future.setMarkBounds(0.05e18, 0);
    vm.warp(block.timestamp + 1 hours);
    spotFeed.setForwardPrice(expiry, 0.00094e18, 1e18); // ~1063.8: a 6.4% move
    vm.expectRevert(IFutureAsset.FA_MarkDeviationExceeded.selector);
    future.pullMark(subId);

    future.setMarkBounds(0.2e18, 0);
    spotFeed.setForwardPrice(expiry, 0.00089e18, 1e18); // ~1123.6: 12.4% from the index
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.pullMark(subId);
  }

  function testNoPullsWithoutAFeedOrAfterLastTrade() public {
    _useIndex();
    vm.warp(block.timestamp + 1 hours);
    vm.expectRevert(IFutureAsset.FA_NoForwardFeed.selector);
    future.pullMark(subId);

    future.setForwardFeed(IForwardFeed(address(spotFeed)), 1 hours);
    spotFeed.setForwardPrice(expiry, FORWARD, 1e18);
    vm.warp(lastTradeTime);
    vm.expectRevert(IFutureAsset.FA_MarkingClosed.selector);
    future.pullMark(subId);
  }

  function testOwnerMarksWhenTheForwardFeedIsDown() public {
    _useForward();
    vm.mockCallRevert(address(spotFeed), abi.encodeWithSelector(IForwardFeed.getForwardPrice.selector), "stale");
    vm.warp(block.timestamp + 1 hours);
    vm.expectRevert(bytes("stale"));
    future.pullMark(subId);
    future.setMark(subId, uint64(block.timestamp), 1010e18);
    assertEq(future.futureContracts(subId).markPrice, 1010e18);
  }

  /// @dev The SRM settles a dated future by calling settleAccount(uint,uint) and booking the result as USDC cash.
  ///      FutureAsset has no such function, so an SRM that whitelisted it by mistake would revert, not mis-credit.
  function testAnSrmCannotSettleThisAsset() public {
    (bool ok,) = address(future).call(abi.encodeWithSignature("settleAccount(uint256,uint256)", aliceAcc, uint(subId)));
    assertFalse(ok, "no settleAccount: an SRM's call reverts");
  }

  ///////////////////
  //  liquidation  //
  ///////////////////

  function testBidAfterTheAuctionSettlesMovesTheAccountAtTheMark() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 300e18);
    _depositCngn(pool, 1_000_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1050e18);
    _mark(1100e18);
    _mark(1150e18);
    _mark(1200e18); // bob owes 200,000 cNGN = 200 USDC; margin 300 - 200 - 100 = 0
    _mark(1210e18); // and now below MM

    assertLt(manager.getMargin(bobAcc, false), 0);

    uint liquidatorAcc = subAccounts.createAccountWithApproval(address(0x11), address(this), manager);
    _fundCash(liquidatorAcc, 10_000e18);

    // the auction settles the account before it prices or takes a bid (DutchAuction.bid), then executes it
    manager.settlePerpsWithIndex(bobAcc);
    vm.prank(address(auction));
    manager.executeBid(bobAcc, liquidatorAcc, 1e18, 0, 0);

    assertEq(_position(liquidatorAcc), -1e18, "the liquidator takes the short");
    assertEq(_position(bobAcc), 0);
    assertEq(_cash(liquidatorAcc), 10_000e18 + 300e18 - 210e18, "and bob's cash, net of the VM bob paid first");
    assertEq(future.getPendingVM(liquidatorAcc, subId), 0, "the position arrives at the mark");
  }

  function testOnlyTheAuctionBids() public {
    vm.expectRevert();
    manager.executeBid(bobAcc, aliceAcc, 1e18, 0, 0);
  }

  ////////////////////////////////////////////
  //  the engine: what the fork itself adds  //
  ////////////////////////////////////////////

  /// @dev Unsettled VM due to an account counts at the base factor, as the cNGN it settles into will: margin reads the
  ///      same before and after settlement. Mark-to-market counts it at par.
  function testUnsettledGainCountsAtTheBaseFactorAndSettlingChangesNothing() public {
    _openAtMark();
    _mark(1010e18); // alice is due 10,000 cNGN, 10 USDC at spot

    // 1,000 cash + 100,000 cNGN at 0.5 (50) + the 10 due at 0.5 (5), less 10% of 1,000 USDC notional
    int before = manager.getMargin(aliceAcc, false);
    assertEq(before, 1_000e18 + 50e18 + 5e18 - 100e18);
    (, int mtm) = manager.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertEq(mtm, 1_000e18 + 100e18 + 10e18, "mark-to-market counts the VM due at par");

    manager.settleAccount(aliceAcc);
    assertEq(_cngn(aliceAcc), 110_000e18, "paid in cNGN");
    assertEq(manager.getMargin(aliceAcc, false), before, "settled or not, margin reads the same");
  }

  /// @dev The point of the engine: spot cNGN, a perp and a future in one account, one margin. Gross in v1: a perp and a
  ///      future on the same market each carry their own requirement.
  function testSpotPerpAndFutureAreMarginedInOneAccount() public {
    MockPerp perp = new MockPerp(subAccounts);
    perp.setMockPerpPrice(SPOT, 1e18);
    perp.setTotalPositionCap(manager, 1e36);
    manager.whitelistAsset(perp, marketId, IMarginEngine.AssetType.Perpetual);
    manager.setPerpMarginRequirements(marketId, 0.1e18, 0.2e18);

    _openAtMark(); // alice: 1,000 cash, 100,000 cNGN, long 1 future
    // alice long 1,000,000 cNGN of perp (1,000 USDC at spot) from bob
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: perp, subId: 0, amount: 1_000_000e18, assetData: bytes32(0)
      }),
      ""
    );
    _mark(1010e18); // the future is up 10 USDC for alice, unsettled
    perp.mockAccountPnlAndFunding(aliceAcc, 0, -20e18); // the perp is down 20 USDC, unrealised

    // MM: 1,000 cash + 50 (cNGN at 0.5) + 5 (future VM due, at 0.5) - 20 (perp PnL) - 100 (perp MM) - 100 (future MM)
    assertEq(manager.getMargin(aliceAcc, false), 1_000e18 + 50e18 + 5e18 - 20e18 - 100e18 - 100e18);
  }

  /// @dev The depeg IM penalty applies to the futures' own USDC notional, as it does to a perp's. Maintenance is unchanged.
  function testDepegPenaltyOnFuturesNotional() public {
    _openAtMark();
    int imPegged = manager.getMargin(aliceAcc, true);
    int mmPegged = manager.getMargin(aliceAcc, false);

    manager.setDepegParameters(IMarginEngine.DepegParams({threshold: 0.99e18, depegFactor: 2e18}));
    stableFeed.setSpot(0.98e18, 1e18); // (0.99 - 0.98) x 2 = 2% of notional
    assertEq(manager.getMargin(aliceAcc, true), imPegged - 20e18, "2% of the 1,000 USDC contract");
    assertEq(manager.getMargin(aliceAcc, false), mmPegged, "maintenance has no depeg penalty");
  }

  /// @dev A cap below open interest means close-only: a holder can still deposit, and reduce, but not grow.
  ///      Under BasePortfolioViewer's check the deposit reverts BM_AssetCapExceeded (the asset was untouched by it).
  function testCapBelowOpenInterestIsCloseOnlyNotFrozen() public {
    _openAtMark(); // 2 contracts of open interest, summed over both sides
    future.setTotalPositionCap(manager, 1e18);

    _fundCash(aliceAcc, 1e18); // a holder can still deposit

    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _trade(bobAcc, aliceAcc, 1e18, MARK); // nor grow

    _trade(aliceAcc, bobAcc, 1e18, MARK); // but can close
    assertEq(_position(aliceAcc), 0);
  }

  function testCloseOutOfASeriesNoMarketListsReverts() public {
    vm.expectRevert(IMarginEngine.ME_NotFuture.selector);
    manager.closeOutExpired(aliceAcc, subId + 1);
  }

  function testOnlyTheOwnerWithdrawsFromThePool() public {
    _depositCngn(pool, 1_000e18);
    vm.prank(alice);
    vm.expectRevert();
    manager.withdrawFromPool(IERC20BasedAsset(address(cngnAsset)), 1e6, alice);

    manager.withdrawFromPool(IERC20BasedAsset(address(cngnAsset)), 1e6, address(0x7ea5));
    assertEq(cngn.balanceOf(address(0x7ea5)), 1e6);
  }

  /// @dev Anyone may realise VM: the keeper's sweep needs no role.
  function testAnyoneMaySettle() public {
    _openAtMark();
    _mark(1010e18);
    vm.prank(address(0xbeef));
    manager.settleAccount(aliceAcc);
    assertEq(_cngn(aliceAcc), 110_000e18);
  }

  /////////////////////////////////////////////////////////////
  //  invariance: views value unsettled VM as settlement pays  //
  /////////////////////////////////////////////////////////////

  struct MarginReads {
    int im;
    int mm;
    int mtm;
  }

  function _reads(uint acc) internal view returns (MarginReads memory r) {
    r.im = manager.getMargin(acc, true);
    r.mm = manager.getMargin(acc, false);
    (, r.mtm) = manager.getMarginAndMarkToMarket(acc, false, 0);
  }

  /// @dev settles `acc` and asserts IM, MM and mark-to-market read the same after as before
  function _assertSettlingChangesNothing(uint acc, string memory why) internal {
    MarginReads memory before = _reads(acc);
    manager.settleAccount(acc);
    MarginReads memory afterwards = _reads(acc);
    assertEq(afterwards.im, before.im, string.concat(why, ": initial margin"));
    assertEq(afterwards.mm, before.mm, string.concat(why, ": maintenance margin"));
    assertEq(afterwards.mtm, before.mtm, string.concat(why, ": mark-to-market"));
  }

  function testInvariantGainPaidInCngn() public {
    _openAtMark(); // the pool holds 100,000 cNGN
    _mark(1010e18); // alice is due 10,000 cNGN
    _assertSettlingChangesNothing(aliceAcc, "gain paid in cNGN by the pool");
  }

  function testInvariantLossPaidInCash() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18); // bob holds no cNGN
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18); // bob owes 10,000 cNGN
    _assertSettlingChangesNothing(bobAcc, "loss paid in cash");
  }

  function testInvariantLossPaidFromHeldCngn() public {
    _openAtMark(); // bob holds 100,000 cNGN
    _mark(1010e18); // and owes 10,000
    _assertSettlingChangesNothing(bobAcc, "loss paid from held cNGN");
  }

  function testInvariantLossPaidPartlyInCngnPartlyInCash() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(bobAcc, 4_000e18); // bob holds 4,000 cNGN of the 10,000 he will owe
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);
    _assertSettlingChangesNothing(bobAcc, "loss paid 4,000 in cNGN and 6,000 in cash");
    assertEq(_cngn(bobAcc), 0, "his cNGN went first");
  }

  /// @dev Two series, both losing: the first spends the held cNGN, the second pays the rest of it and then cash, in the
  ///      order settlement takes them.
  function testInvariantLossesOnTwoSeriesSpendHeldCngnInSettlementOrder() public {
    uint96 subId2 = future.setContract(uint64(expiry + 30 days), uint64(lastTradeTime + 30 days), MARK);
    _fundCash(aliceAcc, 5_000e18);
    _fundCash(bobAcc, 5_000e18);
    _depositCngn(bobAcc, 15_000e18); // 15,000 cNGN against 20,000 owed across the two
    _depositCngn(pool, 100_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: subId2, amount: 1e18, assetData: bytes32(MARK)
      }),
      ""
    );
    _mark(1010e18);
    future.setMark(subId2, uint64(block.timestamp), 1010e18);
    _assertSettlingChangesNothing(bobAcc, "losses on two series");
    assertEq(_cngn(bobAcc), 0);
  }

  /// @dev The one case the view does not match exactly: the pool is short, so settlement pays the gain in cash, at par,
  ///      where the view counted it at the base factor. The view is lower, never higher, than after settlement.
  function testGainPaidInCashFromAnEmptyPoolIsCountedConservatively() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18); // the pool holds no cNGN
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);
    MarginReads memory before = _reads(aliceAcc);
    manager.settleAccount(aliceAcc);
    MarginReads memory afterwards = _reads(aliceAcc);
    assertEq(afterwards.mm - before.mm, 5e18, "10 USDC due: counted at 0.5 before, paid as cash at par");
    assertEq(afterwards.im - before.im, 5e18);
    assertEq(afterwards.mtm, before.mtm, "mark-to-market counts it at par either way");
  }

  ///////////////////////////////////////////////
  //  the pool: negative, never liquidatable   //
  ///////////////////////////////////////////////

  /// @dev An empty pool pays a winner settled before the loser in cash, and goes negative.
  function _drainPoolNegative() internal {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18); // no cNGN anywhere: the pool has none to pay in
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1050e18);
    manager.settleAccount(aliceAcc); // alice before bob: the pool pays 50 USDC it does not have
    assertEq(_cash(pool), -50e18, "the pool owes the cash until bob pays in");
  }

  function testANegativePoolReadsAsNeverLiquidatable() public {
    _drainPoolNegative();
    assertEq(manager.getMargin(pool, false), 0, "never below maintenance");
    assertEq(manager.getMargin(pool, true), 0);
    (int margin, int mtm) = manager.getMarginAndMarkToMarket(pool, false, 0);
    assertEq(margin, 0);
    assertEq(mtm, -50e18, "mark-to-market still reports the deficit");
  }

  function testANegativePoolStillTakesDepositsAndRefillsWhenLosersPay() public {
    _drainPoolNegative();
    _fundCash(pool, 10e18); // a treasury top-up into a negative pool
    assertEq(_cash(pool), -40e18);
    manager.settleAccount(bobAcc);
    assertEq(_cash(pool), 10e18, "bob's 50 repays the deficit");
  }

  ///////////////////////////////////////
  //  fills are bounded by the index band  //
  ///////////////////////////////////////

  function testAFillOutsideTheIndexBandIsRefused() public {
    _useIndex(); // index 1,000 cNGN per USDC, band 10%
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 1101e18);
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 899e18);
    _trade(bobAcc, aliceAcc, 1e18, 1100e18); // the band's edge
    assertEq(_position(aliceAcc), 1e18);
  }

  /// @dev The bound is the band a mark must sit in, so it narrows with it: 1% at expiry.
  function testTheFillBoundNarrowsWithTheBand() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    vm.warp(lastTradeTime - 1);
    uint band = future.markIndexBand(uint64(expiry));
    assertLt(band, 0.0103e18, "about 1% an hour before expiry: 1% + 9% x 1h / 14 days");
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 1015e18);
    _trade(bobAcc, aliceAcc, 1e18, 1009e18);
  }

  /// @dev Bounded by the index, not the last mark: a stale mark far from a moved index does not hold fills back.
  function testTheFillBoundFollowsTheIndexNotAStaleMark() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    uint movedSpot = uint(1e36) / 1150e18; // the index moves 15%, to 1,150; the mark is still 1,000
    spotFeed.setSpot(movedSpot, 1e18);
    _trade(bobAcc, aliceAcc, 1e18, 1150e18);
    assertEq(_position(aliceAcc), 1e18, "a fill at the moved market is taken");
  }

  /// @dev Transfers with no price move at the mark and are not bounded: liquidation, close-out.
  function testAPricelessTransferIsNotBounded() public {
    _useIndex();
    _openAtMark();
    uint farSpot = uint(1e36) / 1500e18; // the index 50% away from the mark
    spotFeed.setSpot(farSpot, 1e18);
    _trade(aliceAcc, bobAcc, 1e18, 0); // no price: moves at the mark
    assertEq(_position(aliceAcc), 0);
  }

  //////////////////////////////////////////////////////////
  //  settlement order: the view does not depend on it     //
  //////////////////////////////////////////////////////////

  /// @dev Two losing series, acquired in the reverse of subId order: held cNGN spent is min(owed, held) whichever the
  ///      series' order, so the view is exact.
  function testInvariantLossesOnTwoSeriesAcquiredOutOfOrder() public {
    uint96 subId2 = future.setContract(uint64(expiry + 30 days), uint64(lastTradeTime + 30 days), MARK);
    _fundCash(aliceAcc, 5_000e18);
    _fundCash(bobAcc, 5_000e18);
    _depositCngn(bobAcc, 15_000e18);
    _depositCngn(pool, 100_000e18);
    // the later series first
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: subId2, amount: 1e18, assetData: bytes32(MARK)
      }),
      ""
    );
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e18);
    future.setMark(subId2, uint64(block.timestamp), 1006e18); // owes 10,000 and 6,000
    _assertSettlingChangesNothing(bobAcc, "losses on two series, acquired out of order");
  }

  /// @dev A gain and a loss on two series, both orders: in settlement a gain taken first can fund the loss in cNGN; the
  ///      view never lets it. So the view is at most the margin after settlement, whichever order.
  function testAGainAndALossAreNeverOverstatedInEitherOrder() public {
    for (uint flip; flip < 2; ++flip) {
      setUp();
      uint96 subId2 = future.setContract(uint64(expiry + 30 days), uint64(lastTradeTime + 30 days), MARK);
      _fundCash(aliceAcc, 5_000e18);
      _fundCash(bobAcc, 5_000e18);
      _depositCngn(pool, 100_000e18); // bob holds no cNGN: his loss is cash unless his gain arrives first
      uint96 first = flip == 0 ? subId : subId2;
      uint96 second = flip == 0 ? subId2 : subId;
      // bob short `first`, long `second`
      subAccounts.submitTransfer(
        ISubAccounts.AssetTransfer({
          fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: first, amount: 1e18, assetData: bytes32(MARK)
        }),
        ""
      );
      subAccounts.submitTransfer(
        ISubAccounts.AssetTransfer({
          fromAcc: aliceAcc, toAcc: bobAcc, asset: future, subId: second, amount: 1e18, assetData: bytes32(MARK)
        }),
        ""
      );
      vm.warp(block.timestamp + 1 days);
      future.setMark(first, uint64(block.timestamp), 1010e18); // bob loses 10,000
      future.setMark(second, uint64(block.timestamp), 1006e18); // and gains 6,000
      MarginReads memory before = _reads(bobAcc);
      manager.settleAccount(bobAcc);
      MarginReads memory afterwards = _reads(bobAcc);
      assertLe(before.mm, afterwards.mm, "never above what settlement gives");
      assertLe(before.im, afterwards.im);
      assertEq(before.mtm, afterwards.mtm, "mark-to-market at par either way");
    }
  }
}
