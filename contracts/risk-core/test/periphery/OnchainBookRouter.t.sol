// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBook.t.sol";
import {OnchainBookRouter, IRouterCash} from "../../src/periphery/OnchainBookRouter.sol";

/// @dev The router (spec C4.3) on the book's fixture. MockCash does not enforce CashAsset's owner-only withdraw; the fork
///      suite (OnchainBookRouterFork) proves the round trip against the real CashAsset.
contract OnchainBookRouterTest is OnchainBookBase {
  OnchainBookRouter router;

  function setUp() public override {
    super.setUp();
    router = new OnchainBookRouter(book, IRouterCash(address(cash)));
    vm.prank(bob);
    subAccounts.setApprovalForAll(address(router), true);
    usdc.mint(bob, 1_000e18);
    vm.prank(bob);
    usdc.approve(address(router), type(uint).max);
  }

  function _route(uint dep, uint lots, bool isBuy, bool reduceOnly, uint wd)
    internal
    view
    returns (OnchainBookRouter.Route memory r)
  {
    r.accountId = bobAcc;
    r.deposit = dep;
    r.take = _order(isBuy, lots, isBuy ? 2e18 : 0);
    r.reduceOnly = reduceOnly;
    r.withdraw = wd;
  }

  function _run(OnchainBookRouter.Route memory r) internal returns (uint filled, uint avg) {
    vm.prank(bob);
    return router.route(r);
  }

  function testDepositTakeAndWithdrawInOneCall() public {
    int cashBefore = _cash(bobAcc);
    uint usdcBefore = usdc.balanceOf(bob);
    OnchainBookRouter.Route memory r = _route(500e18, 300, true, false, 200e18);

    vm.expectEmit(true, true, false, false, address(router));
    emit OnchainBookRouter.Routed(bobAcc, bob, 0, 0, 0, 0, address(0));
    (uint filled, uint avg) = _run(r);

    assertEq(filled, 300 * LOT);
    assertEq(avg, PRICE + HALF_SPREAD * TICK);
    assertEq(_pos(bobAcc), int(300 * LOT));
    uint fee = _fee(300, avg);
    uint markLoss = 300 * LOT * 1_000 * (avg - PRICE) / 1e18; // bought over the mark: the future realizes it into cash
    assertEq(
      _cash(bobAcc), cashBefore + 500e18 - 200e18 - int(fee) - int(markLoss), "deposit in; fee, mark and withdrawal out"
    );
    assertEq(usdc.balanceOf(bob), usdcBefore - 500e18 + 200e18, "withdrawal to the caller");
    // The router holds nothing afterwards, and the account is the owner's again with its allowances intact.
    assertEq(usdc.balanceOf(address(router)), 0);
    assertEq(subAccounts.ownerOf(bobAcc), bob);
    assertEq(subAccounts.balanceOf(address(router)), 0);
    (filled,) = _take(_order(true, 10, 2e18));
    assertEq(filled, 10 * LOT, "bob's own book permissions survive the round trip");
  }

  function testEachStepIsOptional() public {
    OnchainBookRouter.Route memory r = _route(100e18, 0, true, false, 0);
    int before = _cash(bobAcc);
    (uint filled,) = _run(r);
    assertEq(filled, 0);
    assertEq(_cash(bobAcc), before + 100e18, "deposit only");

    r = _route(0, 0, true, false, 40e18);
    r.recipient = address(0xdead);
    _run(r);
    assertEq(usdc.balanceOf(address(0xdead)), 40e18, "withdraw only, to a named recipient");
    assertEq(subAccounts.ownerOf(bobAcc), bob);

    r = _route(0, 100, false, false, 0);
    (filled,) = _run(r);
    assertEq(filled, 100 * LOT, "take only");
  }

  function testOnlyTheOwnerRoutes() public {
    // carol is an operator for bob too: still not bob
    vm.prank(bob);
    subAccounts.setApprovalForAll(carol, true);
    OnchainBookRouter.Route memory r = _route(0, 0, true, false, 1e18);
    r.recipient = carol;
    vm.prank(carol);
    vm.expectRevert(OnchainBookRouter.R_NotOwner.selector);
    router.route(r);
  }

  function testTheTakeMustBeOnTheRoutedAccount() public {
    OnchainBookRouter.Route memory r = _route(0, 10, true, false, 0);
    r.take.takerAccountId = aliceAcc;
    vm.prank(bob);
    vm.expectRevert(OnchainBookRouter.R_WrongAccount.selector);
    router.route(r);
  }

  function testWithoutTheOwnersApprovalNothingMoves() public {
    vm.prank(bob);
    subAccounts.setApprovalForAll(address(router), false);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_NotAuthorized.selector);
    router.route(_route(0, 10, true, false, 0));

    vm.prank(bob);
    vm.expectRevert(); // ERC721: caller is not token owner or approved
    router.route(_route(0, 0, true, false, 1e18));
  }

  function testReduceOnlyCutsTheTakeToThePosition() public {
    _run(_route(0, 300, true, false, 0)); // long 300
    (uint filled,) = _run(_route(0, 500, false, true, 0));
    assertEq(filled, 300 * LOT, "cut to the position");
    assertEq(_pos(bobAcc), 0);

    _run(_route(0, 200, false, false, 0)); // short 200
    (filled,) = _run(_route(0, 50, true, true, 0));
    assertEq(filled, 50 * LOT, "under the position: as asked");
    assertEq(_pos(bobAcc), -int(150 * LOT));
  }

  function testReduceOnlyRefusesATakeThatWouldNotReduce() public {
    vm.prank(bob);
    vm.expectRevert(OnchainBookRouter.R_NotReducing.selector);
    router.route(_route(0, 10, true, true, 0)); // flat

    _run(_route(0, 100, true, false, 0)); // long
    vm.prank(bob);
    vm.expectRevert(OnchainBookRouter.R_NotReducing.selector);
    router.route(_route(0, 10, true, true, 0)); // buying more
  }

  /// A per-account approval works for one withdrawal: ERC721 clears it when the account moves. The router documents
  /// setApprovalForAll for withdrawals.
  function testAPerAccountApprovalIsClearedByAWithdrawal() public {
    vm.startPrank(bob);
    subAccounts.setApprovalForAll(address(router), false);
    subAccounts.approve(address(router), bobAcc);
    router.route(_route(0, 0, true, false, 1e18));
    assertEq(subAccounts.getApproved(bobAcc), address(0), "cleared by the transfer");
    vm.expectRevert();
    router.route(_route(0, 0, true, false, 1e18));
    vm.stopPrank();
  }

  function testTheRouterMustUseTheBooksCash() public {
    MockCash other = new MockCash(usdc, subAccounts);
    vm.expectRevert(OnchainBookRouter.R_WrongCash.selector);
    new OnchainBookRouter(book, IRouterCash(address(other)));
  }

  /// A take's own checks hold through the router: an over-tight minFill reverts the whole route, deposit included.
  function testAFailedTakeUndoesTheDeposit() public {
    OnchainBookRouter.Route memory r = _route(100e18, 10, true, false, 0);
    r.take.minFill = 20 * LOT;
    r.take.amount = 10 * LOT;
    int before = _cash(bobAcc);
    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_BelowMinFill.selector);
    router.route(r);
    assertEq(_cash(bobAcc), before);
  }
}
