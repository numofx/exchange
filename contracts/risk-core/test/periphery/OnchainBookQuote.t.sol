// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBook.t.sol";

/// @dev `quote` (spec C4.1) must equal what `take` then does, whenever no settlement reverts on margin.
contract OnchainBookQuoteTest is OnchainBookBase {
  struct Outcome {
    uint filled;
    uint avgPrice;
    uint fee;
  }

  function _quote(OnchainBook.TakeOrder memory o) internal view returns (Outcome memory q, uint makers) {
    (q.filled, q.avgPrice, q.fee, makers) = book.quote(o);
  }

  /// @dev take, with the fee read as what the fee account received.
  function _takeOutcome(OnchainBook.TakeOrder memory o) internal returns (Outcome memory t) {
    int before = _cash(feeAcc);
    (t.filled, t.avgPrice) = _take(o);
    t.fee = uint(_cash(feeAcc) - before);
  }

  function _assertSame(Outcome memory q, Outcome memory t, string memory what) internal pure {
    assertEq(q.filled, t.filled, string.concat(what, ": filled"));
    assertEq(q.avgPrice, t.avgPrice, string.concat(what, ": avgPrice"));
    assertEq(q.fee, t.fee, string.concat(what, ": fee"));
  }

  function _revokeFuture(address owner, uint acc) internal {
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](1);
    a[0] = IAllowances.AssetAllowance(future, 0, 0);
    vm.prank(owner);
    subAccounts.setAssetAllowances(acc, address(book), a);
  }

  function _updateWithSkew(address owner, uint acc, int32 offsetTicks, uint64 seq, uint32 skewPerLot) internal {
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate({
      marketId: mkt,
      accountId: acc,
      offsetTicks: offsetTicks,
      halfSpreadTicks: uint32(HALF_SPREAD),
      bidCurve: 1,
      askCurve: 1,
      skewTicksPerLot: skewPerLot,
      maxSkewTicks: 1_000_000,
      refillLotsPerSecond: 0,
      ttl: 1 hours,
      seq: seq,
      selfPriced: false
    });
    vm.prank(owner);
    book.updateSplines(u);
  }

  function testQuoteEqualsTakeAcrossMakersAndLevels() public {
    _update(carol, carolAcc, -10, 2);
    OnchainBook.TakeOrder memory o = _order(true, 2500, 2e18); // carol's 1000, alice's 1000, then a second region
    (Outcome memory q, uint makers) = _quote(o);
    assertEq(makers, 2);
    _assertSame(q, _takeOutcome(o), "buy across two makers and regions");

    o = _order(false, 1700, 0);
    (q,) = _quote(o);
    _assertSame(q, _takeOutcome(o), "sell");
  }

  /// @dev take settles carol, finds alice's allowance gone (switched off), and re-plans: the rest comes from carol's next
  ///      levels. quote must predict the re-plan, including carol's levels already consumed in the first round.
  function testQuoteFollowsTheReplanAfterAnAllowanceIsGone() public {
    _update(carol, carolAcc, -10, 2);
    _update(alice, aliceAcc, -5, 2);
    _revokeFuture(alice, aliceAcc);
    OnchainBook.TakeOrder memory o = _order(true, 2000, 2e18);
    (Outcome memory q, uint makers) = _quote(o);
    assertEq(makers, 1, "only carol settles");
    Outcome memory t = _takeOutcome(o);
    _assertSame(q, t, "re-plan");
    assertEq(t.filled, 2000 * LOT, "carol fills it all over two rounds");
  }

  /// @dev Same, with carol skewing on position: in take's second round carol's position has moved, so her mid has too.
  function testQuoteFollowsTheReplanWithSkew() public {
    _updateWithSkew(carol, carolAcc, -10, 2, 1);
    _update(alice, aliceAcc, -5, 2);
    _revokeFuture(alice, aliceAcc);
    OnchainBook.TakeOrder memory o = _order(true, 2000, 2e18);
    (Outcome memory q,) = _quote(o);
    _assertSame(q, _takeOutcome(o), "re-plan with skew");
  }

  function testFuzzQuoteEqualsTake(uint lots, uint limitTicks, bool isBuy, bool revokeAlice, int16 carolOffset) public {
    lots = bound(lots, 1, 6000);
    _update(carol, carolAcc, int32(int(bound(carolOffset, -200, 200))), 2);
    if (revokeAlice) _revokeFuture(alice, aliceAcc);
    uint limit = isBuy ? PRICE + bound(limitTicks, 0, 1000) * TICK : PRICE - bound(limitTicks, 0, 1000) * TICK;
    OnchainBook.TakeOrder memory o = _order(isBuy, lots, limit);

    try book.quote(o) returns (uint filled, uint avgPrice, uint fee, uint) {
      _assertSame(Outcome(filled, avgPrice, fee), _takeOutcome(o), "fuzz");
    } catch (bytes memory reason) {
      vm.prank(bob);
      vm.expectRevert(reason);
      book.take(o, "");
    }
  }

  function testAQuoteWithNoAccountPricesTheBook() public {
    OnchainBook.TakeOrder memory o = _order(true, 1500, 2e18);
    (Outcome memory withBob,) = _quote(o);
    o.takerAccountId = 0;
    (Outcome memory anon,) = _quote(o);
    _assertSame(anon, withBob, "no account");
  }

  function testQuoteRevertsAsTakeDoes() public {
    OnchainBook.TakeOrder memory o = _order(true, 1500, 2e18);

    o.maxFee = 1;
    vm.expectRevert(OnchainBook.OB_FeeTooHigh.selector);
    book.quote(o);

    o = _order(true, 1500, PRICE); // nothing at or under the index
    o.minFill = LOT;
    vm.expectRevert(OnchainBook.OB_BelowMinFill.selector);
    book.quote(o);

    o = _order(true, 1500, 2e18);
    o.deadline = uint64(block.timestamp - 1);
    vm.expectRevert(OnchainBook.OB_Expired.selector);
    book.quote(o);

    _revokeFuture(bob, bobAcc);
    o = _order(true, 1500, 2e18);
    vm.expectRevert(OnchainBook.OB_TakerAllowanceTooLow.selector);
    book.quote(o);
  }

  /// @dev Pegged splines quote only on fresh stored reports; a quote reads them as a take without reports would.
  function testAQuoteOnStaleReportsFillsNothingAsATakeWould() public {
    vm.warp(block.timestamp + 5);
    OnchainBook.TakeOrder memory o = _order(true, 1500, 2e18);
    o.deadline = uint64(block.timestamp);
    (Outcome memory q,) = _quote(o);
    assertEq(q.filled, 0);
    _assertSame(q, _takeOutcome(o), "stale");
  }

  /// @dev The tax is part of the quote at the caller's gas price.
  function testAQuoteIncludesThePriorityTaxAtTheCallersGasPrice() public {
    book.setPriorityTaxRate(1e9);
    vm.fee(1 gwei);
    vm.txGasPrice(3 gwei);
    OnchainBook.TakeOrder memory o = _order(true, 1500, 2e18);
    (Outcome memory q,) = _quote(o);
    _assertSame(q, _takeOutcome(o), "taxed");
    assertGt(q.fee, _fee(1500, PRICE + HALF_SPREAD * TICK) + 1, "the tax is in it");
  }
}
