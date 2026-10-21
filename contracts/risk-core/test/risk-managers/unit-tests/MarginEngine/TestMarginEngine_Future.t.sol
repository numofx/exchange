// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

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
 * The v2 engine's futures suite: FutureAsset in American terms (cNGN-<expiry>), under MarginEngine v2. The v1 suite,
 * against the deployed cNGN-per-USDC contracts, is TestMarginEngineV1_Future.
 *
 * Prices are USDC per cNGN, and so is the spot feed, which the asset reads as is. The numbers mirror v1's so the two
 * suites read side by side: mark and spot 0.001 USDC per cNGN, written 1000e12, one contract = 1,000,000 cNGN, so a
 * contract is 1,000 USDC of notional at the mark and a 10e12 move in the mark is 10 USDC of VM per contract. Unlike
 * v1, VM is cash, notional moves with the mark, and VM is linear in the price.
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

  uint constant CONTRACT_SIZE = 1_000_000e18;
  uint constant MARK = 1000e12;
  uint constant SPOT = 1000e12;

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

  /// @dev the engine's per-market settings: cNGN at a 0.5 factor, no extra IM haircut
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

  /// @dev `seller` sells `amount` contracts to `buyer` at `price`, carried in assetData as the trade module does.
  function _trade(uint seller, uint buyer, int amount, uint price) internal {
    _tradeSeries(seller, buyer, subId, amount, price);
  }

  function _tradeSeries(uint seller, uint buyer, uint96 series, int amount, uint price) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: future, subId: series, amount: amount, assetData: bytes32(price)
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

  /// @dev both traders funded well above IM, one contract open at the mark. The pool holds nothing: v2 needs no reserve.
  function _openAtMark() internal {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _depositCngn(aliceAcc, 100_000e18);
    _depositCngn(bobAcc, 100_000e18);
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
  }

  /// @dev American terms: the price is USDC per cNGN, so it rises as cNGN strengthens, and the long gains.
  function testMarkUpPaysTheLongInCash() public {
    _openAtMark();
    _mark(1010e12); // cNGN +1%: 10 USDC per contract

    assertEq(future.getPendingVM(aliceAcc, subId), 10e18);
    assertEq(future.getPendingVM(bobAcc, subId), -10e18);

    manager.settleAccount(bobAcc);
    manager.settleAccount(aliceAcc);

    assertEq(_cash(aliceAcc), 1_010e18);
    assertEq(_cash(bobAcc), 990e18);
    assertEq(_cash(pool), 0, "zero-sum: the pool is flat once both are settled");
    // nothing moved as cNGN
    assertEq(_cngn(aliceAcc), 100_000e18);
    assertEq(_cngn(bobAcc), 100_000e18);
    assertEq(_cngn(pool), 0);
  }

  function testMarkDownPaysTheShortInCash() public {
    _openAtMark();
    _mark(990e12);

    manager.settleAccount(aliceAcc);
    manager.settleAccount(bobAcc);

    assertEq(_cash(aliceAcc), 990e18);
    assertEq(_cash(bobAcc), 1_010e18);
    assertEq(_cash(pool), 0);
  }

  /// @dev Linear, where v1 was inverse: the same move either way is the same USDC, and VM is Δprice x size exactly.
  function testVMIsLinearInThePrice() public {
    _openAtMark();
    _mark(1100e12);
    assertEq(future.getPendingVM(aliceAcc, subId), 100e18, "+10%: +100 USDC");
    _mark(900e12);
    assertEq(future.getPendingVM(aliceAcc, subId), -100e18, "-10% from the start: -100 USDC, symmetric");
    _mark(1000e12);
    assertEq(future.getPendingVM(aliceAcc, subId), 0, "back at the entry: nothing");
  }

  function testWinnerSettledFirstIsFrontedByThePool() public {
    _openAtMark();
    _mark(1010e12);

    manager.settleAccount(aliceAcc);
    assertEq(_cash(aliceAcc), 1_010e18);
    assertEq(_cash(pool), -10e18, "the pool fronts the winner in cash");

    manager.settleAccount(bobAcc);
    assertEq(_cash(pool), 0, "the loser repays it");
  }

  function testInsolventLoserStillSettles() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 300e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    for (uint i; i < 10; ++i) {
      _mark(MARK + (i + 1) * 50e12); // 5% steps up to 1500e12: bob owes 500 USDC
    }

    manager.settleAccount(bobAcc);
    assertEq(_cash(bobAcc), 300e18 - 500e18, "cash goes negative instead of reverting");
    assertLt(manager.getMargin(bobAcc, false), 0);
  }

  /// @dev VM moves as cash whatever the account holds: a loser's cNGN is collateral, never spent on VM.
  function testALosersCngnIsNotSpent() public {
    _openAtMark();
    _mark(1010e12);
    manager.settleAccount(bobAcc);
    assertEq(_cngn(bobAcc), 100_000e18, "cNGN untouched");
    assertEq(_cash(bobAcc), 990e18, "the loss came out of cash");
  }

  ///////////////////
  //  fill prices  //
  ///////////////////

  function testFillAboveTheMarkChargesTheBuyerImmediately() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);

    _trade(bobAcc, aliceAcc, 1e18, 1010e12); // bought 10e12 above the mark

    assertEq(_cash(aliceAcc), 990e18);
    assertEq(_cash(bobAcc), 1_010e18);
    assertEq(_cash(pool), 0);

    // marked to the fill price, the trade is flat again
    _mark(1010e12);
    manager.settleAccount(aliceAcc);
    manager.settleAccount(bobAcc);
    assertEq(_cash(aliceAcc), 1_000e18);
    assertEq(_cash(bobAcc), 1_000e18);
  }

  function testReducingAtAFillRealisesOnlyTheClosedPart() public {
    _openAtMark();
    _trade(bobAcc, aliceAcc, 1e18, MARK); // alice long 2, bob short 2, at the mark

    // alice sells 1 back to bob at 1020e12, mark still 1000e12: she realises +20 USDC on the closed contract
    _trade(aliceAcc, bobAcc, 1e18, 1020e12);
    assertEq(_cash(aliceAcc), 1_020e18);
    assertEq(_cash(bobAcc), 980e18);
    assertEq(_position(aliceAcc), 1e18);

    // the remaining contract still runs from the mark
    _mark(1010e12);
    assertEq(future.getPendingVM(aliceAcc, subId), 10e18);
  }

  function testClosingFullyAtAFillPaysOut() public {
    _openAtMark();
    _trade(aliceAcc, bobAcc, 1e18, 1020e12);
    assertEq(_position(aliceAcc), 0);
    assertEq(_position(bobAcc), 0);
    assertEq(_cash(aliceAcc), 1_020e18);
    assertEq(_cash(bobAcc), 980e18);
    assertEq(future.accountCashToSettle(aliceAcc, subId), 0, "nothing stranded");
    assertEq(future.accountCashToSettle(bobAcc, subId), 0, "nothing stranded");
  }

  function testTransferWithoutAPriceMovesAtTheMark() public {
    _openAtMark();
    _mark(1010e12);
    uint charlieAcc = subAccounts.createAccountWithApproval(address(0xcc), address(this), manager);
    _fundCash(charlieAcc, 1_000e18);

    // alice hands her contract to charlie with no price: alice keeps the VM to date, charlie starts at the mark
    _trade(aliceAcc, charlieAcc, 1e18, 0);
    assertEq(_cash(aliceAcc), 1_010e18);
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

  /// @dev A cNGN contract's USDC notional moves with the price, as a perp's does; v1's was fixed in USDC.
  function testNotionalMovesWithTheMark() public {
    _openAtMark();
    int imAtTheMark = manager.getMargin(aliceAcc, true);
    _mark(1100e12); // notional 1,100; alice is due 100
    assertEq(manager.getMargin(aliceAcc, true), imAtTheMark + 100e18 - 20e18, "IM on 1,100 not 1,000");
  }

  function testPendingLossCountsAtPar() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e12);

    // bob owes 10 USDC he has not paid, at par, against MM on 1,010 of notional
    assertEq(manager.getMargin(bobAcc, false), 1_000e18 - 10e18 - 101e18);
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
    _trade(bobAcc, aliceAcc, 2e18, MARK); // bob short 2: IM 400
    _mark(1050e12); // bob owes 100: 300 against IM 420 and MM 210 on 2,100 of notional

    assertLt(manager.getMargin(bobAcc, true), 0);
    assertGt(manager.getMargin(bobAcc, false), 0);

    // bob may still buy one back
    _trade(aliceAcc, bobAcc, 1e18, 1050e12);
    assertEq(_position(bobAcc), -1e18);
  }

  /// @dev Between MM and IM after the reduction: only a maintenance check lets it through.
  function testReductionBelowInitialIsAllowedAtMaintenance() public {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 400e18);
    _trade(bobAcc, aliceAcc, 2e18, MARK); // bob short 2
    _mark(1120e12); // bob owes 240: 160 left against MM 224 on 2,240, below maintenance

    _trade(aliceAcc, bobAcc, 1e18, 1120e12); // bob buys one back
    assertEq(_position(bobAcc), -1e18);
    assertEq(manager.getMargin(bobAcc, false), 160e18 - 112e18, "above maintenance once reduced");
    assertEq(manager.getMargin(bobAcc, true), 160e18 - 224e18, "still below initial: an IM check would refuse it");
  }

  function testCannotDrawCashBelowZero() public {
    _fundCash(aliceAcc, 100e18);
    vm.prank(alice);
    vm.expectRevert(IMarginEngine.SRM_NoNegativeCash.selector);
    cash.withdraw(aliceAcc, 101e18, alice);
  }

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
    future.setMark(subId, uint64(block.timestamp), 1051e12);
    future.setMark(subId, uint64(block.timestamp), 1050e12);
  }

  function testStaleMarkIsRejected() public {
    future.setMarkBounds(0, 600);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAsset.FA_StaleMark.selector);
    future.setMark(subId, uint64(block.timestamp - 601), 1001e12);
  }

  function testMarkCannotBeInTheFuture() public {
    vm.expectRevert(IFutureAsset.FA_InvalidMark.selector);
    future.setMark(subId, uint64(block.timestamp + 1), 1001e12);
  }

  function testOnlyOwnerMarks() public {
    vm.warp(block.timestamp + 1 days);
    vm.prank(alice);
    vm.expectRevert();
    future.setMark(subId, uint64(block.timestamp), 1001e12);
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
    future.setSettlementPrice(subId, 1001e12);
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
    _mark(1010e12); // reads the index (1000e12) as the fallback's reference
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1015e12); // last leg +5 on top of +10, 1.5% from the reference

    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);

    assertEq(_position(aliceAcc), 0);
    assertEq(_position(bobAcc), 0);
    assertEq(_cash(aliceAcc), 1_015e18);
    assertEq(_cash(bobAcc), 985e18);
    assertEq(_cash(pool), 0);
    assertEq(future.totalPosition(manager), 0, "open interest is zero");

    // once closed, the accounts are cash and cNGN only, and free to withdraw
    vm.prank(alice);
    cash.withdraw(aliceAcc, 1_015e18, alice);
    assertEq(_cash(aliceAcc), 0);
  }

  function testNoMarksAfterSettlement() public {
    _useIndex();
    _mark(1001e12);
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1001e12);
    vm.expectRevert(IFutureAsset.FA_AlreadySettled.selector);
    future.setSettlementPrice(subId, 1002e12);
    vm.expectRevert(IFutureAsset.FA_AlreadySettled.selector);
    future.setMark(subId, uint64(block.timestamp), 1002e12);
  }

  ///////////////////
  // index, fixing //
  ///////////////////

  uint constant WINDOW = 1 hours;
  uint constant GAP = 15 minutes;
  uint constant FALLBACK = 24 hours;
  uint constant NARROWING = 14 days;

  /// @dev the index feed is USDC per cNGN, the contract's own units: 0.001 is the mark, read as is
  function _useIndex() internal {
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, NARROWING, WINDOW, GAP, FALLBACK);
  }

  /// @dev sample every 15 minutes across the window: 1000e12 for the first half, 800e12 (cNGN 20% weaker) the second
  function _sampleWindow() internal {
    uint start = expiry - WINDOW;
    for (uint i; i < 4; ++i) {
      vm.warp(start + i * GAP);
      spotFeed.setSpot(i < 2 ? SPOT : 800e12, 1e18);
      future.recordFixingSample(subId);
    }
    vm.warp(expiry);
  }

  /// @dev v2 reads the index as the feed gives it; v1 stored 1e36 / spot.
  function testTheIndexIsTheFeedAsIs() public {
    _useIndex();
    _mark(1001e12);
    assertEq(future.lastIndexPrice(), SPOT, "USDC per cNGN, not inverted");
  }

  function testMarkMustSitInsideTheIndexBand() public {
    _useIndex();
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1101e12);
    future.setMark(subId, uint64(block.timestamp), 1100e12); // exactly 10% over
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
    assertEq(c.markPrice, 900e12, "half the window at 1000e12, half at 800e12");
  }

  function testFixingPaysTheLastLegAndClosesOut() public {
    _openAtMark();
    _useIndex();
    _sampleWindow();
    future.fixSettlementFromIndex(subId);

    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);
    assertEq(_cash(aliceAcc), 900e18, "cNGN fell 10%: the long loses 100 USDC");
    assertEq(_cash(bobAcc), 1_100e18);
    assertEq(_position(aliceAcc), 0);
  }

  function testFixingIsNotHeldToTheMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    _useIndex();
    _sampleWindow(); // 10% from the last mark
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
      spotFeed.setSpot(i == 0 ? SPOT : 800e12, 1e18);
      future.recordFixingSample(subId);
    }
    vm.warp(expiry);
    future.fixSettlementFromIndex(subId);
    // 1000e12 for 5 minutes, 800e12 for 55: a per-sample mean would be 840e12
    assertEq(future.futureContracts(subId).markPrice, uint(1000e12 * 300 + 800e12 * 3300) / 3600);
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
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, NARROWING, WINDOW, WINDOW, FALLBACK);
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testOwnerFallbackOnlyAfterTheDelayAndOnlyWithoutAFixing() public {
    _useIndex();
    _mark(1001e12); // the fallback needs a reference: this mark reads the index
    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_NotExpired.selector);
    future.setSettlementPrice(subId, 1001e12);

    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1001e12);
    assertEq(future.futureContracts(subId).markPrice, 1001e12);
  }

  /// @dev two samples, then the index goes stale: the reference is their TWAP, the last held for one gap limit
  function _sampleThenGoStale() internal {
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId); // 1000e12
    vm.warp(start + GAP);
    spotFeed.setSpot(800e12, 1e18);
    future.recordFixingSample(subId); // 800e12
  }

  function testFallbackInsideTheBandOfTheSampleTwap() public {
    _useIndex();
    _sampleThenGoStale();
    vm.warp(expiry + FALLBACK);
    assertEq(future.fallbackReference(subId), 900e12, "1000e12 for 15 minutes, 800e12 for its 15-minute limit");
    future.setSettlementPrice(subId, 918e12); // exactly 2% over: the edge is inside
    assertEq(future.futureContracts(subId).markPrice, 918e12);
  }

  function testFallbackOutsideTheBandOfTheSampleTwapIsRefused() public {
    _useIndex();
    _sampleThenGoStale();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 918e12 + 1);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 882e12 - 1);
  }

  function testFallbackWithoutSamplesIsBoundedByTheLastIndexRead() public {
    _useIndex();
    _mark(1001e12); // reads 1000e12
    spotFeed.setSpot(800e12, 1e18); // the live index moves afterwards: the last READ one is the reference
    vm.warp(expiry + FALLBACK);
    assertEq(future.fallbackReference(subId), 1000e12);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    future.setSettlementPrice(subId, 1021e12);
    future.setSettlementPrice(subId, 1020e12);
    assertTrue(future.futureContracts(subId).settled);
  }

  function testFallbackWithNoReferenceIsRefused() public {
    _useIndex();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_NoSettlementReference.selector);
    future.setSettlementPrice(subId, 1000e12);
  }

  function testFallbackIsNotHeldToTheMarkDeviationBound() public {
    future.setMarkBounds(0.05e18, 0);
    _useIndex();
    _mark(1050e12);
    _mark(1100e12); // both inside the 10% index band; the last index read is 1000e12
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, 1000e12); // 9% from the last mark, at the reference
    assertTrue(future.futureContracts(subId).settled);
  }

  function testOwnerCannotOverrideACompleteFixing() public {
    _useIndex();
    _sampleWindow();
    vm.warp(expiry + FALLBACK);
    vm.expectRevert(IFutureAsset.FA_FixingAvailable.selector);
    future.setSettlementPrice(subId, 1001e12);
  }

  /////////////////////
  // expiry, no feed //
  /////////////////////

  /// @dev alice long 1, bob short 1, cash only; marked 1010e12, then the feed dies and the fallback settles at `price`.
  function _settleWithADeadFeed(uint price) internal {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e12);
    vm.mockCallRevert(address(spotFeed), abi.encodeWithSelector(ISpotFeed.getSpot.selector), "stale");
    vm.warp(expiry + FALLBACK);
    future.setSettlementPrice(subId, price);
  }

  /// @dev VM is USDC, so close-out converts nothing and reads no feed: exact, and the pool ends flat.
  function testCloseOutReadsNoFeedAndIsExact() public {
    _settleWithADeadFeed(1015e12);
    manager.closeOutExpired(bobAcc, subId);
    manager.closeOutExpired(aliceAcc, subId);
    assertEq(_position(bobAcc), 0);
    assertEq(_position(aliceAcc), 0);
    assertEq(_cash(bobAcc), 985e18);
    assertEq(_cash(aliceAcc), 1_015e18);
    assertEq(_cash(pool), 0, "nothing converted, nothing rounded");
    assertEq(future.totalPosition(manager), 0, "no open interest left");
  }

  /// @dev v1 needed the feed to convert a cNGN debt before expiry; v2 settles cash with the feed down.
  function testPreExpirySettlementNeedsNoFeed() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1010e12);
    vm.mockCallRevert(address(spotFeed), abi.encodeWithSelector(ISpotFeed.getSpot.selector), "stale");
    manager.settleAccount(bobAcc);
    assertEq(_cash(bobAcc), 990e18);
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
    _markAt(expiry - NARROWING, 1100e12); // exactly at the start of narrowing: still 10%
  }

  function testBandNarrowsLinearlyToOnePercentAtExpiry() public {
    _useIndex();
    vm.warp(expiry - NARROWING / 2);
    assertEq(future.markIndexBand(uint64(expiry)), 0.055e18, "halfway: 1% + 9% / 2");
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1056e12);
    future.setMark(subId, uint64(block.timestamp), 1055e12);

    vm.warp(expiry);
    assertEq(future.markIndexBand(uint64(expiry)), 0.01e18, "1% at expiry");
  }

  function testBandNearExpiryRefusesAMarkTheFullBandWouldTake() public {
    _useIndex();
    _markAt(expiry - 1 hours, 1010e12); // band ~1.03%: 1% inside it
    vm.warp(expiry - 30 minutes);
    vm.expectRevert(IFutureAsset.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1050e12); // inside 10%, outside ~1%
  }

  function testNoNarrowingWhenThePeriodIsZero() public {
    future.setIndexParams(ISpotFeed(address(spotFeed)), 0.1e18, 0.01e18, 0, WINDOW, GAP, FALLBACK);
    vm.warp(expiry - 1);
    assertEq(future.markIndexBand(uint64(expiry)), 0.1e18);
  }

  /// @dev the forward, USDC per cNGN: 1% over the index, and the mark as is
  uint constant FORWARD = 1010e12;

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

    assertEq(future.futureContracts(subId).markPrice, FORWARD, "the forward itself, not its inverse");
    assertEq(future.futureContracts(subId).lastMarkTime, block.timestamp);
    assertEq(future.getPendingVM(aliceAcc, subId), 10e18, "VM accrues from it");
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
    spotFeed.setForwardPrice(expiry, 1064e12, 1e18); // a 6.4% move
    vm.expectRevert(IFutureAsset.FA_MarkDeviationExceeded.selector);
    future.pullMark(subId);

    future.setMarkBounds(0.2e18, 0);
    spotFeed.setForwardPrice(expiry, 1124e12, 1e18); // 12.4% from the index
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
    future.setMark(subId, uint64(block.timestamp), 1010e12);
    assertEq(future.futureContracts(subId).markPrice, 1010e12);
  }

  /// @dev The SRM settles a dated future by calling settleAccount(uint,uint). FutureAsset has no such function, so an
  ///      SRM that whitelisted it by mistake would revert, not mis-credit.
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
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1050e12);
    _mark(1100e12);
    _mark(1150e12);
    _mark(1200e12); // bob owes 200: 300 - 200 against MM 120 on 1,200 of notional

    assertLt(manager.getMargin(bobAcc, false), 0);

    uint liquidatorAcc = subAccounts.createAccountWithApproval(address(0x11), address(this), manager);
    _fundCash(liquidatorAcc, 10_000e18);

    manager.settlePerpsWithIndex(bobAcc);
    vm.prank(address(auction));
    manager.executeBid(bobAcc, liquidatorAcc, 1e18, 0, 0);

    assertEq(_position(liquidatorAcc), -1e18, "the liquidator takes the short");
    assertEq(_position(bobAcc), 0);
    assertEq(_cash(liquidatorAcc), 10_000e18 + 300e18 - 200e18, "and bob's cash, net of the VM bob paid first");
    assertEq(future.getPendingVM(liquidatorAcc, subId), 0, "the position arrives at the mark");
  }

  function testOnlyTheAuctionBids() public {
    vm.expectRevert();
    manager.executeBid(bobAcc, aliceAcc, 1e18, 0, 0);
  }

  ////////////////////////////////////////////
  //  the engine: what the fork itself adds  //
  ////////////////////////////////////////////

  /// @dev Unsettled VM is cash owed, so it counts at par, as a perp's unrealised PnL does: margin reads the same
  ///      before and after settlement, and so does mark-to-market.
  function testUnsettledGainCountsAtParAndSettlingChangesNothing() public {
    _openAtMark();
    _mark(1010e12); // alice is due 10 USDC

    // 1,000 cash + 100,000 cNGN at 0.5 (50) + the 10 due, less 10% of 1,010 notional
    int before = manager.getMargin(aliceAcc, false);
    assertEq(before, 1_000e18 + 50e18 + 10e18 - 101e18);
    (, int mtm) = manager.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertEq(mtm, 1_000e18 + 100e18 + 10e18, "mark-to-market counts the VM due at par");

    manager.settleAccount(aliceAcc);
    assertEq(_cash(aliceAcc), 1_010e18, "paid in cash");
    assertEq(manager.getMargin(aliceAcc, false), before, "settled or not, margin reads the same");
  }

  /// @dev spot cNGN, a perp and a future in one account, one margin, gross.
  function testSpotPerpAndFutureAreMarginedInOneAccount() public {
    MockPerp perp = new MockPerp(subAccounts);
    perp.setMockPerpPrice(SPOT, 1e18);
    perp.setTotalPositionCap(manager, 1e36);
    manager.whitelistAsset(perp, marketId, IMarginEngine.AssetType.Perpetual);
    manager.setPerpMarginRequirements(marketId, 0.1e18, 0.2e18);

    _openAtMark(); // alice: 1,000 cash, 100,000 cNGN, long 1 future
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: perp, subId: 0, amount: 1_000_000e18, assetData: bytes32(0)
      }),
      ""
    );
    _mark(1010e12); // the future is up 10 USDC for alice, unsettled
    perp.mockAccountPnlAndFunding(aliceAcc, 0, -20e18); // the perp is down 20 USDC, unrealised

    // MM: 1,000 cash + 50 (cNGN at 0.5) + 10 (future VM due) - 20 (perp PnL) - 100 (perp MM) - 101 (future MM on 1,010)
    assertEq(manager.getMargin(aliceAcc, false), 1_000e18 + 50e18 + 10e18 - 20e18 - 100e18 - 101e18);
  }

  function testDepegPenaltyOnFuturesNotional() public {
    _openAtMark();
    int imPegged = manager.getMargin(aliceAcc, true);
    int mmPegged = manager.getMargin(aliceAcc, false);

    manager.setDepegParameters(IMarginEngine.DepegParams({threshold: 0.99e18, depegFactor: 2e18}));
    stableFeed.setSpot(0.98e18, 1e18); // (0.99 - 0.98) x 2 = 2% of notional
    assertEq(manager.getMargin(aliceAcc, true), imPegged - 20e18, "2% of the 1,000 USDC notional");
    assertEq(manager.getMargin(aliceAcc, false), mmPegged, "maintenance has no depeg penalty");
  }

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
    _depositCngn(pool, 1_000e18); // sent to the pool by mistake
    vm.prank(alice);
    vm.expectRevert();
    manager.withdrawFromPool(IERC20BasedAsset(address(cngnAsset)), 1e6, alice);

    manager.withdrawFromPool(IERC20BasedAsset(address(cngnAsset)), 1e6, address(0x7ea5));
    assertEq(cngn.balanceOf(address(0x7ea5)), 1e6);
  }

  function testAnyoneMaySettle() public {
    _openAtMark();
    _mark(1010e12);
    vm.prank(address(0xbeef));
    manager.settleAccount(aliceAcc);
    assertEq(_cash(aliceAcc), 1_010e18);
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

  function testInvariantGain() public {
    _openAtMark();
    _mark(1010e12);
    _assertSettlingChangesNothing(aliceAcc, "gain");
  }

  function testInvariantLoss() public {
    _openAtMark();
    _mark(1010e12);
    _assertSettlingChangesNothing(bobAcc, "loss");
  }

  function testInvariantGainFromAnEmptyPool() public {
    _openAtMark(); // the pool holds nothing: it fronts the gain and goes negative
    _mark(1010e12);
    _assertSettlingChangesNothing(aliceAcc, "gain fronted by an empty pool");
  }

  function testInvariantLossesOnTwoSeries() public {
    uint96 subId2 = future.setContract(uint64(expiry + 30 days), uint64(lastTradeTime + 30 days), MARK);
    _fundCash(aliceAcc, 5_000e18);
    _fundCash(bobAcc, 5_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _tradeSeries(bobAcc, aliceAcc, subId2, 1e18, MARK);
    _mark(1010e12);
    future.setMark(subId2, uint64(block.timestamp), 1006e12);
    _assertSettlingChangesNothing(bobAcc, "losses on two series");
  }

  /// @dev A gain and a loss on two series, both orders: cash at par, so the view is exact whichever settles first
  ///      (in v1 it was only ever conservative).
  function testInvariantGainAndLossInEitherOrder() public {
    for (uint flip; flip < 2; ++flip) {
      setUp();
      uint96 subId2 = future.setContract(uint64(expiry + 30 days), uint64(lastTradeTime + 30 days), MARK);
      _fundCash(aliceAcc, 5_000e18);
      _fundCash(bobAcc, 5_000e18);
      uint96 first = flip == 0 ? subId : subId2;
      uint96 second = flip == 0 ? subId2 : subId;
      _tradeSeries(bobAcc, aliceAcc, first, 1e18, MARK); // bob short `first`
      _tradeSeries(aliceAcc, bobAcc, second, 1e18, MARK); // and long `second`
      vm.warp(block.timestamp + 1 days);
      future.setMark(first, uint64(block.timestamp), 1010e12); // bob loses 10
      future.setMark(second, uint64(block.timestamp), 1006e12); // and gains 6
      _assertSettlingChangesNothing(bobAcc, "a gain and a loss");
    }
  }

  ///////////////////////////////////////////////
  //  the pool: negative, never liquidatable   //
  ///////////////////////////////////////////////

  /// @dev The pool pays a winner settled before the loser, and goes negative.
  function _drainPoolNegative() internal {
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    _trade(bobAcc, aliceAcc, 1e18, MARK);
    _mark(1050e12);
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
    _fundCash(pool, 10e18);
    assertEq(_cash(pool), -40e18);
    manager.settleAccount(bobAcc);
    assertEq(_cash(pool), 10e18, "bob's 50 repays the deficit");
  }

  ///////////////////////////////////////////
  //  fills are bounded by the index band  //
  ///////////////////////////////////////////

  function testAFillOutsideTheIndexBandIsRefused() public {
    _useIndex(); // index 1000e12, band 10%
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 1101e12);
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 899e12);
    _trade(bobAcc, aliceAcc, 1e18, 1100e12); // the band's edge
    assertEq(_position(aliceAcc), 1e18);
  }

  function testTheFillBoundNarrowsWithTheBand() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    vm.warp(lastTradeTime - 1);
    uint band = future.markIndexBand(uint64(expiry));
    assertLt(band, 0.0103e18, "about 1% an hour before expiry: 1% + 9% x 1h / 14 days");
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, 1015e12);
    _trade(bobAcc, aliceAcc, 1e18, 1009e12);
  }

  function testTheFillBoundFollowsTheIndexNotAStaleMark() public {
    _useIndex();
    _fundCash(aliceAcc, 1_000e18);
    _fundCash(bobAcc, 1_000e18);
    spotFeed.setSpot(1150e12, 1e18); // the index moves 15%; the mark is still 1000e12
    _trade(bobAcc, aliceAcc, 1e18, 1150e12);
    assertEq(_position(aliceAcc), 1e18, "a fill at the moved market is taken");
  }

  function testAPricelessTransferIsNotBounded() public {
    _useIndex();
    _openAtMark();
    spotFeed.setSpot(1500e12, 1e18); // the index 50% away from the mark
    _trade(aliceAcc, bobAcc, 1e18, 0); // no price: moves at the mark
    assertEq(_position(aliceAcc), 0);
  }
}
