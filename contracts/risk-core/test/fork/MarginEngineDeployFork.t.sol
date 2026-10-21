// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployMarginEngine} from "../../scripts/deploy-margin-engine.s.sol";
import {MarginEngineV1 as MarginEngine} from "../../src/legacy/v1/MarginEngineV1.sol";
import {PerpAsset} from "../../src/assets/PerpAsset.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {DutchAuction} from "../../src/liquidation/DutchAuction.sol";
import {SecurityModule} from "../../src/SecurityModule.sol";
import {IDutchAuction} from "../../src/interfaces/IDutchAuction.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {StandardManager} from "../../src/risk-managers/StandardManager.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {ISpotDiffFeed} from "../../src/interfaces/ISpotDiffFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {BaseLyraFeed} from "../../src/feeds/BaseLyraFeed.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

interface IOwnableLike {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

interface ITradeModuleLike {
  function isDatedFutureAsset(address) external view returns (bool);
}

/**
 * Runs deploy-margin-engine.s.sol's own `deploy` on a Base fork at head, plays the vault's side by executing the
 * generated batches exactly as written, and proves on the live stack that:
 *   - market 1 on the engine margins spot and the perp exactly as market 1 on the live SRM does (parity);
 *   - spot cNGN, the perp and the future share one engine account;
 *   - a future lives through its whole life on the live perp cash, cNGN escrow, index feed, auction and SecurityModule:
 *     open, marks, the index fixing, close-out, and withdrawal of real USDC and cNGN;
 *   - the live SRM is never touched.
 *
 * At head because it is about deploying into the world as it is now. The index feed goes stale once the test warps
 * past its heartbeat, so from the first warp it is held at its live value with mockCall; that is the only thing
 * mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract MarginEngineDeployFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

  uint64 constant EXPIRY = 1796047200;
  uint constant CARRY = 0.2e18;
  // The perp cap the 2026-10-13 deploy used. PERP_OI_CAP is required since the perp's delisting (the SRM's cap, which
  // the script used to read, is 0: tx 0x77efbb84…, 2026-10-21), so the rehearsal passes the value it deployed with.
  uint constant DEPLOYED_PERP_OI_CAP = 50_000_000e18;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address treasury = address(0x7ea5);

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint forwardPk = uint(keccak256("cngn-future-deploy-fork-forward-signer"));
  address forwardSigner = vm.addr(forwardPk);

  DeployMarginEngine script;
  DeployMarginEngine.Params params;
  DeployMarginEngine.Deployment d;
  SubAccounts subAccounts;

  uint spot; // USDC per cNGN, live
  uint index; // cNGN per USDC
  uint perpMarketsBefore;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    script = new DeployMarginEngine();

    // The initial mark is the operator's input, checked against index * (1 + carry * tau); here it is exactly that.
    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json"));
    (spot,) = ISpotFeed(vm.parseJsonAddress(stack, ".indexFeed")).getSpot();
    index = 1e36 / spot;
    uint tau = uint(EXPIRY) - block.timestamp;
    uint initialMark = index + index * CARRY / 1e18 * tau / 365 days;
    vm.setEnv("CARRY", vm.toString(CARRY));
    vm.setEnv("INITIAL_MARK", vm.toString(initialMark));
    vm.setEnv("FORWARD_SIGNER", vm.toString(forwardSigner));
    vm.setEnv("PERP_OI_CAP", vm.toString(DEPLOYED_PERP_OI_CAP));

    params = script.loadParams();
    // The environment is one per process and forge runs suites in parallel: another fork suite can set these between
    // the setEnv above and loadParams. This suite's own values, put back and checked again, are what it deploys with.
    params.carry = CARRY;
    params.perpOICap = DEPLOYED_PERP_OI_CAP;
    params.initialMark = initialMark;
    params.forwardSigner = forwardSigner;
    script.checkParams(params);
    subAccounts = SubAccounts(params.subAccounts);
    perpMarketsBefore = StandardManager(params.srm).lastMarketId();
    d = script.deploy(params);
  }

  ///////////////////
  //  the script   //
  ///////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(d, params);
  }

  function testInitialMarkOutsideTheIndexBandIsRefused() public {
    DeployMarginEngine.Params memory p = params;
    p.initialMark = index * 111 / 100;
    vm.expectRevert(bytes("INITIAL_MARK is outside the index band"));
    script.checkParams(p);
  }

  function testInitialMarkOffTheCarryForwardIsRefused() public {
    DeployMarginEngine.Params memory p = params;
    uint fair = script.fairForward(p);
    p.initialMark = fair * 103 / 100; // inside the 10% spot band, 3% off the carry forward
    assertLt(p.initialMark, index * 110 / 100, "the spot band alone would pass it");
    vm.expectRevert(bytes("INITIAL_MARK is outside the band around index * (1 + carry * tau)"));
    script.checkParams(p);

    p.initialMark = fair * 1019 / 1000;
    script.checkParams(p);
  }

  function testCarryInTheWrongUnitsIsRefused() public {
    DeployMarginEngine.Params memory p = params;
    p.carry = 20e18; // "20" for 20%
    vm.expectRevert(bytes("CARRY over 100% a year: give it 18dp (0.2e18 for 20%)"));
    script.checkParams(p);
  }

  function testLaunchMarginIsIM25MM15() public view {
    (uint mm, uint im) = d.engine.futureMarginRequirements(d.marketId);
    assertEq(im, 0.25e18);
    assertEq(mm, 0.15e18);
  }

  function testLastTradeAfterTheFixingWindowStartIsRefused() public {
    DeployMarginEngine.Params memory p = params;
    p.lastTradeTime = p.expiry - 30 minutes;
    vm.expectRevert(bytes("last trade must be no later than the fixing window's start"));
    script.checkParams(p);
  }

  /**
   * BaseManager is upgradeable-shaped since Lyra #362 (Ownable2StepUpgradeable, storage for what were immutables), but
   * the engine is deployed directly: its constructor sets the owner and every field, and no initializer is exposed.
   * Straight after deploy the deployer owns it with the vault nominated; nobody else can take it, call an initializer,
   * or rewrite its wiring; the vault owns it once the setup batch accepts.
   */
  function testTheEngineIsOwnedFromItsConstructorAndNothingCanInitializeIt() public {
    MarginEngine engine = d.engine;
    assertEq(engine.owner(), address(script), "the deployer owns it from the constructor");
    assertEq(engine.pendingOwner(), VAULT, "with the vault nominated");
    assertEq(address(engine.subAccounts()), params.subAccounts, "the constructor set SubAccounts");
    assertEq(address(engine.cashAsset()), params.cash, "and the cash");
    assertEq(subAccounts.ownerOf(engine.accId()), address(engine), "and opened its own account");

    address stranger = address(0xbad);
    // no initializer of any shape: BaseManagerUpgradeable's is internal, and the engine does not inherit it
    string[4] memory inits = [
      "initialize()",
      "initialize(address)",
      "initialize(address,address,address,address)",
      "__BaseManagerUpgradeable_init(address,address,address,address)"
    ];
    for (uint i; i < inits.length; ++i) {
      vm.prank(stranger);
      (bool ok,) = address(engine).call(abi.encodeWithSignature(inits[i], stranger, stranger, stranger, stranger));
      assertFalse(ok, string.concat("no initializer: ", inits[i]));
    }
    vm.prank(stranger);
    vm.expectRevert();
    engine.acceptOwnership();
    vm.prank(stranger);
    vm.expectRevert();
    engine.transferOwnership(stranger);
    vm.prank(stranger);
    vm.expectRevert();
    engine.setLiquidation(IDutchAuction(stranger));

    _executeVaultBatch();
    assertEq(engine.owner(), VAULT, "the vault owns it once the setup batch accepts");
    assertEq(engine.pendingOwner(), address(0));
    assertEq(address(engine.subAccounts()), params.subAccounts, "wiring unchanged");
  }

  function testVaultBatchHandsOverAndWires() public {
    address[] memory owned = script.ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      assertEq(IOwnableLike(owned[i]).owner(), address(script), "deployer owns until accepted");
    }

    _executeVaultBatch();

    for (uint i = 0; i < owned.length; i++) {
      assertEq(IOwnableLike(owned[i]).owner(), VAULT, "vault must own every contract");
      assertEq(IOwnableLike(owned[i]).pendingOwner(), address(0), "no nomination left pending");
    }
    assertTrue(CashAsset(params.cash).whitelistedManager(address(d.engine)), "cash takes the manager");
    assertTrue(WrappedERC20Asset(params.cngnEscrow).whitelistedManager(address(d.engine)), "escrow takes it");
    assertEq(WrappedERC20Asset(params.cngnEscrow).totalPositionCap(d.engine), params.engineCngnCap);
    assertTrue(DutchAuction(params.auction).managerWhitelisted(address(d.engine)), "auction takes it");
    assertTrue(PerpAsset(params.perp).whitelistedManager(address(d.engine)), "the perp takes it");
    assertEq(PerpAsset(params.perp).totalPositionCap(d.engine), 0, "but stays closed under it");
    assertEq(d.engine.guardian(), params.guardian, "the SRM's guardian");

    vm.prank(address(script));
    vm.expectRevert();
    d.future.setTotalPositionCap(d.engine, type(uint).max);
  }

  function testDeploysClosedUntilTheEnableBatch() public {
    _executeVaultBatch();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    // read before expectRevert: an external call in the arguments would be the call it expects to revert
    uint mark = d.future.futureContracts(d.subId).markPrice;
    vm.expectRevert(bytes4(keccak256("BM_AssetCapExceeded()")));
    _trade(bobAcc, aliceAcc, 1e18, mark);

    _executeEnableBatch();
    assertEq(d.future.totalPositionCap(d.engine), params.futureOICap);
    assertEq(PerpAsset(params.perp).totalPositionCap(d.engine), params.perpOICap, "the perp opens on the engine");
    assertTrue(ITradeModuleLike(params.perpTradeModule).isDatedFutureAsset(address(d.future)), "registered");
    _trade(bobAcc, aliceAcc, 1e18, mark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);
  }

  function testTheLiveSrmIsUntouched() public {
    StandardManager srm = StandardManager(params.srm);
    uint perpCapBefore = PerpAsset(params.perp).totalPositionCap(srm);
    uint escrowCapBefore = WrappedERC20Asset(params.cngnEscrow).totalPositionCap(srm);
    _executeVaultBatch();
    _executeEnableBatch();
    assertEq(srm.lastMarketId(), perpMarketsBefore, "srm gained a market");
    assertFalse(d.future.whitelistedManager(params.srm), "future must not accept the srm");
    assertEq(address(srm.cashAsset()), params.cash, "srm cash moved");
    assertEq(
      PerpAsset(params.perp).totalPositionCap(srm), perpCapBefore, "the srm's perp cap is the cutover's to change"
    );
    assertEq(WrappedERC20Asset(params.cngnEscrow).totalPositionCap(srm), escrowCapBefore, "the srm's escrow cap moved");
    assertTrue(PerpAsset(params.perp).whitelistedManager(params.srm), "the perp still takes the srm");
  }

  ///////////////////
  //    parity     //
  ///////////////////

  /**
   * The same spot and perp portfolio, held once under the live SRM and once under the engine: identical initial
   * margin, maintenance margin and mark-to-market, on the live perp, cash, escrow and feeds.
   */
  function testSpotAndPerpMarginExactlyAsOnTheLiveSrm() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdPerpFeeds(spot);
    IManager srm = IManager(params.srm);
    // The perp is delisted and its SRM cap is 0 on chain; on this fork only, the vault reopens it so the SRM side of
    // the comparison can hold a position at all.
    vm.prank(params.vault);
    PerpAsset(params.perp).setTotalPositionCap(srm, DEPLOYED_PERP_OI_CAP);

    (uint srmLong, uint srmShort) = (_accountUnder(alice, srm), _accountUnder(bob, srm));
    (uint engLong, uint engShort) = (_account(alice), _account(bob));
    uint[4] memory accs = [srmLong, srmShort, engLong, engShort];
    for (uint i; i < 4; ++i) {
      _depositUsdc(i % 2 == 0 ? alice : bob, accs[i], 1_000e6);
      _depositCngn(i % 2 == 0 ? alice : bob, accs[i], 400_000e6);
    }
    // 1,000,000 cNGN of perp each, about $730 of notional
    _tradePerp(srmShort, srmLong, 1_000_000e18);
    _tradePerp(engShort, engLong, 1_000_000e18);

    for (uint i; i < 2; ++i) {
      (uint onSrm, uint onEngine) = (accs[i], accs[i + 2]);
      for (uint im; im < 2; ++im) {
        (int srmMargin, int srmMtm) = StandardManager(params.srm).getMarginAndMarkToMarket(onSrm, im == 1, 0);
        (int engMargin, int engMtm) = d.engine.getMarginAndMarkToMarket(onEngine, im == 1, 0);
        assertEq(engMargin, srmMargin, im == 1 ? "initial margin as on the srm" : "maintenance margin as on the srm");
        assertEq(engMtm, srmMtm, "mark-to-market as on the srm");
      }
    }
  }

  /// @dev Spot cNGN, the perp and the future in one engine account: one margin, gross in v1. The future adds exactly
  ///      its own requirement, and its unsettled VM, to the spot-and-perp margin the SRM would give.
  function testSpotPerpAndFutureInOneEngineAccount() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdPerpFeeds(spot);
    _depositCngn(treasury, d.poolAccount, 1_000_000e6);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _tradePerp(bobAcc, aliceAcc, 1_000_000e18);
    (int imSpotPerp, int mmSpotPerp) = (d.engine.getMargin(aliceAcc, true), d.engine.getMargin(aliceAcc, false));

    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 1e18, mark0);
    assertEq(d.engine.getMargin(aliceAcc, true), imSpotPerp - 250e18, "plus 25% of the 1,000 USDC contract");
    assertEq(d.engine.getMargin(aliceAcc, false), mmSpotPerp - 150e18, "plus 15% at maintenance");

    // a day later the forward is 2% up: alice is due 2% of the mark on 1,000 USDC, in cNGN, before anyone settles
    vm.warp(block.timestamp + 1 days);
    _holdPerpFeeds(spot);
    uint mark1 = mark0 * 102 / 100;
    vm.prank(VAULT);
    d.future.setMark(d.subId, uint64(block.timestamp), mark1);
    int due = int(1_000 * (mark1 - mark0));
    assertEq(d.future.getPendingVM(aliceAcc, d.subId), due);
    int mmUnsettled = d.engine.getMargin(aliceAcc, false);
    d.engine.settleAccount(aliceAcc);
    d.engine.settleAccount(bobAcc);
    assertEq(_cngnBalance(aliceAcc), 500_000e18 + due, "paid in spot cNGN, in the same account");
    assertEq(d.engine.getMargin(aliceAcc, false), mmUnsettled, "margin reads the same settled or not");
  }

  ///////////////////
  //   lifecycle   //
  ///////////////////

  function testPositionLivesAndSettlesInCngnOnTheRealStack() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);

    // treasury seeds the VM pool with 1,000,000 cNGN
    _depositCngn(treasury, d.poolAccount, 1_000_000e6);

    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 2e18, mark0); // alice long 2 contracts (2,000 USDC)

    // a day later the forward is 2% higher: alice is paid 2 * 1,000 * 2% of the mark, in cNGN
    vm.warp(block.timestamp + 1 days);
    uint mark1 = mark0 * 102 / 100;
    vm.prank(VAULT);
    d.future.setMark(d.subId, uint64(block.timestamp), mark1);

    int expectedVM = int(2 * 1_000 * (mark1 - mark0));
    assertEq(d.future.getPendingVM(aliceAcc, d.subId), expectedVM);
    d.engine.settleAccount(bobAcc);
    d.engine.settleAccount(aliceAcc);
    assertEq(_cngnBalance(aliceAcc), 500_000e18 + expectedVM, "alice paid in cNGN");
    assertEq(_cngnBalance(bobAcc), 500_000e18 - expectedVM, "bob paid in cNGN");
    assertEq(_cngnBalance(d.poolAccount), 1_000_000e18, "pool back to its reserve");

    // the fixing: the index sampled every 10 minutes over the last hour, flat at the live index
    uint64 expiry = params.expiry;
    for (uint t = expiry - 1 hours; t <= expiry; t += 10 minutes) {
      vm.warp(t);
      d.future.recordFixingSample(d.subId);
    }
    vm.warp(expiry);
    vm.prank(address(0xf1));
    d.future.fixSettlementFromIndex(d.subId); // anyone
    assertEq(d.future.futureContracts(d.subId).markPrice, index, "settles at the index");

    // the last leg converges alice back from mark1 to the index
    d.engine.closeOutExpired(bobAcc, d.subId);
    d.engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 0);
    assertEq(subAccounts.getBalance(bobAcc, d.future, d.subId), 0);
    assertEq(d.future.totalPosition(d.engine), 0, "no open interest left");

    int aliceTotal = int(2 * 1_000) * (int(index) - int(mark0));
    assertEq(_cngnBalance(aliceAcc), 500_000e18 + aliceTotal, "in all, alice made index - entry");
    assertEq(_cngnBalance(d.poolAccount), 1_000_000e18, "and the pool is whole");

    // real tokens out
    uint cngnOut = uint(_cngnBalance(aliceAcc)) / 1e12;
    vm.prank(alice);
    WrappedERC20Asset(params.cngnEscrow).withdraw(aliceAcc, cngnOut, alice);
    assertEq(IERC20Metadata(CNGN).balanceOf(alice), cngnOut);
    vm.prank(alice);
    CashAsset(params.cash).withdraw(aliceAcc, 1_000e6, alice);
    assertEq(IERC20Metadata(USDC).balanceOf(alice), 1_000e6);
  }

  function testShortfallFallsBackToTheRealUsdcCash() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);

    // no pool reserve, and alice holds no cNGN: the winner is paid in USDC cash at the index
    uint aliceAcc = _account(alice);
    uint bobAcc = _account(bob);
    _depositUsdc(alice, aliceAcc, 1_000e6);
    _depositUsdc(bob, bobAcc, 1_000e6);
    _depositCngn(bob, bobAcc, 500_000e6);
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 1e18, mark0);

    vm.warp(block.timestamp + 1 days);
    vm.prank(VAULT);
    d.future.setMark(d.subId, uint64(block.timestamp), mark0 * 102 / 100);

    // accrue interest first, so the delta below is the VM payment alone
    d.engine.settleInterest(aliceAcc);
    int cashBefore = subAccounts.getBalance(aliceAcc, _cash(), 0);
    d.engine.settleAccount(aliceAcc);
    int cashAfter = subAccounts.getBalance(aliceAcc, _cash(), 0);
    uint vmCngn = 1_000 * (mark0 * 102 / 100 - mark0);
    assertApproxEqAbs(cashAfter - cashBefore, int(vmCngn * spot / 1e18), 1, "paid the cNGN's value in USDC");
    assertLt(subAccounts.getBalance(d.poolAccount, _cash(), 0), 0, "the pool owes the cash until treasury tops up");
  }

  ///////////////////
  // forward marks //
  ///////////////////

  /// @dev Publish a forward for this contract's expiry, signed by the forward key: forward = index + `diff`.
  function _publishForward(int96 diff) internal {
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: abi.encode(params.expiry, uint(0), uint(0), diff, uint64(1e18)),
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    BaseLyraFeed feed = BaseLyraFeed(address(d.forwardFeed));
    bytes32 structHash =
      keccak256(abi.encode(feed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp));
    (uint8 v, bytes32 r, bytes32 sig) =
      vm.sign(forwardPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, sig, bytes1(v));
    feedData.signers[0] = forwardSigner;
    d.forwardFeed.acceptData(abi.encode(feedData));
  }

  function testMarksArePulledFromTheSignedForwardFeed() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    _depositCngn(treasury, d.poolAccount, 1_000_000e6);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 1e18, mark0);

    // the forward 2% under spot in USDC per cNGN: ~2% over the index in cNGN per USDC
    vm.warp(block.timestamp + 1 hours);
    int96 diff = -int96(int(spot * 2 / 100));
    _publishForward(diff);

    vm.prank(address(0xbeef)); // anyone
    d.future.pullMark(d.subId);
    uint mark1 = 1e36 / uint(int(spot) + diff);
    assertEq(d.future.futureContracts(d.subId).markPrice, mark1, "the inverse of index + diff");
    assertEq(
      d.future.getPendingVM(aliceAcc, d.subId), int(1_000) * (int(mark1) - int(mark0)), "VM from the pulled mark"
    );

    // not again within the hour
    vm.warp(block.timestamp + 30 minutes);
    vm.expectRevert(IFutureAsset.FA_MarkTooSoon.selector);
    d.future.pullMark(d.subId);
  }

  function testAForwardSignedByAnyoneElseIsRefused() public {
    _executeVaultBatch();
    _holdIndex(spot);
    uint pk = uint(keccak256("not-the-forward-signer"));
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: abi.encode(params.expiry, uint(0), uint(0), int96(0), uint64(1e18)),
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    BaseLyraFeed feed = BaseLyraFeed(address(d.forwardFeed));
    bytes32 structHash =
      keccak256(abi.encode(feed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp));
    (uint8 v, bytes32 r, bytes32 sig) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, sig, bytes1(v));
    feedData.signers[0] = vm.addr(pk);
    vm.expectRevert();
    d.forwardFeed.acceptData(abi.encode(feedData));
  }

  function testTheForwardSignerMustNotSignTheIndex() public {
    DeployMarginEngine.Params memory p = params;
    vm.prank(VAULT);
    BaseLyraFeed(params.indexFeed).addSigner(p.forwardSigner, true);
    vm.expectRevert(bytes("FORWARD_SIGNER must not also sign the index"));
    script.checkParams(p);
  }

  ///////////////////
  //     rally     //
  ///////////////////

  /// @dev Move the index by `bps` (cNGN per USDC up, so USDC per cNGN down) and mark the future with it, a day later.
  function _rallyStep(uint bps) internal returns (uint mark) {
    spot = spot * 10_000 / (10_000 + bps);
    _holdIndex(spot);
    mark = d.future.futureContracts(d.subId).markPrice * (10_000 + bps) / 10_000;
    vm.warp(block.timestamp + 1 days);
    vm.prank(VAULT);
    d.future.setMark(d.subId, uint64(block.timestamp), mark);
  }

  function _mtm(uint acc) internal view returns (int mtm) {
    (, mtm) = d.engine.getMarginAndMarkToMarket(acc, false, 0);
  }

  /**
   * The index rises ~15% over four daily marks. Longs are paid in cNGN, fronted by the pool reserve; shorts that hold no
   * cNGN pay in USDC; two shorts fall below maintenance and one is liquidated through the real auction. At IM 25% none
   * goes insolvent: the move costs about 13% of notional against 25% posted.
   */
  function testIndexRallyOfFifteenPercent() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    _depositCngn(treasury, d.poolAccount, 2_000_000e6);

    uint aliceAcc = _account(alice);
    uint bobAcc = _account(bob);
    uint carolAcc = _account(address(0xca401));
    _depositUsdc(alice, aliceAcc, 2_000e6);
    _depositUsdc(bob, bobAcc, 530e6); // IM 500 on two contracts
    _depositUsdc(address(0xca401), carolAcc, 260e6); // IM 250 on one
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 2e18, mark0);
    _trade(carolAcc, aliceAcc, 1e18, mark0);

    for (uint i; i < 4; ++i) {
      _rallyStep(350); // +3.5%, inside the 5% mark limit and the 10% index band
      // the long is settled first each day: the reserve pays it before the shorts have paid in
      uint poolBefore = uint(_cngnBalance(d.poolAccount));
      d.engine.settleAccount(aliceAcc);
      assertLt(uint(_cngnBalance(d.poolAccount)), poolBefore, "the reserve fronted the long");
    }
    uint markEnd = d.future.futureContracts(d.subId).markPrice;
    assertApproxEqRel(markEnd, mark0 * 11475 / 10_000, 0.001e18, "about 14.75% up");

    // alice holds the cNGN the four marks paid her
    assertEq(_cngnBalance(aliceAcc), int(3 * 1_000 * (markEnd - mark0)), "long paid in cNGN, fronted by the pool");

    // the shorts have paid nothing yet; both are below maintenance, neither is insolvent
    assertLt(d.engine.getMargin(bobAcc, false), 0, "bob below MM");
    assertLt(d.engine.getMargin(carolAcc, false), 0, "carol below MM");
    assertGt(_mtm(bobAcc), 0, "bob still solvent");
    assertGt(_mtm(carolAcc), 0, "carol still solvent");

    // bob is liquidated through the real auction: the start settles his VM, in USDC since he holds no cNGN
    DutchAuction auction = DutchAuction(params.auction);
    int poolCashBefore = subAccounts.getBalance(d.poolAccount, _cash(), 0);
    auction.startAuction(bobAcc, 0);
    assertGt(subAccounts.getBalance(d.poolAccount, _cash(), 0), poolCashBefore, "bob paid the pool in USDC");

    address dave = address(0xda5e);
    uint daveAcc = _account(dave);
    _depositUsdc(dave, daveAcc, 5_000e6);
    vm.prank(dave);
    (uint pct,,) = auction.bid(bobAcc, daveAcc, 1e18, 0, 0);
    assertGt(pct, 0, "dave took part of bob");
    assertLt(subAccounts.getBalance(daveAcc, d.future, d.subId), 0, "dave holds the short he bought");
    assertGt(subAccounts.getBalance(bobAcc, d.future, d.subId), -2e18, "bob's short shrank");
  }

  /**
   * Past the 10-15% case: carol's short is left unliquidated while the index keeps rising, until her losses exceed her
   * collateral. Her insolvent auction is paid from the perp stack's real SecurityModule.
   */
  function testUnliquidatedRallyDrawsOnTheSecurityModule() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    _depositCngn(treasury, d.poolAccount, 2_000_000e6);

    uint aliceAcc = _account(alice);
    uint carolAcc = _account(address(0xca401));
    _depositUsdc(alice, aliceAcc, 2_000e6);
    _depositUsdc(address(0xca401), carolAcc, 260e6);
    _trade(carolAcc, aliceAcc, 1e18, d.future.futureContracts(d.subId).markPrice);

    // ~+47% over nine marks with nobody liquidating
    for (uint i; i < 9; ++i) {
      _rallyStep(450);
    }
    assertLt(_mtm(carolAcc), 0, "carol's losses now exceed her collateral");

    DutchAuction auction = DutchAuction(params.auction);
    uint smAcc = vm.parseJsonUint(
      vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json")), ".securityModuleAccount"
    );
    // accrue the SecurityModule's interest first, so the delta below is the payout alone
    StandardManager(params.srm).settleInterest(smAcc);
    int smBefore = subAccounts.getBalance(smAcc, _cash(), 0);
    auction.startAuction(carolAcc, 0);
    (bool insolvent) = _isInsolvent(carolAcc);
    assertTrue(insolvent, "insolvent auction");

    address eve = address(0xe7e);
    uint eveAcc = _account(eve);
    _depositUsdc(eve, eveAcc, 5_000e6);
    vm.prank(eve);
    (,, uint cashToBidder) = auction.bid(carolAcc, eveAcc, 1e18, 0, 0);

    assertGt(cashToBidder, 0, "the bidder is paid to take the account");
    assertEq(smBefore - subAccounts.getBalance(smAcc, _cash(), 0), int(cashToBidder), "paid by the SecurityModule");
    assertEq(subAccounts.getBalance(eveAcc, d.future, d.subId), -1e18, "eve holds carol's short");
    assertEq(subAccounts.getBalance(carolAcc, d.future, d.subId), 0, "carol is closed out");
  }

  ///////////////////////////////////
  //  SecurityModule coverage fit  //
  ///////////////////////////////////

  struct Coverage {
    int equityAfter;
    bool insolvent;
    uint smPaidAtEnd;
    uint smPaidKeeper;
    uint keeperBidAfterSec;
    uint oneSideUsd;
    uint premium; // mark / index, 18dp: the short's loss per dollar of notional per unit of move
  }

  /// @dev The naira loses `s` (18dp) of its USD value: the index and the mark both rise by 1 / (1 - s), in marks of at
  ///      most 4.5% a day, inside the 5% mark limit and the index band. Nobody is liquidated on the way. `settleAcc` is
  ///      settled after every mark, as the keepers settle losers in production: left unsettled, a short's VM is a cNGN
  ///      debt, and the naira's fall shrinks its dollar value, flattering the account by the old debt x s.
  function _devalueBy(uint s, uint settleAcc) internal {
    uint ratio = 1e36 / (1e18 - s);
    while (ratio > 1e18) {
      uint q = ratio > 1.045e18 ? 1.045e18 : ratio;
      spot = spot * 1e18 / q;
      _holdIndex(spot);
      uint mark = d.future.futureContracts(d.subId).markPrice * q / 1e18;
      vm.warp(block.timestamp + 1 days);
      vm.prank(VAULT);
      d.future.setMark(d.subId, uint64(block.timestamp), mark);
      if (settleAcc != 0) d.engine.settleAccount(settleAcc);
      ratio = ratio * 1e18 / q;
    }
  }

  /// @dev Full 4.5% marks while one fits above the target, then the one mark that lands 5 bps above maintenance.
  function _walkToMaintenance(uint acc, uint perUnit, uint mmUsd) internal {
    uint fullMark = 1e18 - uint(1e36) / 1.045e18;
    while (true) {
      int excess = d.engine.getMargin(acc, false) - int(mmUsd * 5 / 10_000);
      if (uint(excess) <= perUnit * fullMark / 1e18) return _devalueBy(uint(excess) * 1e18 / perUnit, acc);
      _devalueBy(fullMark, acc);
    }
  }

  /// @dev The same walk for a side margined in cNGN alone: its collateral falls with the naira too, and a loss is paid
  ///      from it, so a move of a costs factor x (notional x premium + cNGN held) of margin. Sized on the account as it
  ///      stands each step, which over-reads the sensitivity a little, so it closes on the target from above.
  function _walkCngnToMaintenance(uint acc, uint oneSideUsd, uint premium, uint factor, uint mmUsd) internal {
    uint fullMark = 1e18 - uint(1e36) / 1.045e18;
    for (uint i; i < 40; ++i) {
      int excess = d.engine.getMargin(acc, false) - int(mmUsd * 5 / 10_000);
      if (excess <= int(mmUsd / 1_000)) return;
      uint perUnit = (oneSideUsd * premium / 1e18 + uint(_cngnBalance(acc)) * spot / 1e18) * factor / 1e18;
      uint a = uint(excess) * 1e18 / perUnit;
      _devalueBy(a < fullMark ? a : fullMark, acc);
    }
    revert("walk to maintenance did not converge");
  }

  /// @dev Margin for the short: `imUsd` + $1 in USDC (factor 0), or in cNGN alone at `factor`, worth imUsd / factor + 0.1%.
  function _fundShort(uint acc, uint imUsd, uint factor) internal {
    if (factor == 0) return _depositUsdc(address(0xca401), acc, imUsd / 1e12 + 1e6);
    vm.prank(VAULT);
    d.engine.setBaseAssetMarginFactor(d.marketId, factor, 1e18);
    _depositCngn(address(0xca401), acc, imUsd * 1e18 / factor * 1e18 / spot * 1_001 / 1_000 / 1e12);
  }

  /**
   * One whole side at the launch cap (15 contracts short, opened at IM) is walked to 5 bps above maintenance,
   * then the naira loses `s` more of its value with nobody liquidating, and the account goes through the real auction
   * against the perp stack's real SecurityModule, funded so its balance never caps the payout. Measured twice from the
   * same state: (a) the ceiling, the auction run to its last second; (b) the venue's keeper, bidding the first minute
   * the payout covers the deficit +2%. `factor` 0 margins the side in USDC; otherwise in cNGN alone, at that factor.
   */
  function _coverageStep(uint s, uint factor) internal returns (Coverage memory c) {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    {
      address sm = vm.parseJsonAddress(
        vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json")), ".securityModule"
      );
      deal(USDC, treasury, 1_000_000e6);
      vm.startPrank(treasury);
      IERC20Metadata(USDC).approve(sm, 1_000_000e6);
      SecurityModule(sm).donate(1_000_000e6);
      vm.stopPrank();
    }

    uint n = 15e18;
    (uint mmReq, uint imReq) = d.engine.futureMarginRequirements(d.marketId);
    c.oneSideUsd = n * d.future.contractSize() / 1e18;
    uint carolAcc = _account(address(0xca401));
    uint aliceAcc = _account(alice);
    _fundShort(carolAcc, c.oneSideUsd * imReq / 1e18, factor);
    _depositUsdc(alice, aliceAcc, 50_000e6);
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(carolAcc, aliceAcc, int(n), mark0);
    assertGe(d.engine.getMargin(carolAcc, true), 0, "opens within IM");

    // One settled mark of the naira losing a costs the short notional x premium x a: walk to 5 bps above maintenance.
    c.premium = mark0 * spot / 1e18;
    uint mmUsd = c.oneSideUsd * mmReq / 1e18;
    if (factor == 0) _walkToMaintenance(carolAcc, c.oneSideUsd * c.premium / 1e18, mmUsd);
    else _walkCngnToMaintenance(carolAcc, c.oneSideUsd, c.premium, factor, mmUsd);
    assertGe(d.engine.getMargin(carolAcc, false), 0, "sits above MM");
    assertLt(d.engine.getMargin(carolAcc, false), int(mmUsd / 100), "within 1% of MM");

    _devalueBy(s, carolAcc);
    (, c.equityAfter) = d.engine.getMarginAndMarkToMarket(carolAcc, false, 0);

    DutchAuction auction = DutchAuction(params.auction);
    uint daveAcc = _account(address(0xda5e));
    _depositUsdc(address(0xda5e), daveAcc, 100_000e6);
    uint branch = vm.snapshotState();

    // (a) the ceiling. A solvent auction is paid by its bidder, never the SecurityModule: nothing to measure.
    auction.startAuction(carolAcc, 0);
    c.insolvent = _isInsolvent(carolAcc);
    if (!c.insolvent) return c;
    vm.warp(block.timestamp + auction.getAuctionParams().insolventAuctionLength);
    vm.prank(address(0xda5e));
    (,, c.smPaidAtEnd) = auction.bid(carolAcc, daveAcc, 1e18, 0, 0);
    vm.revertToState(branch);

    // (b) the keeper
    auction.startAuction(carolAcc, 0);
    int wanted = -c.equityAfter * 102 / 100;
    uint started = block.timestamp;
    uint length = auction.getAuctionParams().insolventAuctionLength;
    while (-auction.getCurrentBidPrice(carolAcc) < wanted && block.timestamp - started < length) {
      vm.warp(block.timestamp + 59);
    }
    c.keeperBidAfterSec = block.timestamp - started;
    vm.prank(address(0xda5e));
    (,, c.smPaidKeeper) = auction.bid(carolAcc, daveAcc, 1e18, 0, 0);
  }

  /**
   * The SecurityModule sizing rule (check_perp_pager.sm_required_usd) against the fork, from a 10% move to 30% (15%, SM_MOVE, past the cliff):
   *   one-side notional x premium x ln(1 / (1 - s)) when that exceeds one-side notional x MM, else 0.
   * Below the cliff the side stays solvent and the module pays nothing; past it, the module pays the step's whole loss
   * (an insolvent auction ends at the account's maintenance margin), and the fit is never below the fork and within 5%
   * of it (measured: 2.2%). The rule this replaced, one side x s x (1 - IM), is logged beside it: 35% under at 25%.
   */
  function testSecurityModuleCoverageAgainstTheFork() public {
    uint16[9] memory steps = [uint16(1_000), 1_250, 1_400, 1_500, 1_600, 1_750, 2_000, 2_500, 3_000];
    // ln(1 / (1 - s)), 18dp, for each step: Solidity has no log
    uint64[9] memory lns = [
      uint64(105360515657826352),
      133531392624522576,
      150822889734583680,
      162518929497774944,
      174353387144777728,
      192371892647456096,
      223143551314209760,
      287682072451780832,
      356674943938732416
    ];
    (uint mmReq, uint imReq) = d.engine.futureMarginRequirements(d.marketId);
    for (uint i; i < steps.length; ++i) {
      uint s = uint(steps[i]) * 1e14;
      uint snapshot = vm.snapshotState();
      Coverage memory c = _coverageStep(s, 0);
      vm.revertToState(snapshot);
      uint loss = c.oneSideUsd * c.premium / 1e18 * lns[i] / 1e18;
      uint fit = loss > c.oneSideUsd * mmReq / 1e18 ? loss : 0;
      console2.log("step bps:", steps[i]);
      console2.log("  equity after ($, 18dp, signed):", c.equityAfter);
      console2.log("  SM paid, auction to its end ($, 18dp):", c.smPaidAtEnd);
      console2.log("  SM paid, keeper's bid ($, 18dp):", c.smPaidKeeper);
      console2.log("  fit ($, 18dp):", fit);
      console2.log(
        "  replaced rule, one side x s x (1 - IM) ($, 18dp):", c.oneSideUsd * s / 1e18 * (1e18 - imReq) / 1e18
      );
      if (fit == 0) {
        assertFalse(c.insolvent, "under the cliff the side stays solvent");
        assertEq(c.smPaidAtEnd, 0, "and the SecurityModule pays nothing");
      } else {
        assertTrue(c.insolvent, "past the cliff the side is insolvent");
        assertGe(fit, c.smPaidAtEnd, "the fit never understates the fork");
        assertLe(fit, c.smPaidAtEnd * 105 / 100, "and is within 5% of it");
      }
    }
  }

  /**
   * The same side margined in cNGN alone (long naira twice: on the position and on its collateral), at margin factor
   * 0.5 (the launch value) and 0.8 (propose_margin_engine_batch MARGIN_FACTOR_MAX), through the same moves. At maintenance
   * its real equity is the requirement / factor, more than a USDC side's, so it breaks later and costs the SecurityModule
   * less than the USDC side the sizing covers, at every move: that is what lets the factor rise without resizing.
   * At 0.8 it survives SM_MOVE (15%), by $91 on $15,000.
   */
  function testCngnMarginedSideAgainstTheFit() public {
    uint16[5] memory steps = [uint16(1_000), 1_250, 1_500, 2_000, 2_500];
    uint64[5] memory lns =
      [uint64(105360515657826352), 133531392624522576, 162518929497774944, 223143551314209760, 287682072451780832];
    uint64[2] memory factors = [uint64(0.5e18), 0.8e18];
    (uint mmReq,) = d.engine.futureMarginRequirements(d.marketId);
    for (uint f; f < factors.length; ++f) {
      for (uint i; i < steps.length; ++i) {
        uint snapshot = vm.snapshotState();
        Coverage memory c = _coverageStep(uint(steps[i]) * 1e14, factors[f]);
        vm.revertToState(snapshot);
        uint loss = c.oneSideUsd * c.premium / 1e18 * lns[i] / 1e18;
        console2.log("factor (18dp):", factors[f]);
        console2.log("  step bps:", steps[i]);
        console2.log("  equity after ($, 18dp, signed):", c.equityAfter);
        console2.log("  insolvent?", c.insolvent);
        console2.log("  SM paid, auction to its end ($, 18dp):", c.smPaidAtEnd);
        console2.log("  SM paid, keeper's bid ($, 18dp):", c.smPaidKeeper);
        uint fit = loss > c.oneSideUsd * mmReq / 1e18 ? loss : 0;
        console2.log("  USDC-side fit ($, 18dp):", fit);
        assertLe(c.smPaidAtEnd, fit, "a cNGN-margined side never costs the SecurityModule more than the USDC side");
        if (fit == 0) assertFalse(c.insolvent, "and is solvent wherever the USDC side is");
        if (steps[i] == 1_500) assertFalse(c.insolvent, "it survives the 15% move the SecurityModule is sized for");
      }
    }
  }

  ////////////////////////////
  //  the pool, run negative  //
  ////////////////////////////

  /// @dev An unseeded pool pays alice, long two contracts, in cash before her two shorts pay in: about -$330.
  function _drainPoolWithTwoLosers() internal returns (uint aliceAcc, uint bobAcc, uint carolAcc) {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    aliceAcc = _account(alice);
    bobAcc = _account(bob);
    carolAcc = _account(address(0xca401));
    _depositUsdc(alice, aliceAcc, 4_000e6);
    _depositUsdc(bob, bobAcc, 300e6); // thin: below maintenance after the rally
    _depositUsdc(address(0xca401), carolAcc, 2_000e6); // well margined: never liquidated
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 1e18, mark0);
    _trade(carolAcc, aliceAcc, 1e18, mark0);
    for (uint i; i < 4; ++i) {
      _rallyStep(450);
    }
    d.engine.settleAccount(aliceAcc);
    assertLt(subAccounts.getBalance(d.poolAccount, _cash(), 0), -300e18, "the pool owes the cash");
  }

  /// @dev The liquidation fee to the SecurityModule's account (under the old SRM) passes through the pool; a negative
  ///      pool must not block it. Before the fix this reverted SRM_PortfolioBelowMargin on the pool's margin check.
  function testASolventLiquidationStartsWhileThePoolIsNegative() public {
    (, uint bobAcc,) = _drainPoolWithTwoLosers();
    assertLt(d.engine.getMargin(bobAcc, false), 0, "bob below maintenance");
    assertGt(_mtm(bobAcc), 0, "but solvent");
    DutchAuction auction = DutchAuction(params.auction);
    uint smAcc = auction.smAccount();
    int smBefore = subAccounts.getBalance(smAcc, _cash(), 0);
    auction.startAuction(bobAcc, 0);
    assertGt(subAccounts.getBalance(smAcc, _cash(), 0), smBefore, "the fee reached the SecurityModule");
    assertLt(subAccounts.getBalance(d.poolAccount, _cash(), 0), 0, "with the pool still negative (carol owes)");
  }

  /// @dev The same with borrowing off: the risk check refuses cash out of an account with negative cash
  ///      (SRM_NoNegativeCash), which a negative pool always is. Only the pool's exemption from the risk check lets the
  ///      fee through; the never-liquidatable view alone does not.
  function testASolventLiquidationStartsWhileThePoolIsNegativeWithBorrowingOff() public {
    (, uint bobAcc,) = _drainPoolWithTwoLosers();
    vm.prank(VAULT);
    d.engine.setBorrowingEnabled(false);
    DutchAuction auction = DutchAuction(params.auction);
    uint smAcc = auction.smAccount();
    int smBefore = subAccounts.getBalance(smAcc, _cash(), 0);
    auction.startAuction(bobAcc, 0);
    assertGt(subAccounts.getBalance(smAcc, _cash(), 0), smBefore, "the fee reached the SecurityModule");
  }

  /// @dev The SecurityModule's account sits under the old SRM, and the fee a solvent auction pays it is a transfer into
  ///      that account, through the old SRM's adjustment hook. Pausing the old SRM stops every engine auction that
  ///      charges a fee: the runbook's guardian pause targets the engine after the cutover, never the old SRM.
  function testPausingTheOldSrmStopsEngineLiquidations() public {
    (, uint bobAcc,) = _drainPoolWithTwoLosers();
    StandardManager srm = StandardManager(params.srm);
    DutchAuction auction = DutchAuction(params.auction);
    vm.prank(srm.guardian());
    srm.setAdjustmentsPaused(true);
    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    auction.startAuction(bobAcc, 0);

    vm.prank(srm.guardian());
    srm.setAdjustmentsPaused(false);
    int smBefore = subAccounts.getBalance(auction.smAccount(), _cash(), 0);
    auction.startAuction(bobAcc, 0);
    assertGt(subAccounts.getBalance(auction.smAccount(), _cash(), 0), smBefore, "unpaused, the same auction starts");
  }

  /// @dev And the SecurityModule's payout for an insolvent auction is a transfer out of that account: with the old SRM
  ///      paused, no bid on an insolvent engine account can be paid.
  function testPausingTheOldSrmStopsInsolvencyPayouts() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    _depositCngn(treasury, d.poolAccount, 2_000_000e6);
    uint aliceAcc = _account(alice);
    uint carolAcc = _account(address(0xca401));
    _depositUsdc(alice, aliceAcc, 2_000e6);
    _depositUsdc(address(0xca401), carolAcc, 260e6);
    _trade(carolAcc, aliceAcc, 1e18, d.future.futureContracts(d.subId).markPrice);
    for (uint i; i < 9; ++i) {
      _rallyStep(450);
    }
    DutchAuction auction = DutchAuction(params.auction);
    auction.startAuction(carolAcc, 0);
    assertTrue(_isInsolvent(carolAcc), "insolvent auction");
    address eve = address(0xe7e);
    uint eveAcc = _account(eve);
    _depositUsdc(eve, eveAcc, 5_000e6);

    StandardManager srm = StandardManager(params.srm);
    vm.prank(srm.guardian());
    srm.setAdjustmentsPaused(true);
    vm.prank(eve);
    vm.expectRevert(IBaseManager.BM_AdjustmentsPaused.selector);
    auction.bid(carolAcc, eveAcc, 1e18, 0, 0);

    vm.prank(srm.guardian());
    srm.setAdjustmentsPaused(false);
    vm.prank(eve);
    (,, uint cashToBidder) = auction.bid(carolAcc, eveAcc, 1e18, 0, 0);
    assertGt(cashToBidder, 0, "unpaused, the SecurityModule pays the same bid");
  }

  /// @dev Before the fix an auction started on the pool, and the SecurityModule paid bidders to take its debt.
  function testThePoolCannotBeAuctioned() public {
    _drainPoolWithTwoLosers();
    assertEq(d.engine.getMargin(d.poolAccount, false), 0, "never below maintenance");
    vm.expectRevert(IDutchAuction.DA_AccountIsAboveMaintenanceMargin.selector);
    DutchAuction(params.auction).startAuction(d.poolAccount, 0);
  }

  function testTheTreasuryCanTopUpANegativePool() public {
    _drainPoolWithTwoLosers();
    int before = subAccounts.getBalance(d.poolAccount, _cash(), 0);
    _depositUsdc(treasury, d.poolAccount, 100e6);
    assertEq(subAccounts.getBalance(d.poolAccount, _cash(), 0), before + 100e18);
  }

  function _isInsolvent(uint acc) internal view returns (bool) {
    (bool ok, bytes memory data) = params.auction.staticcall(abi.encodeWithSignature("auctions(uint256)", acc));
    require(ok, "auctions() read failed");
    (,, bool insolvent,,,,) = abi.decode(data, (uint, uint, bool, bool, uint, uint, uint));
    return insolvent;
  }

  ///////////////////
  // stale fixing  //
  ///////////////////

  /// @dev The index goes stale 20 minutes into the fixing hour: the fixing cannot be made, and after 24 hours the
  ///      vault may settle by hand, but only within 2% of the samples it did record.
  function testStaleIndexDuringTheFixingThenTheBoundedFallback() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    _depositCngn(treasury, d.poolAccount, 1_000_000e6);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _trade(bobAcc, aliceAcc, 1e18, d.future.futureContracts(d.subId).markPrice);

    uint64 expiry = params.expiry;
    for (uint t = expiry - 1 hours; t <= expiry - 40 minutes; t += 10 minutes) {
      vm.warp(t);
      d.future.recordFixingSample(d.subId);
    }

    // the feed goes stale: getSpot reverts, as LyraSpotFeed does past its heartbeat
    vm.clearMockedCalls();
    vm.mockCallRevert(params.indexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), "stale");
    vm.warp(expiry - 30 minutes);
    vm.expectRevert();
    d.future.recordFixingSample(d.subId);

    vm.warp(expiry);
    vm.expectRevert(IFutureAsset.FA_FixingIncomplete.selector);
    d.future.fixSettlementFromIndex(d.subId);

    vm.prank(VAULT);
    vm.expectRevert(IFutureAsset.FA_NotExpired.selector);
    d.future.setSettlementPrice(d.subId, index);

    vm.warp(uint(expiry) + 24 hours);
    uint ref = d.future.fallbackReference(d.subId);
    assertEq(ref, index, "three samples, all at the live index");

    vm.prank(VAULT);
    vm.expectRevert(IFutureAsset.FA_FallbackOutsideBand.selector);
    d.future.setSettlementPrice(d.subId, ref * 1021 / 1000);

    vm.prank(VAULT);
    d.future.setSettlementPrice(d.subId, ref * 1015 / 1000);
    assertTrue(d.future.futureContracts(d.subId).settled);

    // close-out reads no feed: any USDC part of the last leg converts at the settlement price (getSpot still reverts)
    d.engine.closeOutExpired(bobAcc, d.subId);
    d.engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(d.future.totalPosition(d.engine), 0);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  function _executeVaultBatch() internal {
    _execute(script.vaultActionsJson(d, params), script.vaultActionCount(d));
  }

  function _executeEnableBatch() internal {
    _execute(script.enableActionsJson(d, params), script.enableActionCount());
  }

  function _execute(string memory json, uint count) internal {
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      bytes32 digest = vm.parseJsonBytes32(json, string.concat(key, ".digest"));
      assertEq(digest, keccak256(abi.encodePacked(to, keccak256(data))), "digest must match its own action");
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, string.concat("vault action ", vm.toString(i), " failed"));
    }
  }

  /// @dev The live feed reverts once stale; hold it at `price` so marks, valuation and the fixing can run.
  function _holdIndex(uint price) internal {
    vm.mockCall(params.indexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(price, 1e18));
  }

  /// @dev The perp reads its mark and impact feeds on every trade; hold them at `price` with the index, as _holdIndex does.
  function _holdPerpFeeds(uint price) internal {
    _holdIndex(price);
    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json"));
    string[3] memory feeds = [".markFeed", ".impactAskFeed", ".impactBidFeed"];
    for (uint i; i < 3; ++i) {
      vm.mockCall(
        vm.parseJsonAddress(stack, feeds[i]),
        abi.encodeWithSelector(ISpotDiffFeed.getResult.selector),
        abi.encode(price, 1e18)
      );
    }
  }

  function _accountUnder(address user, IManager manager) internal returns (uint) {
    return subAccounts.createAccountWithApproval(user, address(this), manager);
  }

  function _tradePerp(uint seller, uint buyer, int amount) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: PerpAsset(params.perp), subId: 0, amount: amount, assetData: bytes32(0)
      }),
      ""
    );
  }

  function _cash() internal view returns (CashAsset) {
    return CashAsset(params.cash);
  }

  function _account(address user) internal returns (uint) {
    return subAccounts.createAccountWithApproval(user, address(this), IManager(address(d.engine)));
  }

  function _fundedAccounts() internal returns (uint aliceAcc, uint bobAcc) {
    aliceAcc = _account(alice);
    bobAcc = _account(bob);
    _depositUsdc(alice, aliceAcc, 1_000e6);
    _depositUsdc(bob, bobAcc, 1_000e6);
    _depositCngn(alice, aliceAcc, 500_000e6);
    _depositCngn(bob, bobAcc, 500_000e6);
  }

  function _depositUsdc(address user, uint acc, uint amount) internal {
    deal(USDC, user, amount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(params.cash, amount);
    CashAsset(params.cash).deposit(acc, amount);
    vm.stopPrank();
  }

  function _depositCngn(address user, uint acc, uint amount) internal {
    deal(CNGN, user, amount);
    vm.startPrank(user);
    IERC20Metadata(CNGN).approve(params.cngnEscrow, amount);
    WrappedERC20Asset(params.cngnEscrow).deposit(acc, amount);
    vm.stopPrank();
  }

  function _trade(uint seller, uint buyer, int amount, uint price) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: d.future, subId: d.subId, amount: amount, assetData: bytes32(price)
      }),
      ""
    );
  }

  function _cngnBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, WrappedERC20Asset(params.cngnEscrow), 0);
  }
}
