// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CNGNPerpLeverageBatch} from "../../scripts/cngn-perp-leverage-batch.sol";
import {PrepareCngnPerpLeverage} from "../../scripts/prepare-cngn-perp-leverage.s.sol";
import {CngnPerpCollateralFork} from "./CngnPerpCollateralFork.t.sol";

/**
 * The stage (B) batch exactly as the script builds it, applied on a Base fork after batches 4 and 5,
 * then the two numbers it was sized on re-checked on the resulting state: a long-naira account on
 * cNGN alone survives a 25% step at maintenance margin, and a 1:1 hedge is liquidated by a naira
 * rally of about 30%, solvent. Also pins the gates: the batch refuses an SRM whose factor is
 * already at or below the target, and the funding gate refuses a SecurityModule below the floor.
 *
 * Requires BASE_RPC_URL.
 */
contract CngnPerpLeverageBatchFork is CngnPerpCollateralFork {
  PrepareCngnPerpLeverage internal prepare;

  function _ctx() internal returns (CNGNPerpLeverageBatch.Ctx memory ctx) {
    if (address(prepare) == address(0)) prepare = new PrepareCngnPerpLeverage();
    ctx.vault = address(this);
    ctx.srm = address(srm);
    ctx.subAccounts = address(cash.subAccounts());
    ctx.cash = address(cash);
    ctx.securityModuleAccount = securityModule.accountId();
    ctx.marketId = marketId;
    ctx.mmReq = prepare.DEFAULT_MM_REQ();
    ctx.imReq = prepare.DEFAULT_IM_REQ();
    ctx.marginFactor = prepare.DEFAULT_MARGIN_FACTOR();
    ctx.imScale = 1e18;
    ctx.securityModuleFloor = prepare.DEFAULT_SECURITY_MODULE_FLOOR();
  }

  function testLeverageBatchAppliesAndHoldsItsSizing() public {
    _enable(SIZED_FACTOR, 1e18); // batches 4 and 5 on the fork: cNGN is margin at 0.5
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    CNGNPerpLeverageBatch.Ctx memory ctx = _ctx();

    vm.expectRevert(bytes("PRE: SecurityModule below the agreed floor; fund it first"));
    this.checkFundedExternal(ctx);
    _fundSecurityModule(6_000e6);
    CNGNPerpLeverageBatch.checkFunded(ctx);
    CNGNPerpLeverageBatch.checkPreconditions(ctx);

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

    // Applied twice it is refused: the factor is no longer above the target.
    vm.expectRevert(bytes("PRE: the batch does not lower both requirements"));
    this.checkPreconditionsExternal(ctx);

    _deposit(bob, bobAcc, 500_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);

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

  function checkFundedExternal(CNGNPerpLeverageBatch.Ctx memory ctx) external view {
    CNGNPerpLeverageBatch.checkFunded(ctx);
  }

  function checkPreconditionsExternal(CNGNPerpLeverageBatch.Ctx memory ctx) external view {
    CNGNPerpLeverageBatch.checkPreconditions(ctx);
  }
}
