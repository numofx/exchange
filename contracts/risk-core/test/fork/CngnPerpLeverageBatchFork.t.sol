// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CNGNPerpLeverageBatch} from "../../scripts/cngn-perp-leverage-batch.sol";
import {PrepareCngnPerpLeverage} from "../../scripts/prepare-cngn-perp-leverage.s.sol";
import {CngnPerpLeverageFork} from "./CngnPerpLeverageFork.t.sol";

/**
 * The stage (B) batch exactly as the script builds it, applied on a Base fork after batches 4 and 5,
 * then the numbers it was sized on re-checked on the resulting state: a long-naira account on cNGN
 * alone survives a 25% step at maintenance margin, and a 1:1 hedge is liquidated by a naira rally
 * of about 30%, solvent. Also pins the gates: the SecurityModule coverage rule against actual open
 * interest (passes on today's open interest, refuses once a whole side is open, passes again once
 * funded), its formula against the fork's measured payouts at 3x and 5x, and that the batch cannot
 * be applied twice.
 *
 * Requires BASE_RPC_URL.
 */
contract CngnPerpLeverageBatchFork is CngnPerpLeverageFork {
  PrepareCngnPerpLeverage internal prepare;

  function _ctx() internal returns (CNGNPerpLeverageBatch.Ctx memory ctx) {
    if (address(prepare) == address(0)) prepare = new PrepareCngnPerpLeverage();
    ctx.vault = address(this);
    ctx.srm = address(srm);
    ctx.perp = address(perp);
    ctx.subAccounts = address(cash.subAccounts());
    ctx.cash = address(cash);
    ctx.securityModuleAccount = securityModule.accountId();
    ctx.marketId = marketId;
    ctx.mmReq = prepare.DEFAULT_MM_REQ();
    ctx.imReq = prepare.DEFAULT_IM_REQ();
    ctx.marginFactor = prepare.DEFAULT_MARGIN_FACTOR();
    ctx.imScale = 1e18;
  }

  /// The sizing formula against what the auction actually charged the SecurityModule on the fork:
  /// never below it, and within 5% above it (measured: 0.2%), at 3x and at 5x.
  function testCoverageFormulaMatchesTheForkWithinFivePercent() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);
    uint64[2] memory ims = [uint64(0.33333e18), 0.2e18];
    uint64[2] memory mms = [uint64(0.2e18), 0.12e18];
    for (uint i; i < ims.length; ++i) {
      uint snapshot = vm.snapshotState();
      CashStep memory r = _cashStep(2_500, ims[i], mms[i]);
      vm.revertToState(snapshot);
      uint formula = CNGNPerpLeverageBatch.requiredSecurityModule(uint(CAP_SIDE), INDEX_PRICE, ims[i], 2_500);
      console2.log("IM (18dp):", ims[i]);
      console2.log("  fork: SM paid at the auction's end ($, 18dp):", r.smPaidAtEnd);
      console2.log("  formula: one side x 25% x (1 - IM) ($, 18dp):", formula);
      assertTrue(r.insolvent, "a 25% step from MM is an insolvent auction at this leverage");
      assertGe(formula, r.smPaidAtEnd, "the formula never understates the fork");
      assertLe(formula, r.smPaidAtEnd * 105 / 100, "and is within 5% of it");
    }
  }

  function testLeverageBatchAppliesAndHoldsItsSizing() public {
    _enable(SIZED_FACTOR, 1e18); // batches 4 and 5 on the fork: cNGN is margin at 0.5
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    CNGNPerpLeverageBatch.Ctx memory ctx = _ctx();
    CNGNPerpLeverageBatch.checkPreconditions(ctx);

    // The coverage gate on the fork's open interest (a few thousand cNGN) passes with what the
    // fork stack's SecurityModule holds; with a whole side open at the cap it needs more.
    CNGNPerpLeverageBatch.checkCovered(ctx);
    _deposit(bob, bobAcc, 500_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);
    uint beforeSide = vm.snapshotState();
    {
      (uint mmNow, uint imNow) = srm.perpMarginRequirements(marketId);
      mmNow;
      _deposit(alice, aliceAcc, (uint(CAP_SIDE) * INDEX_PRICE / 1e18) * imNow / 1e18 / 1e12 + 1e6);
      _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
      (uint held, uint oneSide, uint price) = CNGNPerpLeverageBatch.coverageInputs(ctx);
      uint required = CNGNPerpLeverageBatch.requiredSecurityModule(oneSide, price, ctx.imReq, 2_500);
      console2.log("one side at the cap: SM holds ($, 18dp):", held);
      console2.log("  required for a 25% step at IM 20% ($, 18dp):", required);
      assertLt(held, required, "the live SecurityModule does not cover a whole side at 5x");
      vm.expectRevert(
        bytes(
          "PRE: SecurityModule does not cover a 25% step on today's one-side open interest at the new leverage; fund it or lower the cap"
        )
      );
      this.checkCoveredExternal(ctx);
      _fundSecurityModule(uint((required - held) / 1e12) + 1e6);
      CNGNPerpLeverageBatch.checkCovered(ctx);
    }
    vm.revertToState(beforeSide);

    // The script's calldata is what the vault signs; the test executes exactly that.
    string memory actions = prepare.vaultActionsJson(ctx);
    assertEq(vm.parseJsonAddress(actions, "[0].to"), address(srm));
    assertEq(vm.parseJsonAddress(actions, "[1].to"), address(srm));
    CNGNPerpLeverageBatch.execute(ctx);

    (uint mm, uint im) = srm.perpMarginRequirements(marketId);
    assertEq(mm, 0.12e18, "MM 12%");
    assertEq(im, 0.2e18, "IM 20%");
    (uint factor, uint imScale) = srm.baseMarginParams(marketId);
    assertEq(factor, 0.35e18, "factor 0.35");
    assertEq(imScale, 1e18, "IM scale unchanged");

    // Applied twice it is refused: the requirements are no longer above the target.
    vm.expectRevert(bytes("PRE: the batch does not lower both requirements"));
    this.checkPreconditionsExternal(ctx);

    // 1. Long naira on cNGN alone, at MM, stepped 25%: solvent (the venue refuses the direction;
    //    this is what a directly-created account could do to the SecurityModule).
    uint snapshot = vm.snapshotState();
    {
      uint n = uint(CAP_SIDE);
      uint collateral = (n * im / factor) * 1_001 / 1_000;
      _depositCngn(alice, aliceAcc, collateral / 1e12);
      _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
      assertGe(srm.getMargin(aliceAcc, true), 0, "opens within IM");
      uint usd = n * INDEX_PRICE / 1e18;
      uint denom = collateral * factor / 1e18 + n * (1e18 - mm) / 1e18;
      uint96 preJump = uint96(usd * 1e18 / denom * 10_005 / 10_000);
      _setPrices(preJump);
      assertGe(srm.getMargin(aliceAcc, false), 0, "sits above MM");
      _setPrices(uint96(uint(preJump) * 7_500 / 10_000));
      (, int equity) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
      assertGt(equity, 0, "a 25% step from MM leaves the long-naira cNGN account solvent at 0.35 / MM 12%");
      console2.log("long naira on cNGN, 25% step from MM: equity ($, 18dp):", equity);
    }
    vm.revertToState(snapshot);

    // 2. A 1:1 hedge (long USD on cNGN) is liquidated by a rally near 30%, solvent, and rides a 25% fall.
    _depositCngn(alice, aliceAcc, 10_000_000e6);
    _tradePerp(aliceAcc, bobAcc, 10_000_000e18);
    assertGe(srm.getMargin(aliceAcc, true), 0, "1:1 opens within IM");
    _setPrices(uint96(uint(INDEX_PRICE) * 75 / 100));
    assertGe(srm.getMargin(aliceAcc, false), 0, "a 25% naira fall is the hedge working");
    _setPrices(uint96(uint(INDEX_PRICE) * 128 / 100));
    assertGe(srm.getMargin(aliceAcc, false), 0, "a 28% rally is survived at 1:1");
    _setPrices(uint96(uint(INDEX_PRICE) * 131 / 100));
    assertLt(srm.getMargin(aliceAcc, false), 0, "a 31% rally liquidates it");
    (, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertGt(mtm, 0, "solvent: the auction pays, not the SecurityModule");
  }

  function checkCoveredExternal(CNGNPerpLeverageBatch.Ctx memory ctx) external view {
    CNGNPerpLeverageBatch.checkCovered(ctx);
  }

  function checkPreconditionsExternal(CNGNPerpLeverageBatch.Ctx memory ctx) external view {
    CNGNPerpLeverageBatch.checkPreconditions(ctx);
  }
}
