// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBook.t.sol";

/// @dev Self-priced splines (spec C3, C4.2): the maker posts its mid, quoting without fresh reports until its ttl (capped
///      by the market's maxSelfPricedTtl, decided 60 s) while every fill stays inside the index band. Fixture: index 1.10
///      (1,100,000 ticks), band 3% (33,000 ticks), takeMaxAge 1 s, the index itself reverts past 60 s.
contract OnchainBookSelfPricedTest is OnchainBookBase {
  int32 constant MID = 1_100_500; // 1.1005
  uint32 constant CAP = 60;

  function setUp() public override {
    super.setUp();
    book.setSelfPricedTtlCap(mkt, CAP);
  }

  function _self(address owner, uint acc, int32 mid, uint64 seq, uint32 ttl) internal {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate({
      marketId: mkt,
      accountId: acc,
      offsetTicks: mid,
      halfSpreadTicks: uint32(HALF_SPREAD),
      bidCurve: 1,
      askCurve: 1,
      skewTicksPerLot: 0,
      maxSkewTicks: 0,
      refillLotsPerSecond: 0,
      ttl: ttl,
      seq: seq,
      selfPriced: true
    });
    vm.prank(owner);
    book.updateSplines(u);
  }

  /// @dev Only alice quotes, self-priced.
  function _onlyAliceSelfPriced(int32 mid, uint32 ttl) internal {
    _self(alice, aliceAcc, mid, 2, ttl);
    vm.prank(carol);
    book.cancelSpline(mkt, carolAcc);
  }

  function _ticks(int32 t) internal pure returns (uint) {
    return uint(int(t)) * TICK;
  }

  ///////////
  // Price //
  ///////////

  function testASelfPricedSplineQuotesAroundItsOwnMid() public {
    _onlyAliceSelfPriced(MID, CAP);
    (uint filled, uint avg) = _take(_order(true, 500, 2e18));
    assertEq(filled, 500 * LOT);
    assertEq(avg, _ticks(MID) + HALF_SPREAD * TICK, "ask = her mid + half spread, not the index's");

    (filled, avg) = _take(_order(false, 500, 0));
    assertEq(avg, _ticks(MID) - HALF_SPREAD * TICK, "bid = her mid - half spread");
  }

  /// The index moving does not move a self-priced quote; a pegged one moves with it.
  function testTheIndexMovingDoesNotMoveASelfPricedQuote() public {
    _self(alice, aliceAcc, MID, 2, CAP);
    _update(carol, carolAcc, 0, 2);
    vm.warp(block.timestamp + 1); // a report replaces the stored one only when newer
    _postIndex(1.102e18); // carol's ask: 1,102,100; alice's stays 1,100,600
    (, uint avg) = _take(_order(true, 500, 2e18));
    assertEq(avg, _ticks(MID) + HALF_SPREAD * TICK, "alice's is the best ask");
  }

  /// At equal prices registration order decides, whatever the mode: alice registered first.
  function testAtEqualPricesRegistrationOrderDecidesAcrossModes() public {
    _self(carol, carolAcc, 1_100_000, 2, CAP); // carol self-priced at the index, alice pegged at offset 0: same ask
    (uint filled,) = _take(_order(true, 500, 2e18));
    assertEq(filled, 500 * LOT);
    assertEq(_pos(aliceAcc), -int(500 * LOT), "alice (pegged, registered first) fills");
    assertEq(_pos(carolAcc), 0);

    _self(alice, aliceAcc, 1_100_000, 2, CAP); // now alice self-priced, carol self-priced: still alice
    _update(carol, carolAcc, 0, 3); // and carol pegged
    (filled,) = _take(_order(true, 500, 2e18));
    assertEq(_pos(aliceAcc), -int(1000 * LOT), "alice (self-priced, registered first) fills");
    assertEq(_pos(carolAcc), 0);
  }

  ///////////////
  // Freshness //
  ///////////////

  /// Past takeMaxAge pegged splines stop; a self-priced one inside its ttl still quotes.
  function testASelfPricedSplineQuotesOnReportsTooOldForPegged() public {
    _self(alice, aliceAcc, MID, 2, CAP);
    vm.warp(block.timestamp + 5); // reports 5 s old: over takeMaxAge (1 s), under the index's 60 s
    OnchainBook.TakeOrder memory o = _order(true, 1500, 2e18);
    (uint filled, uint avg) = _take(o);
    assertEq(filled, 1500 * LOT, "alice's 1,000 at the spread and 500 of her second region; carol (pegged) none");
    assertGt(avg, _ticks(MID) + HALF_SPREAD * TICK, "into alice's second region");
    assertEq(_pos(carolAcc), 0, "carol pegged: out");
  }

  /// A pegged spline at a negative offset next to a self-priced one, on reports too old for pegged: the pegged one is
  /// left out before its mid is computed (index + offset would underflow and revert the whole take).
  function testAPeggedSplineAtANegativeOffsetIsLeftOutOnOldReports() public {
    _self(alice, aliceAcc, MID, 2, CAP);
    _update(carol, carolAcc, -10, 2);
    vm.warp(block.timestamp + 5);
    OnchainBook.TakeOrder memory o = _order(false, 500, 0);
    (uint filled, uint avg) = _take(o);
    assertEq(filled, 500 * LOT);
    assertEq(avg, _ticks(MID) - HALF_SPREAD * TICK, "alice's bid");
    assertEq(_pos(carolAcc), 0);
  }

  /// Fail closed: once the index cannot be read every fill would be unbounded, so nothing quotes and the take fills 0.
  function testAnUnreadableIndexStopsSelfPricedQuotes() public {
    _onlyAliceSelfPriced(MID, CAP);
    vm.warp(block.timestamp + 59);
    _self(alice, aliceAcc, MID, 3, CAP); // her quote fresh; the reports 59 s old
    (uint filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, LOT, "index still readable");
    vm.warp(block.timestamp + 2); // reports 61 s old: getSpot reverts
    vm.expectRevert();
    index.getSpot();
    (filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0, "fails closed, without reverting the take");
  }

  function testARotatedIndexStopsSelfPricedQuotes() public {
    _onlyAliceSelfPriced(MID, CAP);
    vm.mockCall(address(index), abi.encodeWithSignature("adapter()"), abi.encode(address(0xada)));
    (uint filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0);
  }

  /// The cap bounds a self-priced quote's life even with fresh reports.
  function testASelfPricedQuoteExpiresAtItsTtl() public {
    _onlyAliceSelfPriced(MID, 10);
    vm.warp(block.timestamp + 10);
    _postIndex(PRICE);
    (uint filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, LOT, "at its ttl");
    vm.warp(block.timestamp + 1);
    _postIndex(PRICE);
    (filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0, "past it");
  }

  /// Lowering the cap applies to quotes already posted; 0 switches self-priced quoting off at once.
  function testLoweringTheCapAppliesToPostedQuotes() public {
    _onlyAliceSelfPriced(MID, CAP);
    vm.warp(block.timestamp + 20);
    _postIndex(PRICE);
    book.setSelfPricedTtlCap(mkt, 10);
    (uint filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0, "20 s old, cap now 10 s");

    book.setSelfPricedTtlCap(mkt, CAP);
    (filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, LOT, "back under the cap");

    book.setSelfPricedTtlCap(mkt, 0);
    (filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0, "off");
  }

  //////////
  // Band //
  //////////

  /// A self-priced mid off the index cannot fill outside the band: its near levels are dropped, the far edge stops.
  function testASelfPricedQuoteOutsideTheBandDoesNotFill() public {
    _onlyAliceSelfPriced(1_140_000, CAP); // 3.6% above the index: every ask past the far edge
    (uint filled,) = _take(_order(true, 500, 2e18));
    assertEq(filled, 0, "asks above the band");
    (filled,) = _take(_order(false, 500, 0));
    assertEq(filled, 0, "bids above the band: short of the near edge, dropped");

    _self(alice, aliceAcc, 1_100_000 + 33_000 - int32(int(HALF_SPREAD)), 3, CAP); // best ask on the band's edge
    (filled,) = _take(_order(true, 500, 2e18));
    assertEq(filled, 500 * LOT, "at the edge it fills");
  }

  ////////////
  // Update //
  ////////////

  function testSelfPricedUpdatesAreValidated() public {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, MID, uint32(HALF_SPREAD), 1, 1, 0, 0, 0, CAP + 1, 2, true);
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidTtl.selector);
    book.updateSplines(u);

    u[0].ttl = CAP;
    u[0].offsetTicks = 0;
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidMid.selector);
    book.updateSplines(u);

    u[0].offsetTicks = -1;
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidMid.selector);
    book.updateSplines(u);

    // Pegged: a negative offset and a long ttl stay valid.
    u[0].offsetTicks = -1;
    u[0].ttl = 1 hours;
    u[0].selfPriced = false;
    vm.prank(alice);
    book.updateSplines(u);
  }

  /// The default cap is 0: a market quotes self-priced only once the owner opts it in.
  function testSelfPricedIsOffUntilTheOwnerSetsACap() public {
    book.setSelfPricedTtlCap(mkt, 0);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, aliceAcc, MID, uint32(HALF_SPREAD), 1, 1, 0, 0, 0, 1, 2, true);
    vm.prank(alice);
    vm.expectRevert(OnchainBook.OB_InvalidTtl.selector);
    book.updateSplines(u);
  }

  function testOnlyTheOwnerSetsTheCapAndAtMostMaxTtl() public {
    vm.prank(alice);
    vm.expectRevert();
    book.setSelfPricedTtlCap(mkt, 30);
    vm.expectRevert(OnchainBook.OB_InvalidParams.selector);
    book.setSelfPricedTtlCap(mkt, 1 hours + 1);
    book.setSelfPricedTtlCap(mkt, 1 hours);
    assertEq(book.maxSelfPricedTtl(mkt), 1 hours);
  }

  /// An update switches a spline between modes; the getter keeps v1's layout and isSelfPriced reads the mode.
  function testAnUpdateSwitchesModeAndTheGetterKeepsV1sLayout() public {
    _self(alice, aliceAcc, MID, 2, CAP);
    assertTrue(book.isSelfPriced(mkt, aliceAcc));
    (bool ok, bytes memory ret) =
      address(book).staticcall(abi.encodeWithSignature("splines(uint256,uint256)", mkt, aliceAcc));
    assertTrue(ok);
    assertEq(ret.length, 12 * 32, "12 words, as v1's public getter");
    (int32 offsetTicks,,,,,,,,,, bool active, address owner) =
      abi.decode(ret, (int32, uint32, uint16, uint16, uint32, uint32, uint32, uint40, uint32, uint64, bool, address));
    assertEq(offsetTicks, MID);
    assertTrue(active);
    assertEq(owner, alice);

    _update(alice, aliceAcc, 0, 3);
    assertFalse(book.isSelfPriced(mkt, aliceAcc));
    vm.warp(block.timestamp + 5);
    (uint filled,) = _take(_order(true, 1, 2e18));
    assertEq(filled, 0, "pegged again: stops on old reports");
  }

  ///////////
  // Quote //
  ///////////

  function testFuzzQuoteEqualsTakeWithSelfPriced(uint lots, int16 midOff, uint8 age, bool isBuy, bool carolSelf)
    public
  {
    lots = bound(lots, 1, 6000);
    _self(alice, aliceAcc, int32(1_100_000 + int(bound(midOff, -40_000, 40_000))), 2, CAP);
    if (carolSelf) _self(carol, carolAcc, MID, 2, CAP);
    vm.warp(block.timestamp + bound(age, 0, 70));
    OnchainBook.TakeOrder memory o = _order(isBuy, lots, isBuy ? 2e18 : 0);
    try book.quote(o) returns (uint filled, uint avgPrice, uint fee, uint) {
      int before = _cash(feeAcc);
      (uint f, uint a) = _take(o);
      assertEq(filled, f, "filled");
      assertEq(avgPrice, a, "avgPrice");
      assertEq(fee, uint(_cash(feeAcc) - before), "fee");
    } catch (bytes memory reason) {
      vm.prank(bob);
      vm.expectRevert(reason);
      book.take(o, "");
    }
  }
}
