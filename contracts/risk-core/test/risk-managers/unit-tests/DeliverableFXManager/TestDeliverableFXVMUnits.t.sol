// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./TestDeliverableFXManagerBase.t.sol";

/**
 * Regression test for VM denomination.
 *
 * Series: base = USDC, quote = cNGN, mark price in cNGN-per-USDC (1e18),
 * contractSizeBase = 10,000 USDC. Cash asset is USDC-denominated.
 *
 * VM must be credited into cash as the USDC value of the quote-denominated
 * PnL, converted at the mark it accrued at. A 1 cNGN/USDC mark move on a
 * 1-contract position is 10,000 cNGN ~= 6.66 USDC at 1501 cNGN/USDC.
 * The original bug credited the raw cNGN figure (10,000) into USDC cash,
 * a ~1500x overstatement.
 */
contract TestDeliverableFXVMUnits is TestDeliverableFXManagerBase {
  function testVMCashDenominationMatchesQuoteValue() public {
    _fundCash(aliceAcc, 100_000e18);
    _fundCash(bobAcc, 100_000e18);

    // alice long 1 contract (10,000 USDC notional), bob short
    _openFuturePosition(bobAcc, aliceAcc, 1e18);

    int aliceCashBefore = _getCashBalance(aliceAcc);
    int bobCashBefore = _getCashBalance(bobAcc);

    // mark moves by 1 cNGN per USDC: 1500 -> 1501
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1501e18);

    // public entry that settles VM into cash for each account
    manager.refreshDeliverableReservation(fxFuture, aliceAcc, fxSeries);
    manager.refreshDeliverableReservation(fxFuture, bobAcc, fxSeries);

    int aliceDelta = _getCashBalance(aliceAcc) - aliceCashBefore;
    int bobDelta = _getCashBalance(bobAcc) - bobCashBefore;

    // real PnL: 1 contract * 10,000 USDC * 1 cNGN/USDC = 10,000 cNGN,
    // worth 10,000 / 1501 USDC at the mark it accrued at
    int expectedVMInUsdc = (int(1e18) * 10_000e18) / 1501e18; // ~6.66e18

    assertEq(aliceDelta + bobDelta, 0, "VM should be zero-sum");
    assertEq(aliceDelta, expectedVMInUsdc, "long VM credit should be the USDC value of the quote PnL");
    assertEq(bobDelta, -expectedVMInUsdc, "short VM debit should be the USDC value of the quote PnL");
  }

  function testMultiStepVMAccruesEachIncrementAtItsOwnMark() public {
    _fundCash(aliceAcc, 100_000e18);
    _fundCash(bobAcc, 100_000e18);

    _openFuturePosition(bobAcc, aliceAcc, 1e18);
    int aliceCashBefore = _getCashBalance(aliceAcc);

    // 1500 -> 1600: +100 * 10,000 / 1600 = +625 USDC
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 1600e18);
    // 1600 -> 1550: -50 * 10,000 / 1550 USDC
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 2), 1550e18);

    manager.refreshDeliverableReservation(fxFuture, aliceAcc, fxSeries);

    int expected = 625e18 + (int(-50e18) * 10_000e18) / 1550e18;
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, expected);
  }
}
