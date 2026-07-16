// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./TestDeliverableFXManagerBase.t.sol";
import {IDeliverableFXFutureAsset} from "../../../../src/interfaces/IDeliverableFXFutureAsset.sol";

/**
 * Covers settlement-price VM accrual and the mark/settlement price bounds.
 *
 * setSettlementPrice accrues the final VM leg from the last mark to the
 * fixing (destination-price conversion, like setMarkPrice), is one-shot, and
 * freezes further marks. Bounds are opt-in via setMarkBounds: a max relative
 * price move per update and a max markTime age; 0 disables each.
 */
contract TestDeliverableFXMarkBounds is TestDeliverableFXManagerBase {
  function setUp() public override {
    super.setUp();
    _fundCash(aliceAcc, 1_000_000e18);
    _fundCash(bobAcc, 1_000_000e18);
  }

  /* ------------------- settlement VM accrual ------------------- */

  function testSettlementPriceAccruesFinalVMLeg() public {
    // bob long 1 contract, entered with mark at 1500
    _openFuturePosition(aliceAcc, bobAcc, 1e18);
    int bobCashBefore = _getCashBalance(bobAcc);

    // fixing lands at 1600 with no final mark pushed beforehand
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    IDeliverableFXFutureAsset.Series memory series = fxFuture.getSeries(fxSeries);
    // 100 cNGN/USDC * 10,000 USDC / 1600 = 625 USDC per contract
    assertEq(series.cumulativeVMPerContract, 625e18);
    assertEq(uint(series.markPrice), 1600e18);
    assertEq(uint(series.settlementPrice), 1600e18);

    manager.refreshDeliverableReservation(fxFuture, bobAcc, fxSeries);
    assertEq(_getCashBalance(bobAcc) - bobCashBefore, 625e18);
  }

  function testSettlementAfterFinalMarkAtFixingDoesNotDoubleAccrue() public {
    _openFuturePosition(aliceAcc, bobAcc, 1e18);

    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1600e18);
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    assertEq(fxFuture.getSeries(fxSeries).cumulativeVMPerContract, 625e18);
  }

  function testSettlementPriceIsOneShot() public {
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_SettlementPriceAlreadySet.selector);
    fxFuture.setSettlementPrice(fxSeries, 1650e18);
  }

  function testMarksAreBlockedAfterSettlement() public {
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_SettlementPriceAlreadySet.selector);
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1650e18);
  }

  /* ------------------------ price bounds ------------------------ */

  function testMarkDeviationBoundEnforced() public {
    fxFuture.setMarkBounds(0.05e18, 0);

    // 1500 -> 1576 is > 5%
    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_MarkDeviationExceeded.selector);
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1576e18);

    // exactly 5% passes
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1575e18);
    assertEq(uint(fxFuture.getSeries(fxSeries).markPrice), 1575e18);
  }

  function testSettlementDeviationBoundEnforced() public {
    fxFuture.setMarkBounds(0.05e18, 0);

    // 1500 -> 1600 is 6.7%: rejected as a single settlement print
    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_MarkDeviationExceeded.selector);
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    // a genuine gap is walked in via marks, then the fixing lands
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1575e18);
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 2), 1600e18);
    fxFuture.setSettlementPrice(fxSeries, 1600e18);

    assertTrue(fxFuture.getSeries(fxSeries).settlementPriceSet);
  }

  function testStaleMarkRejected() public {
    fxFuture.setMarkBounds(0, 300);

    vm.warp(block.timestamp + 1000);

    // markTime 400s old with a 300s bound
    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_StaleMark.selector);
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp - 400), 1510e18);

    // 100s old passes
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp - 100), 1510e18);
    assertEq(uint(fxFuture.getSeries(fxSeries).markPrice), 1510e18);
  }

  function testBoundsAreDisabledByDefault() public {
    // no bounds set: a 20% jump and an hour-old markTime are both accepted
    vm.warp(block.timestamp + 3600);
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp - 3599), 1800e18);
    assertEq(uint(fxFuture.getSeries(fxSeries).markPrice), 1800e18);
  }

  function testSetMarkBoundsOnlyOwner() public {
    vm.prank(alice);
    vm.expectRevert();
    fxFuture.setMarkBounds(0.05e18, 300);
  }
}
