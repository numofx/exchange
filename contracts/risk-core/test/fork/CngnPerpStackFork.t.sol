// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "../../src/SubAccounts.sol";
import "../../src/SecurityModule.sol";
import "../../src/assets/CashAsset.sol";
import "../../src/assets/PerpAsset.sol";
import "../../src/assets/InterestRateModel.sol";
import "../../src/liquidation/DutchAuction.sol";
import "../../src/risk-managers/StandardManager.sol";
import "../../src/risk-managers/SRMPortfolioViewer.sol";
import "../../src/feeds/LyraSpotFeed.sol";
import "../../src/feeds/LyraSpotDiffFeed.sol";
import "../../src/feeds/static/LyraStaticSpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {IDataReceiver} from "../../src/interfaces/IDataReceiver.sol";

import {Config} from "../../scripts/config-mainnet.sol";

/**
 * Phase 0 of the USDC-settled cNGN perp: does the insolvency path work on a NEW stack?
 *
 * Deploys, onto a Base fork, the stack the perp would run on: a CashAsset backed by real Base
 * USDC with borrowing enabled, its own SRM, viewer, SecurityModule and DutchAuction, and a
 * PerpAsset priced in USDC per cNGN. It reuses the live SubAccounts, because Matching is bound to
 * it, and touches nothing else on chain: the legacy SRM and its unbacked CashAsset are never
 * called. Parameters come from config-mainnet.sol (cNGN perp margin, auction, rate model).
 *
 * What must hold before this stack is worth deploying:
 *   1. a winner is paid in real USDC, not in cash that cannot be redeemed;
 *   2. a loss beyond the deposit lands as negative cash, and margin still binds;
 *   3. an insolvent account is closed by the auction and the SecurityModule pays the bidder;
 *   4. when the SecurityModule cannot cover it, the loss is socialized through the cash
 *      exchange rate and withdrawals still pay out, rather than the auction reverting.
 *
 * Requires BASE_RPC_URL, like every other fork test here.
 */
contract CngnPerpStackFork is Test {
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  /// USDC per cNGN, the perp's denomination: ~1,389 cNGN per USDC.
  uint96 constant INDEX_PRICE = 0.00072e18;

  // Derived, not a memorable constant: well-known keys like 0xC0FFEE carry EIP-7702 delegations
  // on Base, so SignatureChecker takes the ERC-1271 path for them and every signature fails.
  uint keeperPk = uint(keccak256("cngn-perp-stack-fork-keeper"));
  address keeper = vm.addr(keeperPk);

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address charlie = address(0xc4a);

  SubAccounts subAccounts = SubAccounts(SUB_ACCOUNTS);
  CashAsset cash;
  InterestRateModel rateModel;
  SRMPortfolioViewer viewer;
  StandardManager srm;
  SecurityModule securityModule;
  DutchAuction auction;
  PerpAsset perp;
  LyraSpotFeed indexFeed;
  LyraSpotDiffFeed markFeed;
  LyraSpotDiffFeed impactAskFeed;
  LyraSpotDiffFeed impactBidFeed;
  LyraStaticSpotFeed stableFeed;

  uint aliceAcc;
  uint bobAcc;
  uint charlieAcc;

  function setUp() public virtual {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    _deployStack();
    _deployPerp();

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), srm);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), srm);
    charlieAcc = subAccounts.createAccountWithApproval(charlie, address(this), srm);
  }

  // --- the four properties ---------------------------------------------------------

  /// 1. A winner withdraws real USDC; the cash they were credited is backed.
  function testWinnerIsPaidInRealUsdc() public {
    _deposit(alice, aliceAcc, 3_000e6);
    _deposit(bob, bobAcc, 3_000e6);

    // Bob longs 10M cNGN ($7,200 notional); alice takes the short.
    _tradePerp(aliceAcc, bobAcc, 10_000_000e18);

    // NGN strengthens 10%: bob is up $720.
    _setPrices(0.000792e18);
    _realize(bobAcc);
    _realize(aliceAcc);

    int bobCash = _cash(bobAcc);
    assertApproxEqAbs(bobCash, 3_720e18, 1e18, "bob's cash should carry the $720 gain");

    // Bob closes, then takes the whole balance, gain included, out as USDC.
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    uint before = IERC20Metadata(USDC).balanceOf(bob);
    vm.prank(bob);
    cash.withdraw(bobAcc, 3_719e6, bob);
    assertEq(IERC20Metadata(USDC).balanceOf(bob) - before, 3_719e6, "winner must receive real USDC");
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "cash must stay fully backed");
  }

  /// 2. A loss beyond the deposit lands as negative cash, and margin still binds.
  function testLossBeyondDepositSettlesNegativeAndMarginBinds() public {
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18); // alice long $7,200

    _setPrices(0.000432e18); // NGN -40%: alice loses $2,880 on $2,500
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), 0, "the loss must land as negative cash");

    // And nothing lets her take USDC out while under margin.
    vm.prank(alice);
    vm.expectRevert();
    cash.withdraw(aliceAcc, 1e6, alice);
  }

  /// The borrowing flag is not what makes 2 work: the SRM checks it only in `_assessRisk`, on
  /// risk-adding actions, so settlement records the same negative cash with it off. Pinned so
  /// nobody enables borrowing believing the insolvency path depends on it. (The auction tests
  /// below also pass with it off; what the legacy stack lacks is backed cash, not borrowing.)
  function testSettlementDoesNotDependOnBorrowing() public {
    srm.setBorrowingEnabled(false);
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);

    _setPrices(0.000432e18);
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), 0, "settlement must not be gated by the borrowing flag");
  }

  /// 3. Insolvent account: auction closes it and the SecurityModule pays the bidder.
  function testInsolventAuctionIsPaidBySecurityModule() public {
    _fundSecurityModule(5_000e6);
    _openInsolvent();

    uint smAcc = securityModule.accountId();
    int smCashBefore = _cash(smAcc);

    _runInsolventAuction();

    assertEq(_perpBalance(aliceAcc), 0, "alice's perp must be closed");
    assertEq(_perpBalance(charlieAcc), 10_000_000e18, "bidder must take the position");
    assertLt(_cash(smAcc), smCashBefore, "security module must have paid out");
    console2.log("security module paid (cash, 18dp):", uint(smCashBefore - _cash(smAcc)));
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "a covered loss must not socialize");
    assertFalse(cash.temporaryWithdrawFeeEnabled(), "no withdraw fee when covered");
  }

  /// 4. SecurityModule short: the loss socializes through the exchange rate, withdrawals pay.
  function testUncoveredLossSocializesAndWithdrawalsStillPay() public {
    _fundSecurityModule(10e6); // $10: nowhere near the shortfall
    _openInsolvent();

    _runInsolventAuction();

    assertEq(_perpBalance(aliceAcc), 0, "alice's perp must be closed");
    assertLt(cash.getCashToStableExchangeRate(), 1e18, "shortfall must socialize");
    console2.log("cash-to-USDC rate after socializing (18dp):", cash.getCashToStableExchangeRate());
    assertTrue(cash.temporaryWithdrawFeeEnabled(), "withdraw fee must switch on");

    // Bob, the counterparty who was owed, can still take real USDC out.
    _realize(bobAcc);
    uint before = IERC20Metadata(USDC).balanceOf(bob);
    vm.prank(bob);
    cash.withdraw(bobAcc, 1_000e6, bob);
    assertEq(IERC20Metadata(USDC).balanceOf(bob) - before, 1_000e6, "withdrawal must still pay");
  }

  // --- manual settlement after a step past INDEX_STEP_MAX_BPS -------------------------

  /// The runbook's path for an index step over 50%: the market stays closed, the vault freezes the
  /// perp at the confirmed level with perp.disable(), every account is settled at that frozen price
  /// (which deletes its position), and a loser left below zero goes through the insolvent auction
  /// like any other, paid by the SecurityModule. The winner then withdraws real USDC.
  function testManualSettlementAfterAStepPastTheBound() public {
    _fundSecurityModule(10_000e6);
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _deposit(charlie, charlieAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18); // alice long 10M cNGN ($7,200)

    // The venue is closed first by disallowing the module on Matching (not modelled here: this stack
    // has no Matching). The cap is NOT cut yet -- see testCapBelowOpenInterestFreezesPositionHolders.
    // Put the confirmed level on the feeds (a 60% fall in USDC per cNGN) and freeze the perp there.
    _setPrices(0.000288e18);
    perp.disable();
    assertEq(uint(perp.frozenPerpPrice()), 0.000288e18, "frozen at the confirmed level");

    // Settle every account at the frozen price. Anyone can call this; the keeper or a script does.
    _realize(aliceAcc);
    _realize(bobAcc);
    assertEq(_perpBalance(aliceAcc), 0, "alice's position is deleted");
    assertEq(_perpBalance(bobAcc), 0, "bob's position is deleted");
    // Alice lost $4,320 on $2,500: $1,820 short. Bob gained the $4,320.
    assertApproxEqAbs(_cash(aliceAcc), -1_820e18, 5e18, "alice's shortfall is negative cash");
    assertApproxEqAbs(_cash(bobAcc), 14_320e18, 5e18, "bob is credited his gain");
    // Every position is settled, so nobody holds the perp and the cap can close the market for good.
    // (disable() deletes positions without the perp's hook, so the OI counter keeps its old value;
    // that is harmless once no account holds the perp, since the cap is only checked for holders.)
    perp.setTotalPositionCap(srm, 0);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _tradePerp(bobAcc, charlieAcc, 1e18);

    // The shortfall goes through the insolvent auction and the SecurityModule pays the bidder.
    uint smAcc = securityModule.accountId();
    int smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    assertTrue(auction.getAuction(aliceAcc).insolvent, "a cash-only account below zero auctions insolvent");
    vm.warp(block.timestamp + auction.getAuctionParams().insolventAuctionLength);
    _setPrices(0.000288e18);
    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    console2.log("security module paid for the shortfall (18dp):", uint(smBefore - _cash(smAcc)));
    assertGe(_cash(aliceAcc), 0, "alice's account is made whole");
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "covered by the SecurityModule, nothing socialized");

    // And the winner is paid in real USDC.
    uint before = IERC20Metadata(USDC).balanceOf(bob);
    vm.prank(bob);
    cash.withdraw(bobAcc, 14_000e6, bob);
    assertEq(IERC20Metadata(USDC).balanceOf(bob) - before, 14_000e6, "bob withdraws his gain");
  }

  /// The hazard the settlement order avoids: with open interest above the cap, every account that
  /// holds the perp is frozen out of deposits and withdrawals. A cash-only adjustment never snapshots
  /// the perp's pre-trade OI, so the cap check reads it as 0 and sees the whole OI as an increase.
  /// A top-up is exactly what a trader needs before liquidation, so the vault must never set the cap
  /// below current OI; lowering it TO current OI stops growth without freezing anyone.
  function testCapBelowOpenInterestFreezesPositionHolders() public {
    _deposit(alice, aliceAcc, 5_000e6);
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    uint oi = perp.totalPosition(srm);

    perp.setTotalPositionCap(srm, oi - 1);
    deal(USDC, alice, 1_000e6);
    vm.startPrank(alice);
    IERC20Metadata(USDC).approve(address(cash), 1_000e6);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    cash.deposit(aliceAcc, 1_000e6);
    vm.stopPrank();
    vm.prank(bob);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    cash.withdraw(bobAcc, 1e6, bob);

    // At exactly the current OI, nobody is frozen, and new positions still cannot open.
    perp.setTotalPositionCap(srm, oi);
    vm.prank(alice);
    cash.deposit(aliceAcc, 1_000e6);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _tradePerp(bobAcc, aliceAcc, 1e18);
  }

  // --- deposit gas: estimated in one block, executed in another --------------------

  /// CashAsset._accrueInterest returns early when the cash was already touched at this timestamp,
  /// and otherwise writes the timestamp and, once anything is borrowed, runs the whole accrual. A
  /// gas estimate taken against the block that last touched the cash therefore prices the cheap
  /// path, and the deposit mined in a later block runs the expensive one.
  function testDepositGasDependsOnWhetherTheCashWasTouchedThisBlock() public {
    _deposit(alice, aliceAcc, 5_000e6);
    (uint sameBlock, uint laterBlock) = _depositGasBothWays(bobAcc);
    console2.log("deposit gas, no borrows: same block", sameBlock, "later block", laterBlock);
    assertGt(laterBlock, sameBlock, "a later block costs more");

    // With borrows outstanding (a loss past a deposit is negative cash, i.e. borrowed), the later
    // block runs the rate model and the fee cut too.
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    _setPrices(0.0002e18); // a $5,200 loss on $5,000
    _realize(aliceAcc);
    assertGt(cash.totalBorrow(), 0, "alice's loss past her deposit is a borrow");
    _deposit(charlie, charlieAcc, 1_000e6);
    (uint sameBlockBorrow, uint laterBlockBorrow) = _depositGasBothWays(charlieAcc);
    console2.log("deposit gas, with borrows: same block", sameBlockBorrow, "later block", laterBlockBorrow);
    assertGt(laterBlockBorrow, sameBlockBorrow, "a later block costs more");

    // The failure itself: exactly the same-block cost is not enough a block later.
    deal(USDC, charlie, 1e6);
    vm.prank(charlie);
    IERC20Metadata(USDC).approve(address(cash), 1e6);
    vm.warp(block.timestamp + 2);
    vm.cool(address(cash));
    vm.cool(address(rateModel));
    vm.cool(address(subAccounts));
    vm.cool(address(srm));
    vm.cool(address(viewer));
    vm.cool(USDC);
    vm.prank(charlie);
    (bool ok,) = address(cash).call{gas: sameBlockBorrow}(abi.encodeCall(CashAsset.deposit, (charlieAcc, 1e6)));
    assertFalse(ok, "a limit priced on the touching block runs out of gas a block later");
  }

  /// A deposit's gas as its own transaction would pay it: every contract it touches starts cold.
  function _coldDepositGas(address owner, uint acc) internal returns (uint used) {
    vm.cool(address(cash));
    vm.cool(address(rateModel));
    vm.cool(address(subAccounts));
    vm.cool(address(srm));
    vm.cool(address(viewer));
    vm.cool(USDC);
    vm.prank(owner);
    uint before = gasleft();
    cash.deposit(acc, 1e6);
    used = before - gasleft();
  }

  /// Gas for a 1 USDC deposit into `acc`, at the timestamp the cash was last touched and 2s later.
  function _depositGasBothWays(uint acc) internal returns (uint sameBlock, uint laterBlock) {
    address owner = subAccounts.ownerOf(acc);
    deal(USDC, owner, 2e6);
    vm.prank(owner);
    IERC20Metadata(USDC).approve(address(cash), 2e6);
    // Touch the cash at this timestamp, as another user's deposit or a trade in the same block would.
    _deposit(address(0x70c4), subAccounts.createAccount(address(0x70c4), srm), 1e6);

    uint snapshot = vm.snapshotState();
    sameBlock = _coldDepositGas(owner, acc);
    vm.revertToState(snapshot);

    vm.warp(block.timestamp + 2);
    laterBlock = _coldDepositGas(owner, acc);
    vm.revertToState(snapshot);
  }

  // --- guardian pause -------------------------------------------------------------

  address guardian = address(0x6a2d);

  /// The guardian (a hot ops key) freezes every adjustment under this SRM, and it alone lifts the
  /// pause: setAdjustmentsPaused is guardian-only in both directions, so not even the owner (the
  /// vault) can unpause without first making itself guardian.
  function testGuardianPauseFreezesTheStackAndOnlyTheGuardianLiftsIt() public {
    srm.setGuardian(guardian);
    _deposit(alice, aliceAcc, 5_000e6);
    _deposit(bob, bobAcc, 5_000e6);

    vm.prank(guardian);
    srm.setAdjustmentsPaused(true);

    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    subAccounts.submitTransfers(_perpTransfer(bobAcc, aliceAcc, 1e18), "");

    deal(USDC, alice, 1e6);
    vm.startPrank(alice);
    IERC20Metadata(USDC).approve(address(cash), 1e6);
    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    cash.deposit(aliceAcc, 1e6);
    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    cash.withdraw(aliceAcc, 1e6, alice);
    vm.stopPrank();

    vm.expectRevert(IBaseManager.BM_GuardianOnly.selector);
    srm.setAdjustmentsPaused(false); // the owner
    vm.prank(address(0xbad));
    vm.expectRevert(IBaseManager.BM_GuardianOnly.selector);
    srm.setAdjustmentsPaused(false);

    vm.prank(guardian);
    srm.setAdjustmentsPaused(false);
    _tradePerp(bobAcc, aliceAcc, 1e18);
    assertEq(_perpBalance(aliceAcc), 1e18, "trading resumes once the guardian unpauses");
  }

  /// A pause also stops liquidation: the auction can be started, but a bid reverts, so an
  /// insolvent account sits unliquidated (and its deficit can grow) until the pause is lifted.
  function testGuardianPauseAlsoBlocksLiquidationBids() public {
    srm.setGuardian(guardian);
    _fundSecurityModule(5_000e6);
    _openInsolvent();
    vm.prank(guardian);
    srm.setAdjustmentsPaused(true);

    auction.startAuction(aliceAcc, 0);
    vm.warp(block.timestamp + auction.getAuctionParams().insolventAuctionLength);
    _setPrices(0.000432e18);
    vm.prank(charlie);
    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    assertEq(_perpBalance(aliceAcc), 10_000_000e18, "the position is still open");

    vm.prank(guardian);
    srm.setAdjustmentsPaused(false);
    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
    assertEq(_perpBalance(aliceAcc), 0, "liquidation completes after the unpause");
  }

  function _perpTransfer(uint fromAcc, uint toAcc, int amount)
    internal
    view
    returns (ISubAccounts.AssetTransfer[] memory transfers)
  {
    transfers = new ISubAccounts.AssetTransfer[](1);
    transfers[0] = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: bytes32(0)
    });
  }

  // --- SecurityModule exposure at the launch cap ----------------------------------

  /// The launch cap, 50M cNGN, counts both sides: 25M long against 25M short.
  int constant CAP_SIDE = 25_000_000e18;

  /**
   * What the SecurityModule pays for an index jump at the full launch cap, in the worst case the
   * keeper can leave behind: the ENTIRE long side held by one account sitting just above
   * maintenance margin when the index falls, and the insolvent auction run to its last second
   * (the most the SM ever pays a bidder). A 10% jump is the question; the larger ones say where
   * the SecurityModule actually starts paying.
   *
   * Two things this does not model, both of which only make it more conservative: the index
   * publisher refuses any move over 300bps without an operator's accept (so a 10% jump halts the
   * market first), and a keeper that bids as soon as the payout covers the deficit pays less than
   * the auction's floor.
   */
  function testSecurityModuleLossFromIndexJumpAtFullCap() public {
    perp.setTotalPositionCap(srm, 2 * uint(CAP_SIDE));
    _fundSecurityModule(1_000_000e6); // deep enough that nothing socializes: we measure the SM alone

    uint16[6] memory jumpsBps = [uint16(1_000), 2_000, 2_500, 3_000, 4_000, 5_000];
    for (uint i; i < jumpsBps.length; ++i) {
      uint snapshot = vm.snapshotState();
      (int mtmAfter, uint smPaid) = _jumpAtCap(jumpsBps[i]);
      console2.log("jump bps:", jumpsBps[i]);
      console2.log("  equity after jump ($, 18dp, signed):", mtmAfter);
      console2.log("  security module paid ($, 18dp):", smPaid);
      if (jumpsBps[i] == 1_000) {
        assertGt(mtmAfter, 0, "an account at MM survives a 10% jump solvent");
        assertEq(smPaid, 0, "a 10% jump at the full cap must cost the SecurityModule nothing");
      }
      vm.revertToState(snapshot);
    }
  }

  /// Opens the full long side on one account, walks the index to just above its maintenance
  /// margin, then drops the index by `jumpBps` and liquidates. Returns equity after the jump and
  /// what the SecurityModule paid out.
  function _jumpAtCap(uint jumpBps) internal returns (int mtmAfter, uint smPaid) {
    // Alice opens at the initial margin, 1/3 of $18,000.
    _deposit(alice, aliceAcc, 6_001e6);
    _deposit(bob, bobAcc, 100_000e6);
    _deposit(charlie, charlieAcc, 100_000e6);
    _tradePerp(bobAcc, aliceAcc, CAP_SIDE);
    assertGe(srm.getMargin(aliceAcc, true), 0, "alice opens within initial margin");

    // Equity D + N(p - p0) meets mm*N*p at p = (N*p0 - D) / (N*(1 - mm)); sit 5bps above it.
    uint n = uint(CAP_SIDE);
    uint atMM = (n * INDEX_PRICE / 1e18 - 6_001e18) * 1e18 / (n * 0.8e18 / 1e18);
    uint96 preJump = uint96(atMM * 10_005 / 10_000);
    _setPrices(preJump);
    int mmMargin = srm.getMargin(aliceAcc, false);
    assertGe(mmMargin, 0, "alice sits above maintenance margin");
    assertLt(mmMargin, 50e18, "and only just: within $50 of it");

    uint96 postJump = uint96(uint(preJump) * (10_000 - jumpBps) / 10_000);
    _setPrices(postJump);
    (, mtmAfter) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);

    uint smAcc = securityModule.accountId();
    int smBefore = _cash(smAcc);
    auction.startAuction(aliceAcc, 0);
    if (auction.getAuction(aliceAcc).insolvent) {
      vm.warp(block.timestamp + auction.getAuctionParams().insolventAuctionLength);
      _setPrices(postJump);
      vm.prank(charlie);
      auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
      assertEq(_perpBalance(aliceAcc), 0, "the insolvent auction must close the whole position");
    }
    int smAfter = _cash(smAcc);
    smPaid = smAfter < smBefore ? uint(smBefore - smAfter) : 0;
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "a funded SecurityModule must cover it without socializing");
  }

  // --- scenario helpers ------------------------------------------------------------

  /// Alice longs 10M cNGN on $2,500, just over the 33% IM, then NGN falls 40%.
  function _openInsolvent() internal {
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _deposit(charlie, charlieAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    assertGe(srm.getMargin(aliceAcc, true), 0, "alice opens within initial margin");

    // A $2,880 loss on $2,500 of equity: underwater.
    _setPrices(0.000432e18);
    (, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertLt(mtm, 0, "alice must be insolvent, not just under margin");
  }

  function _runInsolventAuction() internal {
    auction.startAuction(aliceAcc, 0);
    // Underwater at the start, the auction opens straight in insolvency mode; one that is not
    // would have to run out its solvent phase and be converted.
    assertTrue(auction.getAuction(aliceAcc).insolvent, "auction must open insolvent");

    IDutchAuction.AuctionParams memory params = auction.getAuctionParams();
    vm.warp(block.timestamp + params.insolventAuctionLength);
    _setPrices(0.000432e18);
    assertLt(auction.getCurrentBidPrice(aliceAcc), 0, "an insolvent bid is paid, not charged");

    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
  }

  // --- deployment, mirroring deploy-core.s.sol with the live SubAccounts ------------

  function _deployStack() internal {
    (uint minRate, uint rateMultiplier, uint highRateMultiplier, uint optimalUtil) =
      Config.getDefaultInterestRateModel();
    rateModel = new InterestRateModel(minRate, rateMultiplier, highRateMultiplier, optimalUtil);
    cash = new CashAsset(subAccounts, IERC20Metadata(USDC), rateModel);
    viewer = new SRMPortfolioViewer(subAccounts, cash);
    srm = new StandardManager(subAccounts, cash, IDutchAuction(address(0)), viewer);
    securityModule = new SecurityModule(subAccounts, cash, srm);
    auction = new DutchAuction(subAccounts, securityModule, cash);
    srm.setLiquidation(auction);

    stableFeed = new LyraStaticSpotFeed();
    stableFeed.setSpot(1e18, 1e18);

    viewer.setStandardManager(srm);
    auction.setSMAccount(securityModule.accountId());
    auction.setWhitelistManager(address(srm), true);
    cash.setLiquidationModule(auction);
    cash.setSmFeeRecipient(securityModule.accountId());
    cash.setSmFee(Config.CASH_SM_FEE);
    auction.setAuctionParams(Config.getDefaultAuctionParam());
    securityModule.setWhitelistModule(address(auction), true);
    cash.setWhitelistManager(address(srm), true);

    srm.setMaxAccountSize(Config.MAX_ACCOUNT_SIZE_SRM);
    srm.setBorrowingEnabled(true);
    srm.setStableFeed(stableFeed);
    srm.setDepegParameters(Config.getSRMDepegParams());
  }

  function _deployPerp() internal {
    indexFeed = new LyraSpotFeed();
    markFeed = new LyraSpotDiffFeed(indexFeed);
    impactAskFeed = new LyraSpotDiffFeed(indexFeed);
    impactBidFeed = new LyraSpotDiffFeed(indexFeed);

    indexFeed.setHeartbeat(20 minutes);
    markFeed.setHeartbeat(Config.PERP_HEARTBEAT);
    impactAskFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    impactBidFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    // The mark may sit up to 50% from the index here so a 40% crash is not clipped; the
    // production cap is a phase 1 decision.
    markFeed.setSpotDiffCap(0.5e18);
    impactAskFeed.setSpotDiffCap(0.5e18);
    impactBidFeed.setSpotDiffCap(0.5e18);
    indexFeed.addSigner(keeper, true);
    markFeed.addSigner(keeper, true);
    impactAskFeed.addSigner(keeper, true);
    impactBidFeed.addSigner(keeper, true);

    perp = new PerpAsset(subAccounts);
    perp.setSpotFeed(indexFeed);
    perp.setPerpFeed(markFeed);
    perp.setImpactFeeds(impactAskFeed, impactBidFeed);
    (int staticRate, int rateCap, uint convergence) = Config.getPerpParams();
    perp.setStaticInterestRate(staticRate);
    perp.setRateBounds(rateCap);
    perp.setConvergencePeriod(convergence);
    perp.setWhitelistManager(address(srm), true);
    perp.setTotalPositionCap(srm, 1_000_000_000e18); // 1B NGN (~$720k); low-cap is phase 1

    uint marketId = srm.createMarket("NGN");
    srm.whitelistAsset(perp, marketId, IStandardManager.AssetType.Perpetual);
    srm.setOraclesForMarket(marketId, indexFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    (IStandardManager.PerpMarginRequirements memory perpReqs,, IStandardManager.OracleContingencyParams memory oc,) =
      Config.getSRMParams("NGN");
    srm.setPerpMarginRequirements(marketId, perpReqs.mmPerpReq, perpReqs.imPerpReq);
    srm.setOracleContingencyParams(marketId, oc);

    _setPrices(INDEX_PRICE);
  }

  // --- chain interaction -----------------------------------------------------------

  function _deposit(address user, uint acc, uint usdcAmount) internal {
    deal(USDC, user, IERC20Metadata(USDC).balanceOf(user) + usdcAmount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(address(cash), usdcAmount);
    cash.deposit(acc, usdcAmount);
    vm.stopPrank();
  }

  function _fundSecurityModule(uint usdcAmount) internal {
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(address(securityModule), usdcAmount);
    securityModule.donate(usdcAmount);
  }

  /// `fromAcc` sends `amount` of perp to `toAcc` at the mark: positive makes `toAcc` long.
  function _tradePerp(uint fromAcc, uint toAcc, int amount) internal {
    ISubAccounts.AssetTransfer[] memory transfers = new ISubAccounts.AssetTransfer[](1);
    transfers[0] = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: bytes32(0)
    });
    subAccounts.submitTransfers(transfers, "");
  }

  /// Settles an account's perp PnL and funding into cash, as any adjustment would.
  function _realize(uint acc) internal {
    srm.settlePerpsWithIndex(acc);
  }

  /// Moves index, mark and both impact prices to `price` (no premium, so funding is static).
  function _setPrices(uint96 price) internal {
    vm.warp(block.timestamp + 1);
    _sign(indexFeed, abi.encode(price, uint64(1e18)));
    _sign(markFeed, abi.encode(int96(0), uint64(1e18)));
    _sign(impactAskFeed, abi.encode(int96(0), uint64(1e18)));
    _sign(impactBidFeed, abi.encode(int96(0), uint64(1e18)));
  }

  function _sign(BaseLyraFeed feed, bytes memory data) internal {
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: data,
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    bytes32 structHash =
      keccak256(abi.encode(feed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp));
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(keeperPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = keeper;
    IDataReceiver(address(feed)).acceptData(abi.encode(feedData));
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  function _perpBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, perp, 0);
  }
}
