// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../../src/SubAccounts.sol";
import "../../../../src/risk-managers/BasePortfolioViewer.sol";
import "../../../../src/risk-managers/DatedFutureManager.sol";
import "../../../../src/assets/WrappedERC20Asset.sol";
import "../../../../src/assets/DatedFutureAsset.sol";
import {IAsset} from "../../../../src/interfaces/IAsset.sol";
import {ICashAsset} from "../../../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../../../src/interfaces/IDutchAuction.sol";
import {IDatedFutureAsset} from "../../../../src/interfaces/IDatedFutureAsset.sol";
import {IERC20BasedAsset} from "../../../../src/interfaces/IERC20BasedAsset.sol";
import {ISpotFeed} from "../../../../src/interfaces/ISpotFeed.sol";

import "../../../shared/mocks/MockERC20.sol";
import "../../../shared/mocks/MockFeeds.sol";
import "../../../shared/mocks/MockCash.sol";
import "../../mocks/MockDutchAuction.sol";

/**
 * Prices are cNGN per USDC. The spot feed is USDC per cNGN. The numbers are chosen to be consistent and round:
 * mark 1000 cNGN/USDC, spot 0.001 USDC/cNGN, one contract = 1,000 USDC, so a 10 cNGN move in the mark is
 * 10,000 cNGN (10 USDC) of VM per contract.
 */
contract TestDatedFutureManager is Test {
  SubAccounts subAccounts;
  DatedFutureManager manager;
  BasePortfolioViewer viewer;
  MockDutchAuction auction;

  MockCash cash;
  MockERC20 usdc;
  MockERC20 cngn;
  WrappedERC20Asset cngnAsset;
  DatedFutureAsset future;
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
    viewer = new BasePortfolioViewer(subAccounts, cash);
    auction = new MockDutchAuction();
    cngnAsset = new WrappedERC20Asset(subAccounts, cngn);
    future = new DatedFutureAsset(subAccounts, CONTRACT_SIZE);
    spotFeed = new MockFeeds();
    spotFeed.setSpot(SPOT, 1e18);

    manager = new DatedFutureManager(
      subAccounts,
      ICashAsset(address(cash)),
      IDutchAuction(address(auction)),
      viewer,
      IDatedFutureAsset(address(future)),
      IAsset(address(cngnAsset)),
      ISpotFeed(address(spotFeed))
    );
    manager.setMarginParams(
      DatedFutureManager.MarginParams({mmReq: 0.1e18, imReq: 0.2e18, cngnMarginFactor: 0.5e18, cngnIMScale: 1e18})
    );
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
    future.setDailyMark(subId, uint64(block.timestamp), price);
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
    vm.expectRevert(DatedFutureManager.DFM_PortfolioBelowMargin.selector);
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

  function testCannotDrawCashBelowZero() public {
    _fundCash(aliceAcc, 100e18);
    vm.prank(alice);
    vm.expectRevert(DatedFutureManager.DFM_NoNegativeCash.selector);
    cash.withdraw(aliceAcc, 101e18, alice);
  }

  /// @dev The pool is owned by the manager, which grants no allowances, so a transfer cannot reach it. The one path
  ///      that could put a position there without an allowance is a liquidation bid naming it as the liquidator.
  function testPoolCannotBeTheLiquidator() public {
    vm.prank(address(auction));
    vm.expectRevert(DatedFutureManager.DFM_PoolCannotHoldFutures.selector);
    manager.executeBid(bobAcc, pool, 1e18, 0, 0);
  }

  function testRejectsOtherAssets() public {
    WrappedERC20Asset other = new WrappedERC20Asset(subAccounts, usdc);
    other.setWhitelistManager(address(manager), true);
    other.setTotalPositionCap(manager, 1e36);
    usdc.mint(address(this), 1e6);
    usdc.approve(address(other), 1e6);
    vm.expectRevert(DatedFutureManager.DFM_UnsupportedAsset.selector);
    other.deposit(aliceAcc, 1e6);
  }

  ///////////////////
  //     marks     //
  ///////////////////

  function testMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IDatedFutureAsset.DFA_MarkDeviationExceeded.selector);
    future.setDailyMark(subId, uint64(block.timestamp), 1051e18);
    future.setDailyMark(subId, uint64(block.timestamp), 1050e18);
  }

  function testStaleMarkIsRejected() public {
    future.setMarkBounds(0, 600);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IDatedFutureAsset.DFA_StaleMark.selector);
    future.setDailyMark(subId, uint64(block.timestamp - 601), 1001e18);
  }

  function testMarkCannotBeInTheFuture() public {
    vm.expectRevert(IDatedFutureAsset.DFA_InvalidMark.selector);
    future.setDailyMark(subId, uint64(block.timestamp + 1), 1001e18);
  }

  function testOnlyOwnerMarks() public {
    vm.warp(block.timestamp + 1 days);
    vm.prank(alice);
    vm.expectRevert();
    future.setDailyMark(subId, uint64(block.timestamp), 1001e18);
  }

  ///////////////////
  //    expiry     //
  ///////////////////

  function testTradingClosesAtLastTradeTime() public {
    _openAtMark();
    vm.warp(lastTradeTime);
    vm.expectRevert(IDatedFutureAsset.DFA_TradingClosed.selector);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
  }

  function testSettlementPriceOnlyAfterExpiry() public {
    vm.warp(expiry - 1);
    vm.expectRevert(IDatedFutureAsset.DFA_NotExpired.selector);
    future.setSettlementPrice(subId, 1001e18);
  }

  function testCloseOutBeforeSettlementReverts() public {
    _openAtMark();
    vm.warp(expiry);
    vm.expectRevert(DatedFutureManager.DFM_NotSettled.selector);
    manager.closeOutExpired(aliceAcc, subId);
  }

  function testCloseOutAfterSettlementRemovesPositionsAndPaysTheLastLeg() public {
    _openAtMark();
    _mark(1010e18);
    vm.warp(expiry);
    future.setSettlementPrice(subId, 1015e18); // last leg +5 on top of +10

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
    vm.warp(expiry);
    future.setSettlementPrice(subId, 1001e18);
    vm.expectRevert(IDatedFutureAsset.DFA_AlreadySettled.selector);
    future.setSettlementPrice(subId, 1002e18);
    vm.expectRevert(IDatedFutureAsset.DFA_AlreadySettled.selector);
    future.setDailyMark(subId, uint64(block.timestamp), 1002e18);
  }

  ///////////////////
  // index, fixing //
  ///////////////////

  uint constant WINDOW = 1 hours;
  uint constant GAP = 15 minutes;
  uint constant FALLBACK = 24 hours;

  /// @dev the index feed is USDC per cNGN; 0.001 is 1000 cNGN per USDC, the mark
  function _useIndex() internal {
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, WINDOW, GAP, FALLBACK);
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
    vm.expectRevert(IDatedFutureAsset.DFA_MarkOutsideIndexBand.selector);
    future.setDailyMark(subId, uint64(block.timestamp), 1101e18);
    future.setDailyMark(subId, uint64(block.timestamp), 1100e18); // exactly 10% over
  }

  function testIndexParamsAreValidated() public {
    vm.expectRevert(IDatedFutureAsset.DFA_InvalidIndexParams.selector);
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, WINDOW, WINDOW + 1, FALLBACK);
    vm.expectRevert(IDatedFutureAsset.DFA_InvalidIndexParams.selector);
    future.setIndexParams(ISpotFeed(address(0)), 0.1e18, WINDOW, GAP, FALLBACK);
  }

  function testFixingIsTheTimeWeightedIndex() public {
    _useIndex();
    _sampleWindow();
    future.fixSettlementFromIndex(subId);

    IDatedFutureAsset.FutureContract memory c = future.futureContracts(subId);
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
    vm.expectRevert(IDatedFutureAsset.DFA_NotExpired.selector);
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
    vm.expectRevert(IDatedFutureAsset.DFA_FixingIncomplete.selector);
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
    vm.expectRevert(IDatedFutureAsset.DFA_FixingIncomplete.selector);
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
    vm.expectRevert(IDatedFutureAsset.DFA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testSamplesOnlyInsideTheWindow() public {
    _useIndex();
    vm.warp(expiry - WINDOW - 1);
    vm.expectRevert(IDatedFutureAsset.DFA_OutsideFixingWindow.selector);
    future.recordFixingSample(subId);
    vm.warp(expiry + 1);
    vm.expectRevert(IDatedFutureAsset.DFA_OutsideFixingWindow.selector);
    future.recordFixingSample(subId);
  }

  function testParamsCannotMoveAWindowUnderWay() public {
    _useIndex();
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId);
    // widening the gap limit mid-window does not loosen this fixing
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, WINDOW, WINDOW, FALLBACK);
    vm.warp(expiry);
    vm.expectRevert(IDatedFutureAsset.DFA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testOwnerFallbackOnlyAfterTheDelayAndOnlyWithoutAFixing() public {
    _useIndex();
    vm.warp(expiry);
    vm.expectRevert(IDatedFutureAsset.DFA_NotExpired.selector);
    future.setSettlementPrice(subId, 1001e18);

    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1001e18); // nothing was sampled
    assertEq(future.futureContracts(subId).markPrice, 1001e18);
  }

  function testOwnerCannotOverrideACompleteFixing() public {
    _useIndex();
    _sampleWindow();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IDatedFutureAsset.DFA_FixingAvailable.selector);
    future.setSettlementPrice(subId, 1001e18);
  }

  ///////////////////
  //  liquidation  //
  ///////////////////

  function testBidSettlesVMBeforeMovingTheAccount() public {
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
}
