// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {CngnPerpStackFork} from "./CngnPerpStackFork.t.sol";
import {DeployCngnPerpCollateral} from "../../scripts/deploy-cngn-perp-collateral.s.sol";
import {CNGNPerpCollateralBatch} from "../../scripts/cngn-perp-collateral-batch.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {IStandardManager} from "../../src/interfaces/IStandardManager.sol";

/**
 * cNGN as margin on the USDC-settled perp: sizes the haircut and checks the batch that enables it.
 *
 * Deploys the phase-0 stack (CngnPerpStackFork), then the perp's own cNGN escrow through the deploy
 * script, and executes CNGNPerpCollateralBatch as the vault would. Three questions:
 *   1. the sizing: the largest margin factor at which a long-naira account that posted only cNGN,
 *      left by the keeper at maintenance margin, is still solvent after a 25% index step, so the
 *      SecurityModule pays nothing for it. That factor is what the deploy script pins;
 *   2. the hedged direction: how much naira strength a treasury short naira on cNGN margin survives
 *      before liquidation, at full leverage and at 1:1;
 *   3. what `borrowingEnabled` actually gates once cNGN counts: not loss settlement (pinned in
 *      CngnPerpStackFork), but every negative cash delta that lands below zero -- a USDC withdrawal
 *      against cNGN, and also the taker fee of an account that holds no cash. So it stays on.
 *
 * Requires BASE_RPC_URL. The real Base cNGN token is used (it is an upgradeable, pausable proxy;
 * the escrow must work with that one, not a mock).
 */
contract CngnPerpCollateralFork is CngnPerpStackFork {
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;
  uint constant COLLATERAL_CAP = 25_000_000e18;
  uint SIZED_FACTOR;

  DeployCngnPerpCollateral script;
  DeployCngnPerpCollateral.Deployed deployed;
  WrappedERC20Asset cngnEscrow;
  uint marketId;

  function setUp() public override {
    super.setUp();
    marketId = srm.lastMarketId();
    script = new DeployCngnPerpCollateral();
    SIZED_FACTOR = script.SIZED_MARGIN_FACTOR();
    // The test plays the vault: the escrow is nominated to it, and it owns the SRM already.
    deployed = script.deploy(_params(SIZED_FACTOR, 1e18));
    cngnEscrow = deployed.escrow;
    script.assertDeployed(deployed, _params(SIZED_FACTOR, 1e18), address(script));
  }

  // --- the batch -------------------------------------------------------------------

  function testBatchOpensCngnMarginExactlyAsBuilt() public {
    assertFalse(cngnEscrow.whitelistedManager(address(srm)), "shut before the batch");
    _enable(SIZED_FACTOR, 1e18);

    assertEq(cngnEscrow.owner(), address(this), "custody passed");
    assertTrue(
      srm.borrowingEnabled(), "borrowing stays on: fees and funding settle into cash a cNGN account does not hold"
    );
    assertEq(address(cash.rateModel()), address(deployed.rateModel), "the cash prices borrowed cash on the new model");
    assertEq(deployed.rateModel.minRate(), 0.1e18, "with a 10% floor");
    assertTrue(cngnEscrow.whitelistedManager(address(srm)), "open to the perp SRM only");
    assertEq(cngnEscrow.totalPositionCap(srm), COLLATERAL_CAP, "capped");
    (uint factor, uint imScale) = srm.baseMarginParams(marketId);
    assertEq(factor, SIZED_FACTOR, "haircut");
    assertEq(imScale, 1e18, "IM scale");

    // 10M cNGN ($7,200 at the index) margins exactly factor x value, and is worth its full value.
    _depositCngn(alice, aliceAcc, 10_000_000e6);
    (int im, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, true, 0);
    assertApproxEqAbs(mtm, 7_200e18, 1e18, "cNGN is worth its oracle value");
    assertApproxEqAbs(im, 3_600e18, 1e18, "and counts half of it as margin");

    // The cap counts every account: the deposit that crosses it is refused, nothing else is.
    _depositCngn(bob, bobAcc, 15_000_000e6);
    deal(CNGN, bob, 1e6);
    vm.startPrank(bob);
    IERC20Metadata(CNGN).approve(address(cngnEscrow), 1e6);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    cngnEscrow.deposit(bobAcc, 1e6);
    vm.stopPrank();

    // Withdrawal pays real cNGN back, and is refused once it would breach initial margin.
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18); // alice long $7,200 on $3,600 of credit
    vm.prank(alice);
    cngnEscrow.withdraw(aliceAcc, 1_000_000e6, alice);
    assertEq(IERC20Metadata(CNGN).balanceOf(alice), 1_000_000e6, "cNGN leaves as cNGN");
    vm.prank(alice);
    vm.expectRevert();
    cngnEscrow.withdraw(aliceAcc, 5_000_000e6, alice);
  }

  // --- 1. the sizing ---------------------------------------------------------------

  /**
   * For each factor: the treasury posts only cNGN, opens the full long side (25M cNGN, the OI cap)
   * at initial margin -- the largest position the factor allows -- then the index walks it to
   * maintenance margin (the keeper's worst case: it never got to liquidate) and steps down 25%.
   * The auction is run to its end in the insolvent case (the most the SecurityModule ever pays),
   * and to the end of the fast phase in the solvent one.
   *
   * The fresh-open row (no walk, 25% straight after opening at IM) is the same account a moment
   * after it opens: milder, and reported for the runbook.
   */
  function testMarginFactorSizingThroughA25PctStep() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);

    uint64[6] memory factors = [uint64(1e18), 0.8e18, 0.7e18, 0.6e18, 0.5e18, 0.4e18];
    for (uint i; i < factors.length; ++i) {
      uint snapshot = vm.snapshotState();
      StepResult memory atMM = _cngnStep(factors[i], 1e18, 2_500, true);
      vm.revertToState(snapshot);
      snapshot = vm.snapshotState();
      StepResult memory fresh = _cngnStep(factors[i], 1e18, 2_500, false);
      vm.revertToState(snapshot);

      console2.log("factor (18dp):", factors[i]);
      console2.log("  collateral posted (cNGN, 18dp):", atMM.collateral);
      console2.log("  at MM then -25%: equity ($, 18dp, signed)", atMM.equityAfter);
      console2.log("  at MM then -25%: security module paid ($, 18dp)", atMM.smPaid);
      console2.log("  at MM then -25%: insolvent auction?", atMM.insolvent);
      console2.log("  at MM then -25%: keeper holds cNGN after the bid (18dp)", atMM.keeperCngn);
      console2.log("  at MM then -25%: share of the position the bid closed (bps)", atMM.closedBps);
      console2.log("  fresh at IM then -25%: equity ($, 18dp, signed)", fresh.equityAfter);
      console2.log("  fresh at IM then -25%: security module paid ($, 18dp)", fresh.smPaid);

      if (factors[i] == SIZED_FACTOR) {
        assertGt(atMM.equityAfter, 0, "at the sized factor an account left at MM survives the step solvent");
        assertEq(atMM.smPaid, 0, "so the SecurityModule pays nothing");
        assertFalse(atMM.insolvent, "and it is liquidated solvent, for cNGN");
        assertGt(atMM.keeperCngn, 0, "the keeper ends up holding the cNGN");
        assertEq(fresh.smPaid, 0, "a fresh account is milder still");
      }
      if (factors[i] == 0.7e18) {
        assertLt(atMM.equityAfter, 0, "at 0.7 the same account is insolvent after the step");
        assertGt(atMM.smPaid, 0, "and the SecurityModule pays for it");
      }
    }
  }

  /**
   * Re-derives the SecurityModule rule for cNGN margin through the 40% drill step: the full-cap
   * long-naira account at MM, margined on cNGN at the sized factor, against the same account on
   * cash (CngnPerpStackFork's table).
   *
   * The insolvent auction pays the bidder a price that walks from the mark-to-market deficit (t=0)
   * to the MAINTENANCE-MARGIN deficit (its end). On cash the two are $0 apart; on cNGN the margin
   * deficit also carries the 50% haircut on the collateral the bidder receives at full value, so
   * a bid at the auction's end overpays by half the cNGN's worth. The venue's own keeper decides
   * when that bid lands: valuing the cNGN it receives at the index less its own haircut, it bids
   * the first moment the payout covers its deficit, and the SecurityModule pays that, not the
   * terminal price. Both are reported; the rule holds on the keeper's price.
   */
  function testCngnMarginCostsTheSecurityModuleNoMoreThanCashAt40Pct() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6);

    uint snapshot = vm.snapshotState();
    StepResult memory terminal = _cngnStep(SIZED_FACTOR, 1e18, 4_000, true);
    vm.revertToState(snapshot);
    snapshot = vm.snapshotState();
    (int cashEquity, uint cashSmPaid) = _jumpAtCap(4_000);
    vm.revertToState(snapshot);
    (int keeperEquity, uint keeperSmPaid, uint bidAfter) = _cngnStepKeeperBids(SIZED_FACTOR, 4_000, 1_000);

    console2.log("40% step at the full cap, account at MM:");
    console2.log("  on cNGN: equity ($, 18dp, signed)", terminal.equityAfter);
    console2.log("  on cNGN, bid at the auction's end: security module paid ($, 18dp)", terminal.smPaid);
    console2.log("  on cNGN, keeper bids once whole at a 10% cNGN haircut: paid ($, 18dp)", keeperSmPaid);
    console2.log("  on cNGN, keeper bids once whole: seconds into the auction", bidAfter);
    console2.log("  on cash: equity ($, 18dp, signed)", cashEquity);
    console2.log("  on cash, bid at the auction's end: security module paid ($, 18dp)", cashSmPaid);
    assertEq(keeperEquity, terminal.equityAfter, "same account both ways");
    assertGt(terminal.equityAfter, cashEquity, "on cNGN the account is less underwater than on cash");
    assertLe(keeperSmPaid, cashSmPaid, "and on the keeper's bid it costs the SecurityModule no more than cash");
    assertGt(terminal.smPaid, cashSmPaid, "left to the auction's end it would cost more: the keeper must bid");
  }

  /// The sizing scenario, liquidated the way the venue's keeper does it: bids at the first minute
  /// the insolvent payout covers its deficit with the cNGN it receives valued at index x (1 - haircut).
  function _cngnStepKeeperBids(uint factor, uint jumpBps, uint cngnHaircutBps)
    internal
    returns (int equityAfter, uint smPaid, uint bidAfter)
  {
    _enable(factor, 1e18);
    uint n = uint(CAP_SIDE);
    uint collateral = (n * 1e18 / (3 * factor)) * 1_001 / 1_000;
    _depositCngn(alice, aliceAcc, collateral / 1e12);
    _deposit(bob, bobAcc, 100_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);
    _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
    uint96 preJump =
      uint96((n * INDEX_PRICE / 1e18) * 1e18 / (collateral * factor / 1e18 + n * 8 / 10) * 10_005 / 10_000);
    _setPrices(preJump);
    uint96 postJump = uint96(uint(preJump) * (10_000 - jumpBps) / 10_000);
    _setPrices(postJump);
    (, equityAfter) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertLt(equityAfter, 0, "insolvent");

    // What the keeper needs paid: the equity deficit, plus the haircut it takes on the cNGN.
    uint cngnValue = collateral * postJump / 1e18;
    int keeperDeficit = -equityAfter + int(cngnValue * cngnHaircutBps / 10_000);

    uint smAcc = securityModule.accountId();
    int smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    assertTrue(auction.getAuction(aliceAcc).insolvent, "opens insolvent");
    uint started = block.timestamp;
    uint length = auction.getAuctionParams().insolventAuctionLength;
    while (true) {
      _setPrices(postJump);
      int bid = auction.getCurrentBidPrice(aliceAcc); // negative: paid to the bidder
      if (-bid >= keeperDeficit || block.timestamp - started >= length) break;
      vm.warp(block.timestamp + 59);
    }
    bidAfter = block.timestamp - started;
    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    assertEq(_perpBalance(aliceAcc), 0, "closed");
    smPaid = uint(smBefore - _cash(smAcc));
  }

  struct StepResult {
    uint collateral;
    int equityBefore;
    int equityAfter;
    uint smPaid;
    bool insolvent;
    int keeperCngn;
    uint closedBps;
  }

  function _cngnStep(uint factor, uint imScale, uint jumpBps, bool walkToMM) internal returns (StepResult memory r) {
    _enable(factor, imScale);
    uint n = uint(CAP_SIDE);
    // IM: C*p*F*s >= N*p/3, so C = N / (3*F*s), plus 0.1% so the open clears.
    r.collateral = (n * 1e18 / (3 * factor * imScale / 1e18)) * 1_001 / 1_000;
    _depositCngn(alice, aliceAcc, r.collateral / 1e12);
    _deposit(bob, bobAcc, 100_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);
    _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
    assertGe(srm.getMargin(aliceAcc, true), 0, "alice opens within initial margin");

    uint96 preJump = INDEX_PRICE;
    if (walkToMM) {
      // MM: C*p*F - 0.2*N*p + N*(p - p0) = 0  =>  p = N*p0 / (C*F + 0.8*N); sit 5bps above it.
      uint usd = n * INDEX_PRICE / 1e18;
      uint denom = r.collateral * factor / 1e18 + n * 8 / 10;
      preJump = uint96(usd * 1e18 / denom * 10_005 / 10_000);
      _setPrices(preJump);
      int mm = srm.getMargin(aliceAcc, false);
      assertGe(mm, 0, "alice sits above maintenance margin");
      assertLt(mm, 100e18, "and only just");
    }
    (, r.equityBefore) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);

    uint96 postJump = uint96(uint(preJump) * (10_000 - jumpBps) / 10_000);
    _setPrices(postJump);
    (, r.equityAfter) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);

    uint smAcc = securityModule.accountId();
    int smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    r.insolvent = auction.getAuction(aliceAcc).insolvent;
    vm.warp(
      block.timestamp
        + (r.insolvent
            ? auction.getAuctionParams().insolventAuctionLength
            : auction.getAuctionParams().fastAuctionLength)
    );
    _setPrices(postJump);
    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    // An insolvent bid takes everything; a solvent one takes only the proportion that restores the
    // account's margin, and leaves it the rest.
    if (r.insolvent) assertEq(_perpBalance(aliceAcc), 0, "an insolvent bid closes the whole position");
    r.closedBps = uint(CAP_SIDE - _perpBalance(aliceAcc)) * 10_000 / uint(CAP_SIDE);
    int smAfter = _cash(smAcc);
    r.smPaid = smAfter < smBefore ? uint(smBefore - smAfter) : 0;
    r.keeperCngn = _cngn(charlieAcc);
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "a funded SecurityModule covers it without socializing");
  }

  // --- 2. the hedged direction ------------------------------------------------------

  /**
   * A treasury posts 10M cNGN and shorts naira. Naira weakening costs it on the collateral and pays
   * on the perp: hedged, and it stays above margin through a 25% fall. Naira strengthening is where
   * the haircut bites: the collateral gains at full value but only half of it is margin, while the
   * short loses at full value. At full leverage (15M short on 10M posted, the IM maximum at 0.5) a
   * ~15% rise liquidates it; at 1:1 (10M short on 10M posted) it takes ~43%.
   */
  function testHedgedTreasuryHeadroom() public {
    _enable(SIZED_FACTOR, 1e18);
    _deposit(bob, bobAcc, 100_000e6);

    uint snapshot = vm.snapshotState();
    _depositCngn(alice, aliceAcc, 10_000_000e6);
    _tradePerp(aliceAcc, bobAcc, 15_000_000e18); // alice short 15M cNGN: the most 10M posted allows
    assertGe(srm.getMargin(aliceAcc, true), 0, "full leverage opens within IM");
    _setPrices(uint96(uint(INDEX_PRICE) * 75 / 100));
    assertGe(srm.getMargin(aliceAcc, false), 0, "a 25% naira fall leaves the hedged treasury above MM");
    _setPrices(uint96(uint(INDEX_PRICE) * 114 / 100));
    assertGe(srm.getMargin(aliceAcc, false), 0, "a 14% rise is survived at full leverage");
    _setPrices(uint96(uint(INDEX_PRICE) * 116 / 100));
    assertLt(srm.getMargin(aliceAcc, false), 0, "a 16% rise liquidates it (solvent: the auction, not the SM)");
    (, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertGt(mtm, 0, "still solvent by far");
    vm.revertToState(snapshot);

    _depositCngn(alice, aliceAcc, 10_000_000e6);
    _tradePerp(aliceAcc, bobAcc, 10_000_000e18); // 1:1
    _setPrices(uint96(uint(INDEX_PRICE) * 141 / 100));
    assertGe(srm.getMargin(aliceAcc, false), 0, "at 1:1 a 41% rise is survived");
    _setPrices(uint96(uint(INDEX_PRICE) * 145 / 100));
    assertLt(srm.getMargin(aliceAcc, false), 0, "and 45% liquidates");
  }

  // --- 3. what borrowing gates ----------------------------------------------------

  /// With cNGN as margin, `borrowingEnabled` is also a USDC loan facility: an account can withdraw
  /// cash it does not have, down to initial margin, against its cNGN at the haircut. Losses settle
  /// into negative cash and a fee-free close works either way. What needs it on is the next test:
  /// the taker fee, a cash transfer an account holding only cNGN cannot make from zero.
  function testBorrowingGatesLoansNotLosses() public {
    _enable(SIZED_FACTOR, 1e18);
    _deposit(bob, bobAcc, 100_000e6);
    _depositCngn(alice, aliceAcc, 10_000_000e6);

    srm.setBorrowingEnabled(true);
    uint before = IERC20Metadata(USDC).balanceOf(alice);
    vm.prank(alice);
    cash.withdraw(aliceAcc, 1_000e6, alice); // a $1,000 loan against $7,200 of cNGN
    assertEq(IERC20Metadata(USDC).balanceOf(alice) - before, 1_000e6, "borrowing on: USDC leaves against cNGN");
    assertEq(_cash(aliceAcc), -1_000e18, "as negative cash");
    assertGt(cash.totalBorrow(), 0, "which the pool is now lending");
    deal(USDC, alice, 1_000e6);
    vm.startPrank(alice);
    IERC20Metadata(USDC).approve(address(cash), 1_000e6);
    cash.deposit(aliceAcc, 1_000e6);
    vm.stopPrank();
    assertEq(_cash(aliceAcc), 0, "repaid");

    srm.setBorrowingEnabled(false);
    vm.prank(alice);
    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    cash.withdraw(aliceAcc, 1_000e6, alice);

    // A loss still lands as negative cash with borrowing off, and the position can still be closed.
    _tradePerp(bobAcc, aliceAcc, 5_000_000e18); // alice long 5M cNGN ($3,600)
    _setPrices(uint96(uint(INDEX_PRICE) * 90 / 100));
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), 0, "the loss is negative cash, borrowing or not");
    _tradePerp(aliceAcc, bobAcc, 5_000_000e18);
    assertEq(_perpBalance(aliceAcc), 0, "closed with cash negative and borrowing off");
    // And cNGN can leave down to IM, borrowing or not: the negative cash is owed, the rest is hers.
    vm.prank(alice);
    cngnEscrow.withdraw(aliceAcc, 1_000_000e6, alice);
  }

  /// The venue's TradeModule charges the taker fee as a cash transfer in the same batch as the
  /// perp leg. With borrowing OFF, an account whose cash ends below zero after a negative cash
  /// delta reverts (SRM_NoNegativeCash), so a cNGN-only account could not open, and one whose loss
  /// has already settled could not close. Borrowing therefore stays ON for cNGN margin.
  function testTakerFeeOnACngnOnlyAccountNeedsBorrowing() public {
    _enable(SIZED_FACTOR, 1e18);
    _deposit(bob, bobAcc, 100_000e6);
    _depositCngn(alice, aliceAcc, 10_000_000e6);
    uint feeAcc = subAccounts.createAccountWithApproval(charlie, address(this), srm);

    srm.setBorrowingEnabled(false);
    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _tradePerpWithFee(bobAcc, aliceAcc, 5_000_000e18, aliceAcc, feeAcc, 9e18); // $9 fee on $3,600

    srm.setBorrowingEnabled(true);
    _tradePerpWithFee(bobAcc, aliceAcc, 5_000_000e18, aliceAcc, feeAcc, 9e18);
    assertEq(_cash(aliceAcc), -9e18, "the fee is a small loan against the cNGN");
    assertEq(_perpBalance(aliceAcc), 5_000_000e18, "and the position opened");

    // A loss settles; with borrowing off the close's fee would revert on the negative cash.
    _setPrices(uint96(uint(INDEX_PRICE) * 90 / 100));
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), -9e18, "the loss landed on top");
    srm.setBorrowingEnabled(false);
    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _tradePerpWithFee(aliceAcc, bobAcc, 5_000_000e18, aliceAcc, feeAcc, 9e18);
    srm.setBorrowingEnabled(true);
    _tradePerpWithFee(aliceAcc, bobAcc, 5_000_000e18, aliceAcc, feeAcc, 9e18);
    assertEq(_perpBalance(aliceAcc), 0, "closed, fee paid from borrowed cash");
  }

  /// A perp transfer plus the taker's fee as a cash transfer, as the TradeModule submits them.
  function _tradePerpWithFee(uint fromAcc, uint toAcc, int amount, uint payer, uint feeAcc, int fee) internal {
    ISubAccounts.AssetTransfer[] memory transfers = new ISubAccounts.AssetTransfer[](2);
    transfers[0] = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: bytes32(0)
    });
    transfers[1] = ISubAccounts.AssetTransfer({
      fromAcc: payer, toAcc: feeAcc, asset: cash, subId: 0, amount: fee, assetData: bytes32(0)
    });
    subAccounts.submitTransfers(transfers, "");
  }

  // --- helpers ---------------------------------------------------------------------

  function _params(uint factor, uint imScale) internal view returns (DeployCngnPerpCollateral.Params memory) {
    return DeployCngnPerpCollateral.Params({
      subAccounts: SUB_ACCOUNTS,
      cngnToken: CNGN,
      srm: address(srm),
      cash: address(cash),
      indexFeed: address(indexFeed),
      marketId: marketId,
      vault: address(this),
      marginFactor: factor,
      imScale: imScale,
      cap: COLLATERAL_CAP,
      rateFloor: 0.1e18
    });
  }

  /// Executes the batch as the vault would: the same build() the script serialises, in order.
  function _enable(uint factor, uint imScale) internal {
    CNGNPerpCollateralBatch.Ctx memory ctx = script.batchCtx(deployed, _params(factor, imScale));
    CNGNPerpCollateralBatch.checkPreconditions(ctx);
    CNGNPerpCollateralBatch.execute(ctx);
    assertFalse(cngnEscrow.whitelistedManager(address(srm)), "the configuring batch opens nothing");
    CNGNPerpCollateralBatch.executeEnable(ctx);
  }

  function _depositCngn(address user, uint acc, uint cngnAmount) internal {
    deal(CNGN, user, IERC20Metadata(CNGN).balanceOf(user) + cngnAmount);
    vm.startPrank(user);
    IERC20Metadata(CNGN).approve(address(cngnEscrow), cngnAmount);
    cngnEscrow.deposit(acc, cngnAmount);
    vm.stopPrank();
  }

  function _cngn(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cngnEscrow, 0);
  }
}
