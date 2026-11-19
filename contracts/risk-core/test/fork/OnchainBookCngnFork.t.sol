// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {StreamsIndexAdapter} from "../../src/feeds/StreamsIndexAdapter.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IFutureAssetV3} from "../../src/interfaces/IFutureAssetV3.sol";
import {OnchainBook, IOnchainBookManager} from "../../src/periphery/OnchainBook.sol";

/**
 * A market with no adapter, on the live cNGN-30NOV26 future (FutureAsset v2 under MarginEngine v2). cNGN's index is
 * our signed spot feed, not a Data Streams pair, so the book cannot peg to reports: the market quotes self-priced
 * splines only, inside the future's own index band, while the future still reads the feed it read at listing.
 *
 * Nothing is mocked except where a test says so: SubAccounts, the engine, the future, its spot feed and the cash asset
 * are the deployed ones. Requires BASE_RPC_URL.
 */
contract OnchainBookCngnFork is Test {
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  IFutureAssetV3 constant FUTURE = IFutureAssetV3(0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75);
  uint96 constant SUB_ID = 1796047200; // cNGN-30NOV26
  MarginEngine constant ENGINE = MarginEngine(0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950);
  CashAsset constant CASH = CashAsset(0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272);
  /// @dev EURC-30NOV26's adapter: a real adapter, but not this future's index
  StreamsIndexAdapter constant EURC_ADAPTER = StreamsIndexAdapter(0x9E9aB6ee5ccf0b050Eba0b64Ce9429334D49FfEB);
  uint constant FEE_ACCOUNT = 22;

  /// @dev Pinned (CLAUDE.md: chain state moves under tests): 2026-11-18, cNGN-30NOV26 listed and trading.
  uint constant FORK_BLOCK = 59_240_000;

  /// @dev cNGN is ~0.00068 USDC: a 1e12 tick would be 15 bps. 1e10 is 0.15 bps.
  uint constant TICK = 1e10;
  uint constant LOT = 1e15;
  uint constant FEE_RATE = 0.0015e18; // the registry's 15 bps

  SubAccounts subAccounts;
  OnchainBook book;
  uint mkt;
  uint index;

  address maker = address(0x1000);
  address bob = address(0xb0b);
  uint makerAcc;
  uint bobAcc;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    subAccounts = SubAccounts(address(ENGINE.subAccounts()));
    (index,) = FUTURE.indexFeed().getSpot();

    book = new OnchainBook(subAccounts, IAsset(address(CASH)), FEE_ACCOUNT);
    mkt = book.createMarket(
      FUTURE, SUB_ID, IOnchainBookManager(address(ENGINE)), StreamsIndexAdapter(address(0)), TICK, LOT
    );
    book.setMarketParams(mkt, FEE_RATE, 1, 1 hours, 10, true);
    book.setSelfPricedTtlCap(mkt, 60);
    book.setMakerAllowed(maker, true);

    makerAcc = _account(maker, 20_000e6);
    bobAcc = _account(bob, 10_000e6);

    OnchainBook.Region[] memory r = new OnchainBook.Region[](3);
    r[0] = OnchainBook.Region(500, 0);
    r[1] = OnchainBook.Region(1000, 20);
    r[2] = OnchainBook.Region(2000, 60);
    vm.startPrank(maker);
    book.setCurve(1, r);
    book.registerMaker(mkt, makerAcc);
    vm.stopPrank();
  }

  function _account(address owner, uint usdc) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, IManager(address(ENGINE)));
    deal(USDC, owner, usdc);
    vm.startPrank(owner);
    IERC20Metadata(USDC).approve(address(CASH), usdc);
    CASH.deposit(acc, usdc);
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(FUTURE, type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(address(CASH)), type(uint).max, type(uint).max);
    subAccounts.setAssetAllowances(acc, address(book), a);
    vm.stopPrank();
  }

  /// @dev A self-priced spline at the index, 10 ticks half spread.
  function _quoteAtIndex(bool selfPriced, uint seq) internal {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(
      mkt, makerAcc, selfPriced ? int32(int(index / TICK)) : int32(0), 10, 1, 1, 0, 0, 0, 60, uint64(seq), selfPriced
    );
    vm.prank(maker);
    book.updateSplines(u);
  }

  function _order(bool isBuy, uint lots) internal view returns (OnchainBook.TakeOrder memory) {
    return OnchainBook.TakeOrder({
      marketId: mkt,
      takerAccountId: bobAcc,
      isBuy: isBuy,
      amount: lots * LOT,
      limitPrice: isBuy ? index * 2 : 0,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 255,
      selfTradeMode: OnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
  }

  ///////////
  // Tests //
  ///////////

  function testListedWithNoAdapterRecordsTheIndexFeed() public view {
    assertGt(index, 0.0003e18);
    assertLt(index, 0.003e18);
    assertEq(book.indexFeedOf(mkt), address(FUTURE.indexFeed()));
    // markets()'s sixth word is the adapter: the getter's layout is unchanged, and it is empty here
    (bool ok, bytes memory d) = address(book).staticcall(abi.encodeWithSelector(book.markets.selector, mkt));
    assertTrue(ok);
    address adapter;
    assembly {
      adapter := mload(add(d, 0xc0))
    }
    assertEq(adapter, address(0));
  }

  /// cNGN's spot feed has no adapter(): naming any adapter for this future is refused.
  function testAnAdapterTheIndexDoesNotHaveIsRefused() public {
    vm.expectRevert();
    book.createMarket(FUTURE, SUB_ID, IOnchainBookManager(address(ENGINE)), EURC_ADAPTER, TICK, LOT);
  }

  /// With no adapter the feed is the only thing that ties the market to an index: a future without one is refused.
  function testAFutureWithNoIndexFeedIsRefused() public {
    vm.mockCall(address(FUTURE), abi.encodeWithSignature("indexFeed()"), abi.encode(address(0)));
    vm.expectRevert(OnchainBook.OB_InvalidParams.selector);
    book.createMarket(FUTURE, SUB_ID, IOnchainBookManager(address(ENGINE)), StreamsIndexAdapter(address(0)), TICK, LOT);
  }

  function testASelfPricedTakeFillsBothWaysOnTheLiveEngine() public {
    _quoteAtIndex(true, 1);
    (uint q,,,) = book.quote(_order(true, 300));
    assertEq(q, 300 * LOT);

    vm.prank(bob);
    (uint filled,) = book.take(_order(true, 300), "");
    assertEq(filled, 300 * LOT);
    assertEq(subAccounts.getBalance(bobAcc, FUTURE, SUB_ID), int(300 * LOT));
    assertEq(subAccounts.getBalance(makerAcc, FUTURE, SUB_ID), -int(300 * LOT));
    (int bobMargin,) = ENGINE.getMarginAndMarkToMarket(bobAcc, true, 0);
    (int makerMargin,) = ENGINE.getMarginAndMarkToMarket(makerAcc, true, 0);
    assertGt(bobMargin, 0);
    assertGt(makerMargin, 0);

    vm.prank(bob);
    (filled,) = book.take(_order(false, 300), "");
    assertEq(filled, 300 * LOT);
    assertEq(subAccounts.getBalance(bobAcc, FUTURE, SUB_ID), 0);
    assertEq(subAccounts.getBalance(makerAcc, FUTURE, SUB_ID), 0);
  }

  /// The future's band holds: a self-priced mid far off the index fills nothing on the far side of the band.
  function testTheIndexBandStillBounds() public {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, makerAcc, int32(int(index * 2 / TICK)), 10, 1, 1, 0, 0, 0, 60, 1, true);
    vm.prank(maker);
    book.updateSplines(u);
    (uint q,,,) = book.quote(_order(true, 300));
    assertEq(q, 0, "an ask at twice the index is outside the band");
  }

  function testAPeggedSplineIsRefused() public {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, makerAcc, 0, 10, 1, 1, 0, 0, 0, 60, 1, false);
    vm.prank(maker);
    vm.expectRevert(OnchainBook.OB_NoAdapter.selector);
    book.updateSplines(u);
  }

  function testAReportIsRefused() public {
    _quoteAtIndex(true, 1);
    OnchainBook.TakeOrder memory o = _order(true, 10);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_NoAdapter.selector);
    book.take(o, hex"01");
  }

  /// Once the future reads another index, the band prices something this market did not list on: nothing quotes.
  function testARotatedIndexStopsQuoting() public {
    _quoteAtIndex(true, 1);
    vm.mockCall(address(FUTURE), abi.encodeWithSignature("indexFeed()"), abi.encode(address(0xfeed)));
    (uint q,,,) = book.quote(_order(true, 10));
    assertEq(q, 0);
    vm.prank(bob);
    (uint filled,) = book.take(_order(true, 10), "");
    assertEq(filled, 0);
  }

  /// The EURC path is unchanged: a market with an adapter records no index feed.
  function testAnAdapterMarketRecordsNoFeed() public {
    IFutureAssetV3 eurc = IFutureAssetV3(0xC350243c1d07Ff598770ECe12323799D2EFbB227);
    uint m2 = book.createMarket(eurc, 1796050800, IOnchainBookManager(address(ENGINE)), EURC_ADAPTER, 1e12, LOT);
    assertEq(book.indexFeedOf(m2), address(0));
  }
}
