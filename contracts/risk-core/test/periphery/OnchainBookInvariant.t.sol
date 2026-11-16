// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBook.t.sol";

/**
 * Drives the book with random takes, spline updates, index moves with time passing, and pokes, and checks after each
 * action what must always hold (docs/eurc-usdc-futures-spec.md, B11 invariants). Per-take properties are checked in
 * the handler and recorded as a violation; the invariant functions read the record and the global balances.
 */
contract OnchainBookHandler is Test {
  OnchainBookInvariant immutable t;
  OnchainBook immutable book;
  uint immutable mkt;

  uint public takes;
  uint public fills;
  string public violation;

  uint64[2] public lastSeq;

  constructor(OnchainBookInvariant t_) {
    t = t_;
    book = t_.bookRef();
    mkt = t_.mktRef();
    lastSeq = [uint64(1), uint64(1)];
  }

  function _fail(string memory why) internal {
    if (bytes(violation).length == 0) violation = why;
  }

  struct Ctx {
    bool isBuy;
    uint limit;
    uint maxFee;
    bool fresh;
    uint[] makers;
    bool[] live;
  }

  function take(bool isBuy, uint lots, uint limitTicks, uint maxFee, bool attach, uint attachBps) external {
    Ctx memory c;
    c.isBuy = isBuy;
    c.maxFee = bound(maxFee, 0, 10e18);
    limitTicks = bound(limitTicks, 0, 40_000);
    (uint idx,) = t.indexRef().getSpot();
    c.limit = isBuy ? idx + limitTicks * 1e12 : (idx > limitTicks * 1e12 ? idx - limitTicks * 1e12 : 0);

    c.fresh = t.isFresh();
    bytes memory report = "";
    if (attach) {
      report = t.reportsAt(idx * (10_000 + bound(attachBps, 0, 200) - 100) / 10_000);
      c.fresh = true;
    }
    // each maker's spline state before the take
    c.makers = book.makers(mkt);
    c.live = new bool[](c.makers.length);
    for (uint i; i < c.makers.length; ++i) {
      (,,,,,,, uint40 updatedAt, uint32 ttl,, bool active,) = book.splines(mkt, c.makers[i]);
      c.live[i] = active && block.timestamp <= uint(updatedAt) + ttl;
    }

    OnchainBook.TakeOrder memory o = t.orderRef(isBuy, bound(lots, 1, 6000), c.limit);
    o.maxFee = c.maxFee;
    vm.recordLogs();
    vm.prank(t.bobRef());
    try book.take(o, report) returns (uint filled, uint) {
      takes++;
      if (!c.fresh && filled > 0) _fail("fill against a stale price");
      _checkLogs(c, vm.getRecordedLogs());
    } catch {
      vm.getRecordedLogs();
    }
  }

  function _checkLogs(Ctx memory c, Vm.Log[] memory logs) internal {
    (uint idx,) = t.indexRef().getSpot();
    uint band = t.futureRef().markIndexBand(uint64(t.expiryRef()));
    for (uint i; i < logs.length; ++i) {
      if (logs[i].emitter != address(book)) continue;
      if (logs[i].topics[0] == OnchainBook.Fill.selector) {
        fills++;
        uint maker = uint(logs[i].topics[3]);
        (, uint amount, uint price,) = abi.decode(logs[i].data, (bool, uint, uint, uint));
        if (amount == 0) _fail("empty fill");
        if (c.isBuy ? price > c.limit : price < c.limit) _fail("fill past the limit");
        uint diff = price > idx ? price - idx : idx - price;
        if (diff * 1e18 > idx * band) _fail("fill outside the index band");
        for (uint j; j < c.makers.length; ++j) {
          if (c.makers[j] == maker && !c.live[j]) _fail("fill against an expired or inactive spline");
        }
      }
      if (logs[i].topics[0] == OnchainBook.TakeExecuted.selector) {
        (,,, uint fee) = abi.decode(logs[i].data, (bool, uint, uint, uint));
        if (fee > c.maxFee) _fail("fee above maxFee");
      }
    }
  }

  function update(uint who, int32 offset, uint32 hs, uint32 skew, uint32 refill, uint seqBump) external {
    who = bound(who, 0, 1);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    uint64 seq = lastSeq[who] + uint64(bound(seqBump, 1, 3));
    u[0] = OnchainBook.SplineUpdate({
      marketId: mkt,
      accountId: t.makerAcc(who),
      offsetTicks: int32(bound(offset, -3000, 3000)),
      halfSpreadTicks: uint32(bound(hs, 0, 500)),
      bidCurve: 1,
      askCurve: 1,
      skewTicksPerLot: uint32(bound(skew, 0, 2)),
      maxSkewTicks: 200,
      refillLotsPerSecond: uint32(bound(refill, 0, 500)),
      ttl: 1 hours,
      seq: seq
    });
    vm.prank(t.makerOwner(who));
    try book.updateSplines(u) {
      lastSeq[who] = seq;
    } catch {}
  }

  /// @dev An update that must be refused: seq not above the stored one.
  function staleUpdate(uint who) external {
    who = bound(who, 0, 1);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(mkt, t.makerAcc(who), 0, 100, 1, 1, 0, 0, 0, 1 hours, lastSeq[who]);
    vm.prank(t.makerOwner(who));
    try book.updateSplines(u) {
      _fail("an update with seq not above the stored one landed");
    } catch {}
  }

  /// @dev Short moves, so the index is often between the take age (1 s) and the index's own limit (60 s): the window
  ///      where only the book's freshness check stands between a taker and a stale price.
  function move(uint dt, uint bps, bool post) external {
    vm.warp(block.timestamp + bound(dt, 0, 120));
    if (post) t.postAt(1.1e18 * (10_000 + bound(bps, 0, 400) - 200) / 10_000);
  }

  /// @dev Long enough for splines to lapse (ttl 1 h).
  function longWait(uint dt) external {
    vm.warp(block.timestamp + bound(dt, 0, 90 minutes));
    t.postAt(1.1e18);
  }

  function poke(uint who) external {
    book.poke(mkt, t.makerAcc(bound(who, 0, 1)));
  }
}

contract OnchainBookInvariant is OnchainBookBase {
  OnchainBookHandler handler;
  int cashTotal;

  function setUp() public override {
    super.setUp();
    handler = new OnchainBookHandler(this);
    cashTotal = _cashTotal();
    targetContract(address(handler));
  }

  // ---- what the handler reads ----
  function bookRef() external view returns (OnchainBook) {
    return book;
  }

  function mktRef() external view returns (uint) {
    return mkt;
  }

  function indexRef() external view returns (EurcIndexFeed) {
    return index;
  }

  function futureRef() external view returns (FutureAsset) {
    return future;
  }

  function expiryRef() external view returns (uint) {
    return expiry;
  }

  function bobRef() external view returns (address) {
    return bob;
  }

  function makerAcc(uint i) external view returns (uint) {
    return i == 0 ? aliceAcc : carolAcc;
  }

  function makerOwner(uint i) external view returns (address) {
    return i == 0 ? alice : carol;
  }

  function orderRef(bool isBuy, uint lots, uint limit) external view returns (OnchainBook.TakeOrder memory) {
    return _order(isBuy, lots, limit);
  }

  function reportsAt(uint price) external view returns (bytes memory) {
    return _reports(price);
  }

  function postAt(uint price) external {
    _postIndex(price);
  }

  function isFresh() external view returns (bool) {
    (, uint64 a) = adapter.latest(EURC);
    (, uint64 b) = adapter.latest(USDC);
    uint oldest = a < b ? a : b;
    return block.timestamp <= oldest + 1;
  }

  function _cashTotal() internal view returns (int) {
    return _cash(aliceAcc) + _cash(carolAcc) + _cash(bobAcc) + _cash(feeAcc) + _cash(engine.accId());
  }

  // ---- invariants ----

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 40
  function invariant_noPerTakeViolation() public view {
    assertEq(handler.violation(), "");
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 40
  function invariant_netPositionZero() public view {
    assertEq(_pos(aliceAcc) + _pos(carolAcc) + _pos(bobAcc), 0);
  }

  /// Fees go to the recipient and VM moves through the engine's pool: the sum is unchanged.
  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 40
  function invariant_cashConserved() public view {
    assertEq(_cashTotal(), cashTotal);
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 40
  function invariant_seqNeverDecreasesAndNoSplineCrossed() public view {
    for (uint i; i < 2; ++i) {
      uint acc = i == 0 ? aliceAcc : carolAcc;
      (, uint32 hs, uint16 bidCurve, uint16 askCurve,,,,,, uint64 seq,,) = book.splines(mkt, acc);
      assertEq(seq, handler.lastSeq(i), "stored seq is the last accepted one");
      address owner = i == 0 ? alice : carol;
      uint bid0 = book.curve(owner, bidCurve)[0].offsetTicks;
      uint ask0 = book.curve(owner, askCurve)[0].offsetTicks;
      assertGt(2 * uint(hs) + bid0 + ask0, 0, "best bid below best ask");
    }
  }

  /// Not an invariant: proves the handler's take lands fills that its checks then read, so the per-take invariant
  /// is not vacuous.
  function testTheHandlerLandsFillsItChecks() public {
    handler.take(true, 500, 40_000, 10e18, false, 0);
    handler.take(false, 500, 40_000, 10e18, true, 150);
    assertEq(handler.takes(), 2);
    assertGe(handler.fills(), 2);
    assertEq(handler.violation(), "");
  }
}
