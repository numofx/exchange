// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./TestDeliverableFXManagerBase.t.sol";

/**
 * Covers the _blendVM paths in DeliverableFXFutureAsset: trades carrying a
 * trade price in assetData measure PnL from the actual trade price rather
 * than the last mark.
 *
 * End-to-end semantics: _blendVM defers the trade-vs-mark offset into the
 * account's baseline, but the manager's post-trade hook settles all VM
 * immediately, so every transfer cash-settles that offset on the spot and
 * leaves the baseline equal to the series' cumulative VM. A trade at a price
 * above mark charges the buyer (and credits the seller) the offset at trade
 * time; subsequent mark moves then accrue from the mark as usual.
 *
 * Series: base = USDC, quote = cNGN, contractSizeBase = 10,000 USDC,
 * initial mark 1500 cNGN/USDC. All VM figures are USDC (1e18), each price
 * increment converted at its destination price — same convention as
 * setMarkPrice accruals, so marking to the trade price nets to exactly zero.
 */
contract TestDeliverableFXVMBlend is TestDeliverableFXManagerBase {
  int internal constant SIZE = 10_000e18;
  uint64 internal markTimeOffset;

  function setUp() public override {
    super.setUp();
    _fundCash(aliceAcc, 1_000_000e18);
    _fundCash(bobAcc, 1_000_000e18);
  }

  function _transferAtPrice(uint fromAcc, uint toAcc, int amount, uint tradePrice) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: fromAcc,
        toAcc: toAcc,
        asset: fxFuture,
        subId: fxSeries,
        amount: amount,
        assetData: bytes32(tradePrice)
      }),
      ""
    );
  }

  function _mark(uint price) internal {
    markTimeOffset += 1;
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp) + markTimeOffset, price);
  }

  // one price increment converted at its destination price, per contract
  function _accrual(uint fromPrice, uint toPrice) internal pure returns (int) {
    return (int(toPrice) - int(fromPrice)) * SIZE / int(toPrice);
  }

  function _settle(uint acc) internal {
    manager.refreshDeliverableReservation(fxFuture, acc, fxSeries);
  }

  /* ---------------------------------------------------------------- *
   *                    open from zero (preBalance == 0)               *
   * ---------------------------------------------------------------- */

  function testOpenAboveMarkChargesBuyerTheOffsetAtTradeTime() public {
    int aliceCashBefore = _getCashBalance(aliceAcc);
    int bobCashBefore = _getCashBalance(bobAcc);

    // alice long 1 @ 1530 while mark is 1500: she pays the 1500 -> 1530 leg
    // now, bob receives it; the post-trade sync leaves both baselines at the
    // series cumulative VM and nothing pending
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1530e18);

    int offset = _accrual(1500e18, 1530e18);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, -offset);
    assertEq(_getCashBalance(bobAcc) - bobCashBefore, offset);
    assertEq(fxFuture.accountLastCumulativeVM(aliceAcc, fxSeries), 0);
    assertEq(fxFuture.accountLastCumulativeVM(bobAcc, fxSeries), 0);
    assertEq(fxFuture.accountCashToSettle(aliceAcc, fxSeries), 0);
    assertEq(fxFuture.accountCashToSettle(bobAcc, fxSeries), 0);
  }

  function testMarkingToTradePriceNetsToZero() public {
    int aliceCashBefore = _getCashBalance(aliceAcc);
    int bobCashBefore = _getCashBalance(bobAcc);

    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1530e18);

    // mark converges to the trade price: the accrual credited back to alice
    // exactly cancels the offset she paid at trade time
    _mark(1530e18);
    _settle(aliceAcc);
    _settle(bobAcc);

    assertEq(_getCashBalance(aliceAcc), aliceCashBefore);
    assertEq(_getCashBalance(bobAcc), bobCashBefore);
  }

  function testLongPnLMeasuresFromTradePriceNotMark() public {
    int aliceCashBefore = _getCashBalance(aliceAcc);

    // alice buys at 1530 with mark still 1500; mark then moves to 1600
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1530e18);
    _mark(1600e18);
    _settle(aliceAcc);

    // alice nets only the 1530 -> 1600 leg, not 1500 -> 1600
    int expected = _accrual(1500e18, 1600e18) - _accrual(1500e18, 1530e18);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, expected);
  }

  /* ---------------------------------------------------------------- *
   *              add to position (same sign, exposure up)             *
   * ---------------------------------------------------------------- */

  function testIncreaseRealizesOldAccrualAndChargesNewEntryOffset() public {
    // alice long 1 @ mark
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1500e18);

    _mark(1600e18);
    int latest = _accrual(1500e18, 1600e18); // 625e18

    // alice adds 1 more @ 1650 while mark is 1600: the trade settles the
    // accrued VM on her original contract and charges the 1600 -> 1650
    // offset on the new one
    int aliceCashBefore = _getCashBalance(aliceAcc);
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1650e18);

    // baseline blending divides by the position and may truncate 1 wei
    assertApproxEqAbs(_getCashBalance(aliceAcc) - aliceCashBefore, latest - _accrual(1600e18, 1650e18), 1);
    assertEq(fxFuture.accountLastCumulativeVM(aliceAcc, fxSeries), latest);
    assertEq(fxFuture.accountCashToSettle(aliceAcc, fxSeries), 0);
  }

  function testIncreasePreservesTotalPnLAcrossBothEntries() public {
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1500e18);
    int aliceCashBefore = _getCashBalance(aliceAcc);

    _mark(1600e18);
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1650e18);
    _mark(1650e18);
    _settle(aliceAcc);

    // contract 1: entered at 1500, marked to 1650 -> full accrued path
    // contract 2: entered at 1650, marked to 1650 -> zero
    int fullPath = _accrual(1500e18, 1600e18) + _accrual(1600e18, 1650e18);
    // baseline blending divides by the position and may truncate 1 wei
    assertApproxEqAbs(_getCashBalance(aliceAcc) - aliceCashBefore, fullPath, 1);
  }

  /* ---------------------------------------------------------------- *
   *             reduce position (same sign, exposure down)            *
   * ---------------------------------------------------------------- */

  function testReduceRealizesTradePriceVMOnClosedPortion() public {
    // alice long 2 @ mark
    _transferAtPrice(bobAcc, aliceAcc, 2e18, 1500e18);

    _mark(1600e18);
    int latest = _accrual(1500e18, 1600e18);

    // alice sells 1 @ 1650 while mark is 1600: both contracts' accrued VM
    // settles, plus the 1600 -> 1650 leg on the contract she closed
    int aliceCashBefore = _getCashBalance(aliceAcc);
    _transferAtPrice(aliceAcc, bobAcc, 1e18, 1650e18);

    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, 2 * latest + _accrual(1600e18, 1650e18));
    assertEq(subAccounts.getBalance(aliceAcc, fxFuture, fxSeries), 1e18);
    assertEq(fxFuture.accountLastCumulativeVM(aliceAcc, fxSeries), latest);
    assertEq(fxFuture.accountCashToSettle(aliceAcc, fxSeries), 0);

    // the remaining contract keeps accruing from the mark as usual
    aliceCashBefore = _getCashBalance(aliceAcc);
    _mark(1700e18);
    _settle(aliceAcc);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, _accrual(1600e18, 1700e18));
  }

  /* ---------------------------------------------------------------- *
   *                    reverse position (sign flip)                   *
   * ---------------------------------------------------------------- */

  function testReversalClosesOldPositionAtTradePriceAndOpensNew() public {
    // alice long 1 @ mark, then sells 2 @ 1650 -> short 1
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1500e18);

    _mark(1600e18);
    int latest = _accrual(1500e18, 1600e18);
    int offset = _accrual(1600e18, 1650e18);

    // at trade: the old long realizes its full path to 1650, and the new
    // short (sold above mark) is credited the 1600 -> 1650 offset
    int aliceCashBefore = _getCashBalance(aliceAcc);
    _transferAtPrice(aliceAcc, bobAcc, 2e18, 1650e18);

    assertEq(subAccounts.getBalance(aliceAcc, fxFuture, fxSeries), -1e18);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, latest + 2 * offset);
    assertEq(fxFuture.accountLastCumulativeVM(aliceAcc, fxSeries), latest);
    assertEq(fxFuture.accountCashToSettle(aliceAcc, fxSeries), 0);

    // mark converging to the reversal price claws back one offset, leaving
    // alice with exactly the old long's path to 1650 and the short flat
    _mark(1650e18);
    _settle(aliceAcc);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, latest + offset);

    // a further rally is now a loss on exactly 1 short contract
    aliceCashBefore = _getCashBalance(aliceAcc);
    _mark(1700e18);
    _settle(aliceAcc);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, -_accrual(1650e18, 1700e18));
  }

  /* ---------------------------------------------------------------- *
   *                zero-sum and no-blend (assetData == 0)             *
   * ---------------------------------------------------------------- */

  function testBlendedVMIsZeroSumBetweenCounterparties() public {
    int aliceCashBefore = _getCashBalance(aliceAcc);
    int bobCashBefore = _getCashBalance(bobAcc);

    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1530e18);
    _mark(1600e18);
    _transferAtPrice(bobAcc, aliceAcc, 1e18, 1650e18);
    _mark(1650e18);
    _transferAtPrice(aliceAcc, bobAcc, 2e18, 1620e18);
    _mark(1700e18);

    _settle(aliceAcc);
    _settle(bobAcc);

    int aliceDelta = _getCashBalance(aliceAcc) - aliceCashBefore;
    int bobDelta = _getCashBalance(bobAcc) - bobCashBefore;
    assertEq(aliceDelta + bobDelta, 0, "blended VM must be zero-sum");
    assertTrue(aliceDelta != 0, "trade sequence should move cash");
  }

  function testZeroTradePriceTradesAtTheMark() public {
    // a transfer without assetData skips blending; the pre-trade sync
    // fast-forwards the opener's baseline, so it behaves as a trade at the
    // current mark: no windfall from previously accrued series VM
    _mark(1600e18);
    int latest = _accrual(1500e18, 1600e18);

    int aliceCashBefore = _getCashBalance(aliceAcc);
    _openFuturePosition(bobAcc, aliceAcc, 1e18); // assetData: ""

    assertEq(_getCashBalance(aliceAcc), aliceCashBefore);
    assertEq(fxFuture.accountLastCumulativeVM(aliceAcc, fxSeries), latest);
    assertEq(fxFuture.accountCashToSettle(aliceAcc, fxSeries), 0);

    // and PnL accrues only from the mark at entry onward
    _mark(1700e18);
    _settle(aliceAcc);
    assertEq(_getCashBalance(aliceAcc) - aliceCashBefore, _accrual(1600e18, 1700e18));
  }
}
