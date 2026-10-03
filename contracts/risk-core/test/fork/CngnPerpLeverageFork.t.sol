// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CngnPerpCollateralFork} from "./CngnPerpCollateralFork.t.sol";

/**
 * The leverage study: what raising USDCcNGN-PERP's maximum leverage from 3x (IM 33.3% / MM 20%) to
 * 10x on USDC margin (IM 10%) would cost, before any parameter changes. cNGN margin at the 0.5
 * factor is then 5x effective. Numbers only; nothing here proposes anything.
 *
 *   1. SecurityModule loss at the full OI cap for 5/10/25/40% single steps at IM 10%, for two
 *      candidate MMs, both at the auction's end (the ceiling) and with the keeper bidding as soon
 *      as the payout covers the deficit +2% (what the venue's keeper does).
 *   2. The on-chain worst case of a long-naira account on cNGN at the new IM (the venue refuses the
 *      direction; a directly-created account can still do it): which cNGN factor keeps it solvent
 *      through 10% and 25%, and what the SecurityModule pays otherwise.
 *
 * Requires BASE_RPC_URL.
 */
contract CngnPerpLeverageFork is CngnPerpCollateralFork {
  uint constant IM_10X = 0.1e18;

  struct CashStep {
    int equityAfter;
    uint smPaidAtEnd;
    uint smPaidKeeper;
    uint keeperBidAfterSec;
    bool insolvent;
  }

  function testSecurityModuleLossAt10x() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);
    uint64[2] memory mms = [uint64(0.05e18), 0.065e18];
    uint16[4] memory jumps = [uint16(500), 1_000, 2_500, 4_000];
    for (uint m; m < mms.length; ++m) {
      console2.log("=== IM 10%, MM (18dp):", mms[m]);
      for (uint j; j < jumps.length; ++j) {
        uint snapshot = vm.snapshotState();
        CashStep memory r = _cashStep(jumps[j], IM_10X, mms[m]);
        vm.revertToState(snapshot);
        console2.log("jump bps:", jumps[j]);
        console2.log("  equity after ($, 18dp, signed):", r.equityAfter);
        console2.log("  insolvent auction?", r.insolvent);
        console2.log("  SM paid, auction to its end ($, 18dp):", r.smPaidAtEnd);
        console2.log("  SM paid, keeper bids once covered +2% ($, 18dp):", r.smPaidKeeper);
        console2.log("  keeper bid after (s):", r.keeperBidAfterSec);
      }
    }
  }

  /// The whole long side on one USDC-margined account at IM `im`, walked to MM `mm`, stepped down
  /// `jumpBps`, then liquidated two ways from the same state.
  function _cashStep(uint jumpBps, uint im, uint mm) internal returns (CashStep memory r) {
    srm.setPerpMarginRequirements(marketId, mm, im);
    uint n = uint(CAP_SIDE);
    uint deposit = (n * INDEX_PRICE / 1e18) * im / 1e18 / 1e12 + 1e6; // USDC 6dp, +$1
    _deposit(alice, aliceAcc, deposit);
    _deposit(bob, bobAcc, 100_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);
    _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
    assertGe(srm.getMargin(aliceAcc, true), 0, "opens within IM");

    // Equity D + N(p - p0) meets mm*N*p at p = (N*p0 - D) / (N*(1 - mm)); sit 5bps above it.
    uint d = deposit * 1e12;
    uint atMM = (n * INDEX_PRICE / 1e18 - d) * 1e18 / (n * (1e18 - mm) / 1e18);
    uint96 preJump = uint96(atMM * 10_005 / 10_000);
    _setPrices(preJump);
    assertGe(srm.getMargin(aliceAcc, false), 0, "sits above MM");
    uint96 postJump = uint96(uint(preJump) * (10_000 - jumpBps) / 10_000);
    _setPrices(postJump);
    (, r.equityAfter) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);

    uint smAcc = securityModule.accountId();
    uint branch = vm.snapshotState();
    // (a) the ceiling: the auction runs to its last second.
    int smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    r.insolvent = auction.getAuction(aliceAcc).insolvent;
    if (r.insolvent) {
      vm.warp(block.timestamp + auction.getAuctionParams().insolventAuctionLength);
      _setPrices(postJump);
      vm.prank(charlie);
      auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    } else {
      vm.warp(block.timestamp + auction.getAuctionParams().fastAuctionLength);
      _setPrices(postJump);
      vm.prank(charlie);
      auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    }
    r.smPaidAtEnd = _cash(smAcc) < smBefore ? uint(smBefore - _cash(smAcc)) : 0;
    vm.revertToState(branch);

    // (b) the venue's keeper: bids the first minute the insolvent payout covers the deficit +2%.
    smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    if (auction.getAuction(aliceAcc).insolvent) {
      int wanted = -r.equityAfter * 102 / 100;
      uint started = block.timestamp;
      uint length = auction.getAuctionParams().insolventAuctionLength;
      while (true) {
        _setPrices(postJump);
        if (-auction.getCurrentBidPrice(aliceAcc) >= wanted || block.timestamp - started >= length) break;
        vm.warp(block.timestamp + 59);
      }
      r.keeperBidAfterSec = block.timestamp - started;
      vm.prank(charlie);
      auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
      r.smPaidKeeper = _cash(smAcc) < smBefore ? uint(smBefore - _cash(smAcc)) : 0;
    }
  }

  /**
   * Long naira on cNGN alone at IM 10% / MM 6%: the cNGN credits F x value, so the account runs
   * F/im x on its collateral (5x at F = 0.5). Walked to MM, stepped 10% and 25%. The venue refuses
   * this direction; this is what a directly-created account could still do to the SecurityModule.
   */
  function testCngnLongNairaAtTenXMarginRequirements() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);
    srm.setPerpMarginRequirements(marketId, 0.06e18, IM_10X);
    // 0.1 would need 25M cNGN for the side, the test ctx's whole collateral cap; 0.15 already clears 25%.
    uint64[4] memory factors = [uint64(0.5e18), 0.3e18, 0.2e18, 0.15e18];
    uint16[2] memory steps = [uint16(1_000), 2_500];
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
}
