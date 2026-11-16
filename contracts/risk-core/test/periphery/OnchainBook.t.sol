// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/SubAccounts.sol";
import "../../src/risk-managers/MarginEnginePortfolioViewer.sol";
import "../../src/risk-managers/MarginEngine.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IVolFeed} from "../../src/interfaces/IVolFeed.sol";
import {FutureAsset} from "../../src/assets/FutureAsset.sol";
import {ICashAsset} from "../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../src/interfaces/IDutchAuction.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../src/interfaces/IForwardFeed.sol";
import {StreamsIndexAdapter} from "../../src/feeds/StreamsIndexAdapter.sol";
import {EurcIndexFeed} from "../../src/feeds/EurcIndexFeed.sol";
import {OnchainBook, IOnchainBookManager} from "../../src/periphery/OnchainBook.sol";

import "../shared/mocks/MockERC20.sol";
import "../shared/mocks/MockFeeds.sol";
import "../shared/mocks/MockCash.sol";
import "../risk-managers/mocks/MockDutchAuction.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {MockStreamsVerifier} from "../feed/unit-tests/StreamsIndexAdapter.t.sol";

/// @dev Looks like the index adapter to the book, and re-enters it from acceptData with whatever call it was given.
contract ReentrantAdapter {
  StreamsIndexAdapter public immutable real;
  address public immutable book;
  bytes public reentry;

  constructor(StreamsIndexAdapter real_, address book_) {
    real = real_;
    book = book_;
  }

  function setReentry(bytes calldata data) external {
    reentry = data;
  }

  function baseFeedId() external view returns (bytes32) {
    return real.baseFeedId();
  }

  function quoteFeedId() external view returns (bytes32) {
    return real.quoteFeedId();
  }

  function latest(bytes32 feedId) external view returns (uint, uint64) {
    return real.latest(feedId);
  }

  function acceptData(bytes calldata) external {
    (bool ok, bytes memory ret) = book.call(reentry);
    if (!ok) {
      assembly {
        revert(add(ret, 32), mload(ret))
      }
    }
  }
}

/// @dev Stands in for SubAccounts.submitTransfers: uses up all the gas it is given.
contract GasBurner {
  uint public sink;

  function submitTransfers(ISubAccounts.AssetTransfer[] calldata, bytes calldata) external returns (uint) {
    while (true) {
      sink += 1;
    }
    return 0;
  }
}

/// @dev A manager a maker might move its account to: any call into it reverts.
contract RevertingManager {
  fallback() external {
    revert("called a maker-chosen manager");
  }
}

/**
 * OnchainBook (docs/eurc-usdc-futures-spec.md, Part B) against the real SubAccounts, MarginEngine v2, FutureAsset v3,
 * StreamsIndexAdapter and EurcIndexFeed; only the Data Streams verifier, the auction and cash are mocks.
 *
 * Index 1.10 USDC per EURC, one contract 1,000 EURC, one lot 1 EURC (1e15), one tick 0.000001.
 */
abstract contract OnchainBookBase is Test {
  bytes32 constant EURC = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 constant USDC = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;

  uint constant PRICE = 1.1e18;
  uint constant TICK = 1e12;
  uint constant LOT = 1e15;
  uint constant FEE_RATE = 0.0005e18;
  uint constant HALF_SPREAD = 100; // 0.0001
  uint constant GAS_FLOOR = 700_000;

  SubAccounts subAccounts;
  MarginEngine engine;
  MarginEnginePortfolioViewer viewer;
  MockDutchAuction auction;
  MockCash cash;
  MockERC20 usdc;
  FutureAsset future;
  MockFeeds forwardFeed;
  StreamsIndexAdapter adapter;
  EurcIndexFeed index;
  MockStreamsVerifier verifier;
  OnchainBook book;

  uint96 subId;
  uint expiry;
  uint mkt;
  uint engineMarket;

  address alice = address(0xa11ce); // maker
  address carol = address(0xca401); // maker
  address bob = address(0xb0b); // taker
  uint aliceAcc;
  uint carolAcc;
  uint bobAcc;
  uint feeAcc;

  function setUp() public virtual {
    vm.warp(1_794_702_400);
    subAccounts = new SubAccounts("Accounts", "ACC");
    usdc = new MockERC20("USDC", "USDC");
    usdc.setDecimals(6);
    cash = new MockCash(usdc, subAccounts);
    viewer = new MarginEnginePortfolioViewer(subAccounts, cash);
    auction = new MockDutchAuction();

    verifier = new MockStreamsVerifier(new MockERC20("LINK", "LINK"));
    adapter = new StreamsIndexAdapter(verifier, address(0), EURC, USDC);
    index = new EurcIndexFeed(adapter, 60);
    _postIndex(PRICE);

    forwardFeed = new MockFeeds();
    future = new FutureAsset(subAccounts, 1_000e18, index, 1 days);
    future.setIndexParams(0.03e18, 0.01e18, 7 days, 30 minutes, 2 minutes, 1 hours);
    future.setForwardFeed(forwardFeed, 0);

    engine = new MarginEngine(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), viewer);
    viewer.setMarginEngine(engine);
    engineMarket = engine.createMarket("eur");
    uint marketId = engineMarket;
    engine.whitelistAsset(future, marketId, IMarginEngine.AssetType.Future);
    MockFeeds spot = new MockFeeds();
    spot.setSpot(PRICE, 1e18);
    engine.setOraclesForMarket(marketId, ISpotFeed(address(spot)), IForwardFeed(address(0)), IVolFeed(address(0)));
    MockFeeds stable = new MockFeeds();
    stable.setSpot(1e18, 1e18);
    engine.setStableFeed(stable);
    engine.setFutureMarginRequirements(marketId, 0.1e18, 0.15e18);

    future.setWhitelistManager(address(engine), true);
    future.setTotalPositionCap(engine, 1e36);
    expiry = 1_796_050_800;
    subId = future.setContract(uint64(expiry), uint64(expiry - 30 minutes), PRICE);
    forwardFeed.setForwardPrice(expiry, PRICE, 1e18);

    feeAcc = subAccounts.createAccount(address(this), engine);
    book = new OnchainBook(subAccounts, IAsset(address(cash)), feeAcc);
    mkt = book.createMarket(future, subId, IOnchainBookManager(address(engine)), adapter, TICK, LOT);
    book.setMarketParams(mkt, FEE_RATE, 1, 1 hours, 8, true);

    usdc.approve(address(cash), type(uint).max);
    aliceAcc = _account(alice, 10_000e18);
    carolAcc = _account(carol, 10_000e18);
    bobAcc = _account(bob, 10_000e18);

    book.setMakerAllowed(alice, true);
    book.setMakerAllowed(carol, true);
    _maker(alice, aliceAcc, 0);
    _maker(carol, carolAcc, 0);
  }

  /////////////
  // Helpers //
  /////////////

  function _report(bytes32 feedId, uint observedAt, uint price) internal pure returns (bytes memory) {
    StreamsIndexAdapter.ReportV3 memory r = StreamsIndexAdapter.ReportV3({
      feedId: feedId,
      validFromTimestamp: uint32(observedAt),
      observationsTimestamp: uint32(observedAt),
      nativeFee: 0,
      linkFee: 0,
      expiresAt: uint32(observedAt + 30 days),
      benchmarkPrice: int192(int(price)),
      bid: int192(int(price)),
      ask: int192(int(price))
    });
    bytes32[3] memory ctx;
    return abi.encode(ctx, abi.encode(r), new bytes32[](0), new bytes32[](0), bytes32(0));
  }

  function _reports(uint price) internal view returns (bytes memory) {
    bytes[] memory reports = new bytes[](2);
    reports[0] = _report(EURC, block.timestamp, price);
    reports[1] = _report(USDC, block.timestamp, 1e18);
    return abi.encode(reports);
  }

  function _postIndex(uint price) internal {
    adapter.acceptData(_reports(price));
  }

  /// @dev An account owned by `owner`, funded, with max allowances to the book on the future and on cash.
  function _account(address owner, uint funding) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, engine);
    if (funding > 0) {
      usdc.mint(address(this), funding);
      cash.deposit(acc, funding);
    }
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(future, type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(address(cash)), type(uint).max, type(uint).max);
    vm.prank(owner);
    subAccounts.setAssetAllowances(acc, address(book), a);
  }

  /// @dev Curve 1: 1,000 lots at the half spread, then 2,000 lots 50 ticks further out. Both sides.
  function _maker(address owner, uint acc, int32 offsetTicks) internal {
    OnchainBook.Region[] memory r = new OnchainBook.Region[](2);
    r[0] = OnchainBook.Region(1000, 0);
    r[1] = OnchainBook.Region(2000, 50);
    vm.startPrank(owner);
    book.setCurve(1, r);
    book.registerMaker(mkt, acc);
    vm.stopPrank();
    _update(owner, acc, offsetTicks, 1);
  }

  function _update(address owner, uint acc, int32 offsetTicks, uint64 seq) internal {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate({
      marketId: mkt,
      accountId: acc,
      offsetTicks: offsetTicks,
      halfSpreadTicks: uint32(HALF_SPREAD),
      bidCurve: 1,
      askCurve: 1,
      skewTicksPerLot: 0,
      maxSkewTicks: 0,
      refillLotsPerSecond: 0,
      ttl: 1 hours,
      seq: seq
    });
    vm.prank(owner);
    book.updateSplines(u);
  }

  function _order(bool isBuy, uint lots, uint limit) internal view returns (OnchainBook.TakeOrder memory) {
    return OnchainBook.TakeOrder({
      marketId: mkt,
      takerAccountId: bobAcc,
      isBuy: isBuy,
      amount: lots * LOT,
      limitPrice: limit,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 20,
      selfTradeMode: OnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
  }

  function _take(OnchainBook.TakeOrder memory o) internal returns (uint filled, uint avg) {
    vm.prank(bob);
    return book.take(o, "");
  }

  function _pos(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, future, subId);
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  function _fee(uint lots, uint price) internal pure returns (uint) {
    uint notional = lots * LOT * 1_000e18 / 1e18 * price / 1e18;
    return (notional * FEE_RATE + 1e18 - 1) / 1e18;
  }
}

contract OnchainBookTest is OnchainBookBase {
  ///////////
  // Fills //
  ///////////

  function testBuyFillsAtTheBestAsk() public {
    (uint filled, uint avg) = _take(_order(true, 500, 2e18));
    uint ask = PRICE + HALF_SPREAD * TICK;
    assertEq(filled, 500 * LOT);
    assertEq(avg, ask);
    assertEq(_pos(bobAcc), int(500 * LOT));
    assertEq(_pos(aliceAcc), -int(500 * LOT), "alice registered first: she fills at an equal price");
    assertEq(_pos(carolAcc), 0);
    assertEq(_cash(feeAcc), int(_fee(500, ask)));
  }

  function testSellFillsAtTheBestBid() public {
    (uint filled, uint avg) = _take(_order(false, 500, 0));
    assertEq(filled, 500 * LOT);
    assertEq(avg, PRICE - HALF_SPREAD * TICK);
    assertEq(_pos(bobAcc), -int(500 * LOT));
    assertEq(_pos(aliceAcc), int(500 * LOT));
  }

  /// B5: identical balance changes to TradeModule for the same fill: the position with the price in assetData and no
  ///     quote leg, and the taker fee in cash.
  function testSameBalanceChangesAsTradeModule() public {
    uint ask = PRICE + HALF_SPREAD * TICK;
    uint snap = vm.snapshotState();
    _take(_order(true, 700, 2e18));
    int[4] memory viaBook = [_pos(bobAcc), _pos(aliceAcc), _cash(bobAcc), _cash(aliceAcc)];
    int feeViaBook = _cash(feeAcc);
    vm.revertToState(snap);

    // what TradeModule submits for the same fill, from an account with allowances on both sides as Matching has
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(future, type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(address(cash)), type(uint).max, type(uint).max);
    vm.prank(alice);
    subAccounts.setAssetAllowances(aliceAcc, address(this), a);
    vm.prank(bob);
    subAccounts.setAssetAllowances(bobAcc, address(this), a);
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](3);
    batch[0] = ISubAccounts.AssetTransfer(bobAcc, aliceAcc, cash, 0, 0, bytes32(0));
    batch[1] = ISubAccounts.AssetTransfer(aliceAcc, bobAcc, future, subId, int(700 * LOT), bytes32(ask));
    batch[2] = ISubAccounts.AssetTransfer(bobAcc, feeAcc, cash, 0, int(_fee(700, ask)), bytes32(0));
    subAccounts.submitTransfers(batch, "");
    assertEq(viaBook[0], _pos(bobAcc));
    assertEq(viaBook[1], _pos(aliceAcc));
    assertEq(viaBook[2], _cash(bobAcc));
    assertEq(viaBook[3], _cash(aliceAcc));
    assertEq(feeViaBook, _cash(feeAcc));
  }

  function testWalksBestPriceFirstAcrossMakers() public {
    _update(carol, carolAcc, -10, 2); // carol's asks 10 ticks better
    (uint filled, uint avg) = _take(_order(true, 1500, 2e18));
    assertEq(filled, 1500 * LOT);
    assertEq(_pos(carolAcc), -1000e15, "carol's first region first");
    assertEq(_pos(aliceAcc), -500e15, "then alice's first region, better than carol's second");
    uint carolAsk = PRICE + (HALF_SPREAD - 10) * TICK;
    uint aliceAsk = PRICE + HALF_SPREAD * TICK;
    assertEq(avg, (1000 * carolAsk + 500 * aliceAsk) / 1500);
  }

  function testNetPositionZeroAndCashConserved() public {
    uint pool = engine.accId();
    int cashBefore = _cash(bobAcc) + _cash(aliceAcc) + _cash(carolAcc) + _cash(feeAcc) + _cash(pool);
    _take(_order(true, 4500, 2e18));
    _take(_order(false, 2000, 0));
    assertEq(_pos(bobAcc) + _pos(aliceAcc) + _pos(carolAcc), 0);
    assertEq(
      _cash(bobAcc) + _cash(aliceAcc) + _cash(carolAcc) + _cash(feeAcc) + _cash(pool),
      cashBefore,
      "VM moves through the engine's pool account; fees to the recipient"
    );
  }

  ///////////////////
  // Walk stopping //
  ///////////////////

  function testStopsAtTheLimit() public {
    uint firstRegion = PRICE + HALF_SPREAD * TICK;
    (uint filled,) = _take(_order(true, 5000, firstRegion));
    assertEq(filled, 2000 * LOT, "both makers' first regions, nothing from the second at +50 ticks");
  }

  function testStopsAtMaxLevels() public {
    OnchainBook.TakeOrder memory o = _order(true, 5000, 2e18);
    o.maxLevels = 1;
    (uint filled,) = _take(o);
    assertEq(filled, 1000 * LOT);
  }

  function testStopsAtTheIndexBand() public {
    // carol quotes 3% + 1 tick above the index, outside the 3% band; alice inside
    _update(carol, carolAcc, int32(int(PRICE * 3 / 100 / TICK)) - int32(int(HALF_SPREAD)) + 1, 2);
    _update(alice, aliceAcc, 1_000_000, 2); // alice's whole curve far outside
    (uint filled,) = _take(_order(true, 1000, 2e18));
    assertEq(filled, 0, "nothing inside the band");
    _update(carol, carolAcc, int32(int(PRICE * 3 / 100 / TICK)) - int32(int(HALF_SPREAD)), 3);
    (filled,) = _take(_order(true, 1000, 2e18));
    assertEq(filled, 1000 * LOT, "exactly at the band edge fills: the future's own check passes");
  }

  /// One maker's levels settle as one transfer at their average price, and the future checks only that average. The
  /// walk must stop each level at the band, or a level outside it could ride along inside an in-band average.
  function testALevelOutsideTheBandDoesNotRideInsideAnInBandAverage() public {
    book.removeMaker(mkt, aliceAcc);
    // carol's first region 32,980 ticks above the index (inside 3% = 33,000), her second 33,030 (outside)
    _update(carol, carolAcc, int32(32_980) - int32(int(HALF_SPREAD)), 2);
    (uint filled,) = _take(_order(true, 1100, 2e18));
    assertEq(filled, 1000 * LOT, "the 100 lots outside the band are not taken, though the average would pass");
  }

  function testRoundsTheTakeDownToWholeLots() public {
    OnchainBook.TakeOrder memory o = _order(true, 0, 2e18);
    o.amount = 10 * LOT + LOT - 1;
    (uint filled,) = _take(o);
    assertEq(filled, 10 * LOT);
  }

  ///////////////////////////////////
  // Stale price (B6a) and reports //
  ///////////////////////////////////

  function testStalePriceFillsNothing() public {
    vm.warp(block.timestamp + 2);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp);
    (uint filled,) = _take(o);
    assertEq(filled, 0);
  }

  function testAttachedReportMakesItFreshAndMovesThePeg() public {
    vm.warp(block.timestamp + 2);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp);
    vm.prank(bob);
    (uint filled, uint avg) = book.take(o, _reports(1.11e18));
    assertEq(filled, 500 * LOT);
    assertEq(avg, 1.11e18 + HALF_SPREAD * TICK, "priced from the report posted in the same take");
  }

  function testStaleOptionMinFillRevertsRatherThanFillingNothingSilently() public {
    vm.warp(block.timestamp + 2);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp);
    o.minFill = 1;
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_BelowMinFill.selector);
    book.take(o, "");
  }

  //////////////////
  // Taker limits //
  //////////////////

  function testMaxFeeIsEnforced() public {
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.maxFee = _fee(500, PRICE + HALF_SPREAD * TICK) - 1;
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_FeeTooHigh.selector);
    book.take(o, "");
    o.maxFee += 1;
    vm.prank(bob);
    book.take(o, "");
  }

  function testPriorityTaxCountsInsideMaxFee() public {
    book.setPriorityTaxRate(1e6); // 1e6 cash wei per wei of priority fee
    vm.fee(1 gwei);
    vm.txGasPrice(2 gwei);
    uint tax = 1 gwei * 1e6;
    uint fee = _fee(500, PRICE + HALF_SPREAD * TICK);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.maxFee = fee + tax - 1;
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_FeeTooHigh.selector);
    book.take(o, "");
    o.maxFee = fee + tax;
    vm.prank(bob);
    book.take(o, "");
    assertEq(_cash(feeAcc), int(fee + tax));
  }

  function testMinFillAppliesToTheTotal() public {
    OnchainBook.TakeOrder memory o = _order(true, 5000, PRICE + HALF_SPREAD * TICK);
    o.minFill = 2001 * LOT;
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_BelowMinFill.selector);
    book.take(o, "");
  }

  function testDeadline() public {
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp - 1);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_Expired.selector);
    book.take(o, "");
  }

  function testOnlyTheAccountOwnerTakes() public {
    vm.prank(carol);
    vm.expectRevert(OnchainBook.OB_NotAuthorized.selector);
    book.take(_order(true, 500, 2e18), "");
  }

  function testNoTakeFromLastTradeTime() public {
    vm.warp(expiry - 30 minutes);
    _postIndex(PRICE);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_TradingClosed.selector);
    book.take(o, "");
  }

  function testDisabledMarket() public {
    book.setMarketParams(mkt, FEE_RATE, 1, 1 hours, 8, false);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_MarketDisabled.selector);
    book.take(_order(true, 500, 2e18), "");
  }

  function testTakerAllowanceTooLow() public {
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](1);
    a[0] = IAllowances.AssetAllowance(future, 499 * LOT, type(uint).max);
    vm.prank(bob);
    subAccounts.setAssetAllowances(bobAcc, address(book), a);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_TakerAllowanceTooLow.selector);
    book.take(_order(true, 500, 2e18), "");
  }

  ////////////////
  // Self trade //
  ////////////////

  function testSelfTradeAborts() public {
    book.setMakerAllowed(bob, true);
    uint bobMaker = _account(bob, 10_000e18);
    OnchainBook.Region[] memory r = new OnchainBook.Region[](1);
    r[0] = OnchainBook.Region(1000, 0);
    vm.startPrank(bob);
    book.setCurve(1, r);
    book.registerMaker(mkt, bobMaker);
    vm.stopPrank();
    _update(bob, bobMaker, -10, 1);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_SelfTrade.selector);
    book.take(_order(true, 500, 2e18), "");
  }

  function testSelfTradeDecrementsTheTake() public {
    book.setMakerAllowed(bob, true);
    uint bobMaker = _account(bob, 10_000e18);
    OnchainBook.Region[] memory r = new OnchainBook.Region[](1);
    r[0] = OnchainBook.Region(300, 0);
    vm.startPrank(bob);
    book.setCurve(1, r);
    book.registerMaker(mkt, bobMaker);
    vm.stopPrank();
    _update(bob, bobMaker, -10, 1);
    OnchainBook.TakeOrder memory o = _order(true, 1000, 2e18);
    o.selfTradeMode = OnchainBook.SelfTradeMode.DecrementTake;
    (uint filled,) = _take(o);
    assertEq(filled, 700 * LOT, "300 of the take cancelled against bob's own level");
    assertEq(_pos(bobMaker), 0);
  }

  ////////////////////////
  // Splines and curves //
  ////////////////////////

  function testSeqMustIncrease() public {
    vm.expectRevert(OnchainBook.OB_StaleSeq.selector);
    _update(alice, aliceAcc, 0, 1);
  }

  function testCrossedSplineReverts() public {
    OnchainBook.Region[] memory r = new OnchainBook.Region[](1);
    r[0] = OnchainBook.Region(1000, 0);
    vm.prank(alice);
    book.setCurve(2, r);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, 0, 0, 2, 2, 0, 0, 0, 1 hours, 5);
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_CrossedSpline.selector);
    book.updateSplines(u);
  }

  function testCurveOffsetsMustNotDecrease() public {
    OnchainBook.Region[] memory r = new OnchainBook.Region[](2);
    r[0] = OnchainBook.Region(1000, 10);
    r[1] = OnchainBook.Region(1000, 9);
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidCurve.selector);
    book.setCurve(3, r);
  }

  function testTtlLapsesQuotes() public {
    vm.warp(block.timestamp + 1 hours + 1);
    _postIndex(PRICE);
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.deadline = uint64(block.timestamp);
    (uint filled,) = _take(o);
    assertEq(filled, 0);
  }

  function testTtlAboveTheMarketMaxReverts() public {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, 0, 100, 1, 1, 0, 0, 0, 1 hours + 1, 5);
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidTtl.selector);
    book.updateSplines(u);
  }

  function testOnlyTheOwnerUpdatesASpline() public {
    vm.expectRevert(OnchainBook.OB_NotAuthorized.selector);
    _update(carol, aliceAcc, 0, 9);
  }

  function testMakerAllowlist() public {
    uint acc = _account(bob, 0);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_MakerNotAllowed.selector);
    book.registerMaker(mkt, acc);
  }

  function testMakersPerMarketCap() public {
    book.setMarketParams(mkt, FEE_RATE, 1, 1 hours, 2, true);
    book.setMakerAllowed(bob, true);
    uint acc = _account(bob, 0);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_TooManyMakers.selector);
    book.registerMaker(mkt, acc);
  }

  /// Consumption is a cursor refilling at refillLotsPerSecond, not per block (B7).
  function testCursorRefillsAtTheMakersRate() public {
    book.removeMaker(mkt, carolAcc);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, 0, uint32(HALF_SPREAD), 1, 1, 0, 0, 100, 1 hours, 2);
    vm.prank(alice);
    book.updateSplines(u);

    uint firstRegion = PRICE + HALF_SPREAD * TICK;
    (uint filled,) = _take(_order(true, 1000, firstRegion));
    assertEq(filled, 1000 * LOT);
    (filled,) = _take(_order(true, 1000, firstRegion));
    assertEq(filled, 0, "first region consumed, same second");

    vm.warp(block.timestamp + 3);
    _postIndex(PRICE);
    OnchainBook.TakeOrder memory o = _order(true, 1000, firstRegion);
    o.deadline = uint64(block.timestamp);
    (filled,) = _take(o);
    assertEq(filled, 300 * LOT, "3 s at 100 lots a second");
  }

  function testAnUpdateResetsBothCursors() public {
    book.removeMaker(mkt, carolAcc);
    uint bestAsk = PRICE + HALF_SPREAD * TICK;
    uint bestBid = PRICE - HALF_SPREAD * TICK;
    _take(_order(true, 1000, bestAsk));
    _take(_order(false, 1000, bestBid));
    (uint filled,) = _take(_order(true, 1000, bestAsk));
    assertEq(filled, 0);
    _update(alice, aliceAcc, 0, 2);
    (filled,) = _take(_order(true, 1000, bestAsk));
    assertEq(filled, 1000 * LOT, "ask cursor reset");
    (filled,) = _take(_order(false, 1000, bestBid));
    assertEq(filled, 1000 * LOT, "bid cursor reset");
  }

  function testSkewMovesTheMid() public {
    book.removeMaker(mkt, carolAcc);
    _take(_order(true, 1000, 2e18)); // alice is short 1,000 lots
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, 0, uint32(HALF_SPREAD), 1, 1, 1, 30, 0, 1 hours, 2);
    vm.prank(alice);
    book.updateSplines(u);
    (, uint avg) = _take(_order(false, 100, 0));
    assertEq(avg, PRICE + 30 * TICK - HALF_SPREAD * TICK, "short maker raises its mid, clamped to 30 ticks");
  }

  function testSkewIsClampedForALongMakerToo() public {
    book.removeMaker(mkt, carolAcc);
    _take(_order(false, 1000, 0)); // alice is long 1,000 lots
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, 0, uint32(HALF_SPREAD), 1, 1, 1, 30, 0, 1 hours, 2);
    vm.prank(alice);
    book.updateSplines(u);
    (, uint avg) = _take(_order(true, 100, 2e18));
    assertEq(avg, PRICE - 30 * TICK + HALF_SPREAD * TICK, "long maker lowers its mid, clamped to 30 ticks");
  }

  ////////////////////////////////////////////////////
  // One failing maker must not freeze the market (B5a) //
  ////////////////////////////////////////////////////

  /// A maker whose batch reverts on margin is skipped for this take only; its spline stays active.
  function testMakerBelowMarginIsSkippedNotDeactivated() public {
    uint poor = _account(alice, 1e18);
    vm.prank(alice);
    book.registerMaker(mkt, poor);
    _update(alice, poor, -10, 1); // best price, cannot carry 1,000 lots
    (uint filled,) = _take(_order(true, 1000, 2e18));
    assertEq(filled, 1000 * LOT, "the others filled it");
    assertEq(_pos(poor), 0);
    (,,,,,,,,,, bool active) = book.splines(mkt, poor);
    assertTrue(active, "a caught revert changes nothing stored");
  }

  /// An underfunded taker reverts every batch: it must not be able to switch the makers off.
  function testUnderfundedTakerCannotDeactivateMakers() public {
    uint broke = _account(bob, 0);
    OnchainBook.TakeOrder memory o = _order(true, 1000, 2e18);
    o.takerAccountId = broke;
    (uint filled,) = _take(o);
    assertEq(filled, 0);
    (,,,,,,,,,, bool aliceActive) = book.splines(mkt, aliceAcc);
    (,,,,,,,,,, bool carolActive) = book.splines(mkt, carolAcc);
    assertTrue(aliceActive && carolActive);
  }

  function testRevokedMakerAllowanceDeactivates() public {
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](1);
    a[0] = IAllowances.AssetAllowance(future, 0, 0);
    vm.prank(alice);
    subAccounts.setAssetAllowances(aliceAcc, address(book), a);
    (uint filled,) = _take(_order(true, 500, 2e18));
    assertEq(filled, 500 * LOT, "alice was planned, dropped, and carol filled it in the next round");
    assertEq(_pos(carolAcc), -int(500 * LOT));
    assertEq(_pos(aliceAcc), 0);
    (,,,,,,,,,, bool active) = book.splines(mkt, aliceAcc);
    assertFalse(active, "an allowance failure is attributable: switched off");
  }

  function testMakerInAnAuctionIsNotQuoted() public {
    auction.startAuction(aliceAcc, 0);
    vm.recordLogs();
    _take(_order(true, 500, 2e18));
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint i; i < logs.length; ++i) {
      assertTrue(logs[i].topics[0] != OnchainBook.MakerSkipped.selector, "never planned, so never attempted");
    }
    assertEq(_pos(aliceAcc), 0);
    assertEq(_pos(carolAcc), -int(500 * LOT));
  }

  function testPokeDeactivatesBelowInitialMargin() public {
    uint poor = _account(alice, 300e18);
    vm.prank(alice);
    book.registerMaker(mkt, poor);
    _update(alice, poor, -10, 1);
    _take(_order(true, 1000, 2e18)); // poor is short one contract, IM 165 of its 300
    assertEq(_pos(poor), -1e18);
    book.poke(mkt, poor);
    (,,,,,,,,,, bool active) = book.splines(mkt, poor);
    assertTrue(active, "above IM");
    engine.setFutureMarginRequirements(engineMarket, 0.2e18, 0.3e18); // IM 330 > 300
    book.poke(mkt, poor);
    (,,,,,,,,,, active) = book.splines(mkt, poor);
    assertFalse(active);
  }

  function testPokeDeactivatesInAnAuction() public {
    auction.startAuction(aliceAcc, 0);
    book.poke(mkt, aliceAcc);
    (,,,,,,,,,, bool active) = book.splines(mkt, aliceAcc);
    assertFalse(active);
  }

  function testGasFloor() public {
    book.setGasFloor(type(uint).max);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_GasFloor.selector);
    book.take(_order(true, 500, 2e18), "");
  }

  //////////////////////////////////////////
  // Maker accounts stay on the engine    //
  //////////////////////////////////////////

  function testAMakerUnderAnotherManagerCannotRegister() public {
    RevertingManager other = new RevertingManager();
    uint acc = subAccounts.createAccount(alice, IManager(address(other)));
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_WrongManager.selector);
    book.registerMaker(mkt, acc);
  }

  function testAMarketsEngineMustBeWhitelistedOnTheFuture() public {
    RevertingManager other = new RevertingManager();
    vm.expectRevert(OnchainBook.OB_InvalidParams.selector);
    book.createMarket(future, subId, IOnchainBookManager(address(other)), adapter, TICK, LOT);
  }

  ////////////////
  // Reentrancy //
  ////////////////

  function _evilMarket() internal returns (ReentrantAdapter evil, uint m2) {
    evil = new ReentrantAdapter(adapter, address(book));
    m2 = book.createMarket(
      future, subId, IOnchainBookManager(address(engine)), StreamsIndexAdapter(address(evil)), TICK, LOT
    );
    book.setMarketParams(m2, FEE_RATE, 1, 1 hours, 8, true);
  }

  function testReentryIntoTakeIsRefused() public {
    (ReentrantAdapter evil, uint m2) = _evilMarket();
    evil.setReentry(abi.encodeCall(OnchainBook.take, (_order(true, 500, 2e18), bytes(""))));
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.marketId = m2;
    vm.prank(bob);
    vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    book.take(o, hex"01");
  }

  /// The walk reads splines, cursors and curves: none may change under it.
  function testReentryIntoMakerStateIsRefused() public {
    (ReentrantAdapter evil, uint m2) = _evilMarket();
    OnchainBook.TakeOrder memory o = _order(true, 500, 2e18);
    o.marketId = m2;
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](0);
    OnchainBook.Region[] memory r = new OnchainBook.Region[](0);
    bytes[5] memory calls = [
      abi.encodeCall(OnchainBook.updateSplines, (u)),
      abi.encodeCall(OnchainBook.poke, (mkt, aliceAcc)),
      abi.encodeCall(OnchainBook.cancelSpline, (mkt, aliceAcc)),
      abi.encodeCall(OnchainBook.setCurve, (1, r)),
      abi.encodeCall(OnchainBook.registerMaker, (mkt, aliceAcc))
    ];
    for (uint i; i < calls.length; ++i) {
      evil.setReentry(calls[i]);
      vm.prank(bob);
      vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
      book.take(o, hex"01");
    }
  }

  //////////////////////////////
  // Gas griefing (B5a, B11)  //
  //////////////////////////////

  /// @dev Whether some gas limit lets a take succeed with a maker skipped by running out of gas inside its batch,
  ///      the 63/64 rule's grief. Sweeps the limit across the whole range a one-maker take can run in.
  function _griefable() internal returns (bool found, uint atGas) {
    book.removeMaker(mkt, carolAcc);
    bytes memory call = abi.encodeCall(OnchainBook.take, (_order(true, 500, 2e18), bytes("")));
    for (uint g = 150_000; g <= 2_500_000; g += 5_000) {
      uint snap = vm.snapshotState();
      vm.recordLogs();
      vm.prank(bob);
      (bool ok,) = address(book).call{gas: g}(call);
      Vm.Log[] memory logs = vm.getRecordedLogs();
      vm.revertToState(snap);
      if (!ok) continue;
      for (uint i; i < logs.length; ++i) {
        if (logs[i].emitter == address(book) && logs[i].topics[0] == OnchainBook.MakerSkipped.selector) {
          return (true, g);
        }
      }
    }
  }

  /// A batch that runs out of gas reverts the take; it is never caught and skipped. submitTransfers is replaced by
  /// one that burns everything it is given, as a batch made heavy through the taker's own account would.
  function testABatchOutOfGasRevertsTheTakeRatherThanSkippingTheMaker() public {
    GasBurner burner = new GasBurner();
    vm.mockFunction(
      address(subAccounts), address(burner), abi.encodeWithSelector(ISubAccounts.submitTransfers.selector)
    );
    // tests run with a near-unlimited gas limit (foundry.toml): give the take a real one
    vm.prank(bob);
    (bool ok, bytes memory ret) =
      address(book).call{gas: 5_000_000}(abi.encodeCall(OnchainBook.take, (_order(true, 500, 2e18), bytes(""))));
    assertFalse(ok);
    assertEq(bytes4(ret), OnchainBook.OB_BatchOutOfGas.selector);
  }

  /// A genuine revert is still caught and skipped, however little gas it used.
  function testAGenuineRevertIsStillSkipped() public {
    vm.mockCallRevert(
      address(subAccounts), abi.encodeWithSelector(ISubAccounts.submitTransfers.selector), bytes("margin")
    );
    vm.prank(bob);
    (uint filled,) = book.take(_order(true, 500, 2e18), "");
    assertEq(filled, 0);
  }

  function testWithTheGasFloorNoGasLimitSkipsAMaker() public {
    book.setGasFloor(GAS_FLOOR);
    (bool found, uint atGas) = _griefable();
    assertFalse(found, string.concat("skipped at gas ", vm.toString(atGas)));
  }

  ///////////
  // Admin //
  ///////////

  function testOnlyOwnerAdmin() public {
    vm.startPrank(bob);
    vm.expectRevert();
    book.setMakerAllowed(bob, true);
    vm.expectRevert();
    book.setMarketParams(mkt, FEE_RATE, 1, 1 hours, 8, true);
    vm.expectRevert();
    book.setGasFloor(0);
    vm.stopPrank();
  }

  function testRemoveMakerKeepsRegistrationOrder() public {
    book.setMakerAllowed(bob, true);
    uint b = _account(bob, 0);
    vm.prank(bob);
    book.registerMaker(mkt, b);
    book.removeMaker(mkt, aliceAcc);
    uint[] memory list = book.makers(mkt);
    assertEq(list.length, 2);
    assertEq(list[0], carolAcc);
    assertEq(list[1], b);
  }
}
