// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CngnPerpLeverageFork} from "./CngnPerpLeverageFork.t.sol";

/**
 * Stage (B) of the leverage path: 5x on USDC margin (IM 20% / MM 12%) with the cNGN margin factor
 * lowered from 0.5 to 0.35. The same three questions as the 10x study, at these parameters:
 *
 *   1. SecurityModule loss with the whole long side on one USDC account at the OI cap, for
 *      5/10/25/40% single steps, at the auction's end and with the venue's keeper bidding.
 *   2. The on-chain worst case of a long-naira account on cNGN alone (the venue refuses the
 *      direction) at factors 0.35 and 0.30, stepped 10% and 25%.
 *   3. The hedged direction (long USD on cNGN): how far the naira can rally before a hedged account
 *      is liquidated, for the hedge ratios the factor allows, and whether the liquidation is
 *      solvent. This is what the hedge-mode limit in markets-service and the app should match.
 *
 * Numbers only. Requires BASE_RPC_URL.
 */
contract CngnPerpFiveXFork is CngnPerpLeverageFork {
  uint constant IM_5X = 0.2e18;
  uint constant MM_5X = 0.12e18;

  function testSecurityModuleLossAt5x() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);
    uint16[4] memory jumps = [uint16(500), 1_000, 2_500, 4_000];
    console2.log("=== IM 20%, MM 12%, USDC margin, whole long side at the cap");
    for (uint j; j < jumps.length; ++j) {
      uint snapshot = vm.snapshotState();
      CashStep memory r = _cashStep(jumps[j], IM_5X, MM_5X);
      vm.revertToState(snapshot);
      console2.log("jump bps:", jumps[j]);
      console2.log("  equity after ($, 18dp, signed):", r.equityAfter);
      console2.log("  insolvent auction?", r.insolvent);
      console2.log("  SM paid, auction to its end ($, 18dp):", r.smPaidAtEnd);
      console2.log("  SM paid, keeper bids once covered +2% ($, 18dp):", r.smPaidKeeper);
      console2.log("  keeper bid after (s):", r.keeperBidAfterSec);
    }
  }

  function testCngnLongNairaAt5x() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);
    srm.setPerpMarginRequirements(marketId, MM_5X, IM_5X);
    uint64[2] memory factors = [uint64(0.35e18), 0.3e18];
    uint16[2] memory steps = [uint16(1_000), 2_500];
    console2.log("=== IM 20%, MM 12%, long naira on cNGN alone, whole side at the cap");
    for (uint f; f < factors.length; ++f) {
      for (uint k; k < steps.length; ++k) {
        uint snapshot = vm.snapshotState();
        StepResult memory r = _cngnStep(factors[f], 1e18, steps[k], true);
        vm.revertToState(snapshot);
        console2.log("factor (18dp):", factors[f]);
        console2.log("  step bps:", steps[k]);
        console2.log("  cNGN posted for the 25M side (18dp):", r.collateral);
        console2.log("  equity after ($, 18dp, signed):", r.equityAfter);
        console2.log("  insolvent?", r.insolvent);
        console2.log("  SM paid, auction to its end ($, 18dp):", r.smPaid);
      }
    }
  }

  struct Hedge {
    uint ratioBps; // short cNGN notional / cNGN posted
    bool opens; // within IM at the ratio
    uint liquidatesAtRallyBps; // first 50 bps step of naira strength that takes MM below zero
    bool solventThere; // mark-to-market still positive at that step
    bool survives25PctFall;
  }

  /**
   * A treasury posts 10M cNGN and shorts naira (long USD) at several ratios. Naira weakening is the
   * hedge working; naira strengthening is where the haircut bites. Reports the rally that
   * liquidates each ratio at factors 0.35 and 0.30, at IM 20% / MM 12%.
   */
  function testHedgedHeadroomAt5x() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _deposit(bob, bobAcc, 500_000e6);
    uint64[2] memory factors = [uint64(0.35e18), 0.3e18];
    uint16[5] memory ratios = [uint16(10_000), 12_500, 15_000, 17_500, 20_000];
    console2.log("=== IM 20%, MM 12%, hedged: long USD on 10M cNGN posted");
    for (uint f; f < factors.length; ++f) {
      for (uint i; i < ratios.length; ++i) {
        uint snapshot = vm.snapshotState();
        Hedge memory h = _hedge(factors[f], ratios[i]);
        vm.revertToState(snapshot);
        console2.log("factor (18dp):", factors[f]);
        console2.log("  short cNGN per cNGN posted (bps):", h.ratioBps);
        console2.log("  opens within IM?", h.opens);
        if (h.opens) {
          console2.log("  liquidated at naira rally (bps):", h.liquidatesAtRallyBps);
          console2.log("  solvent at that point?", h.solventThere);
          console2.log("  survives a 25% naira fall?", h.survives25PctFall);
        }
      }
    }
  }

  function _hedge(uint factor, uint ratioBps) internal returns (Hedge memory h) {
    h.ratioBps = ratioBps;
    _enable(factor, 1e18);
    srm.setPerpMarginRequirements(marketId, MM_5X, IM_5X);
    _depositCngn(alice, aliceAcc, 10_000_000e6);
    // IM: C*F*s >= im*N, so the most the posted cNGN carries is N/C = F*s/im; above it the open reverts.
    h.opens = ratioBps <= factor * 1e18 / IM_5X * 10_000 / 1e18;
    if (!h.opens) return h;
    int size = int(10_000_000e18 * ratioBps / 10_000);
    _tradePerp(aliceAcc, bobAcc, size); // alice short cNGN = long USD
    assertGe(srm.getMargin(aliceAcc, true), 0, "opens within IM");

    uint fallSnapshot = vm.snapshotState();
    _setPrices(uint96(uint(INDEX_PRICE) * 75 / 100));
    h.survives25PctFall = srm.getMargin(aliceAcc, false) >= 0;
    vm.revertToState(fallSnapshot);

    for (uint bps = 50; bps <= 10_000; bps += 50) {
      _setPrices(uint96(uint(INDEX_PRICE) * (10_000 + bps) / 10_000));
      if (srm.getMargin(aliceAcc, false) < 0) {
        h.liquidatesAtRallyBps = bps;
        (, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
        h.solventThere = mtm > 0;
        return h;
      }
    }
  }
}
