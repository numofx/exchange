// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployEurcFutureV2} from "../../scripts/deploy-eurc-future-v2.s.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {FutureAsset} from "../../src/assets/FutureAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../../src/interfaces/IVolFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {BaseLyraFeed} from "../../src/feeds/BaseLyraFeed.sol";

/// @dev contracts/execution's Matching and TradeModule, as deployed: declared here, as in MarginEngineTradeModuleFork.
struct EAction {
  uint subaccountId;
  uint nonce;
  address module;
  bytes data;
  uint expiry;
  address owner;
  address signer;
}

struct ETradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct EFillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct EOrderData {
  uint takerAccount;
  uint takerFee;
  EFillDetails[] fillDetails;
  bytes managerData;
}

interface IEMatching {
  function verifyAndMatch(EAction[] memory actions, bytes[] memory signatures, bytes memory actionData) external;
  function depositSubAccount(uint accountId) external;
  function setTradeExecutor(address tradeExecutor, bool canExecute) external;
  function domainSeparator() external view returns (bytes32);
  function getActionHash(EAction memory action) external pure returns (bytes32);
}

interface IETradeModule {
  function matching() external view returns (address);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

interface IEOwnable {
  function owner() external view returns (address);
}

/**
 * Runs deploy-eurc-future-v2.s.sol's own `deploy` on a Base fork at head, against the live MarginEngine v2 (set up,
 * closed), executes its setup and enable batches as the vault, and proves that:
 *   - the deployed engine takes the future on market 2 through owner-only setters alone: no engine change, no new pool;
 *   - EURC-<expiry> is in American terms end to end: the initial mark sits at the index's forward premium, a long gains
 *     as EURC/USD rises (by pulled mark and by fill price), VM moves as USDC cash through the one pool, and the fixing
 *     settles at the index;
 *   - it fills through the live Matching and TradeModule;
 *   - cNGN-30NOV26 (enabled from its own artifact) and the spot markets are untouched, and the two series close out
 *     independently because their expiries differ; at one expiry they would not (the script refuses it).
 *
 * The two indexes are held with mockCall from the first warp on (Chainlink EURC/USD goes stale past 3h, the cNGN index
 * past its heartbeat); nothing else is mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract EurcFutureV2Fork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint64 constant CNGN_EXPIRY = 1796047200;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address executor = address(0xE1EC);

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint forwardPk = uint(keccak256("numo.eurc-future-v2-fork.forward-signer"));
  uint makerPk = uint(keccak256("numo.eurc-future-v2-fork.maker"));
  uint takerPk = uint(keccak256("numo.eurc-future-v2-fork.taker"));

  DeployEurcFutureV2 script;
  DeployEurcFutureV2.Params params;
  DeployEurcFutureV2.Deployment d;
  SubAccounts subAccounts;
  MarginEngine engine;
  FutureAsset cngnFuture;
  address cngnIndex;

  uint eurIndex; // USDC per EURC, live
  uint cngnSpot; // USDC per cNGN, live
  uint nonce;
  IEMatching matching;

  // The block before EURC-30NOV26's deploy (2026-10-30, 53273869): its setup has since landed, and the deploy refuses an
  // engine whose EUR market already lists a future, so the suite rehearses from just before it.
  uint constant FORK_BLOCK = 53_273_868;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    script = new DeployEurcFutureV2();
    params = script.loadChainParams();
    params.forwardSigner = vm.addr(forwardPk);
    params.initialMark = script.fairForward(params);
    script.checkParams(params);

    subAccounts = SubAccounts(params.subAccounts);
    engine = MarginEngine(params.engine);
    string memory v2 = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/MARGIN_ENGINE_V2.json"));
    cngnFuture = FutureAsset(vm.parseJsonAddress(v2, ".future"));
    cngnIndex = params.cngnIndexFeed;
    (eurIndex,) = ISpotFeed(params.indexFeed).getSpot();
    (cngnSpot,) = ISpotFeed(cngnIndex).getSpot();

    d = script.deploy(params);
  }

  ///////////////////
  //  the script   //
  ///////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(d, params);
  }

  /// @dev The engine the vault set up on 2026-10-27, as the deploy finds it: two markets, a future only on NGN, the EUR
  ///      market's base the EURC escrow, one pool.
  function testTheLiveEngineIsWhatTheScriptExpects() public view {
    assertEq(engine.owner(), VAULT);
    assertEq(engine.lastMarketId(), 2);
    assertEq(address(engine.assetMap(1, IMarginEngine.AssetType.Future)), address(cngnFuture));
    assertEq(address(engine.assetMap(2, IMarginEngine.AssetType.Future)), address(0), "EUR lists no future yet");
    assertEq(engine.accId(), 37, "the pool");
    assertEq(params.poolAccount, 37);
  }

  /// @dev Same expiry as cNGN-30NOV26 is the same subId: refused.
  function testAnExpiryCngnListsIsRefused() public {
    DeployEurcFutureV2.Params memory p = params;
    p.expiry = CNGN_EXPIRY;
    p.lastTradeTime = CNGN_EXPIRY - 1 hours;
    p.initialMark = script.fairForward(p);
    vm.expectRevert(bytes("EXPIRY is a series another market lists: closeOutExpired would couple them"));
    script.checkParams(p);
  }

  function testTheDefaultSeriesIs30Nov1600() public view {
    assertEq(d.subId, 1796054400, "2026-11-30 16:00 UTC");
    assertEq(d.future.contractSize(), 1_000e18, "1,000 EURC");
    assertEq(params.imReq, 0.06e18);
    assertEq(params.mmReq, 0.04e18);
    assertEq(params.futureOICap, 18e18);
  }

  /// @dev USD rates over EUR rates: carry negative, EUR at a forward premium, initial mark over the index.
  function testTheForwardSitsAtAPremiumToTheIndex() public {
    assertGt(params.initialMark, eurIndex, "EUR dearer forward");
    uint tau = uint(params.expiry) - block.timestamp;
    uint expected = eurIndex * 1e18 / (1e18 - 0.015e18 * tau / 365 days);
    assertEq(params.initialMark, expected);
    // a mark under the index, inside the 3% band but on the wrong side of the forward, is refused
    DeployEurcFutureV2.Params memory p = params;
    p.initialMark = eurIndex * 99 / 100;
    vm.expectRevert(bytes("INITIAL_MARK is outside the band around index / (1 + carry * tau)"));
    script.checkParams(p);
  }

  function testAUsedOrWrongDeployerIsRefused() public {
    address used = makeAddr("used deployer");
    script.checkDeployer(params, used, 1, address(0));
    vm.expectRevert(
      bytes("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)")
    );
    script.checkDeployer(params, used, 5, address(0));
    script.checkDeployer(params, used, 5, used);
    vm.expectRevert(bytes("deployer is the vault"));
    script.checkDeployer(params, VAULT, 5, VAULT);
    vm.expectRevert(bytes("deployer signs the forward"));
    script.checkDeployer(params, params.forwardSigner, 0, address(0));
    vm.expectRevert(bytes("run with --account <keystore> (or --private-key): no sender given"));
    script.checkDeployer(params, 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, 0, address(0));
  }

  ///////////////////
  //   batches     //
  ///////////////////

  function testSetupAttachesTheFutureToMarketTwoAndOpensNothing() public {
    _setup();
    assertEq(IEOwnable(address(d.future)).owner(), VAULT);
    assertEq(IEOwnable(address(d.forwardFeed)).owner(), VAULT);
    assertEq(address(engine.assetMap(2, IMarginEngine.AssetType.Future)), address(d.future));
    IMarginEngine.AssetDetail memory detail = engine.assetDetails(d.future);
    assertTrue(detail.isWhitelisted);
    assertEq(detail.marketId, 2);
    (uint mm, uint im) = engine.futureMarginRequirements(2);
    assertEq(mm, 0.04e18);
    assertEq(im, 0.06e18);
    assertEq(d.future.totalPositionCap(engine), 0, "still closed");
    assertFalse(IETradeModule(params.tradeModule).isDatedFutureAsset(address(d.future)), "not on the TradeModule");

    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    vm.expectRevert();
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
  }

  function testDeploysClosedUntilSetupThenEnable() public {
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    // the future's own cap (0, set at deploy) refuses it before the engine is asked
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    _setup();
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    _enable();
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);
    assertEq(d.future.totalPosition(engine), 2e18, "both sides count against the cap");
  }

  /// @dev IM 6% of |position| x 1,000 EURC x mark: 100 USDC opens one contract (~$67 IM), not two (~$134).
  function testInitialMarginIsSixPercentOfNotional() public {
    _setup();
    _enable();
    _holdIndexes();
    uint small = _account(alice);
    uint big = _account(bob);
    _depositUsdc(alice, small, 100e6);
    _depositUsdc(bob, big, 10_000e6);
    vm.expectRevert(IMarginEngine.SRM_PortfolioBelowMargin.selector);
    _trade(big, small, 2e18, params.initialMark);
    _trade(big, small, 1e18, params.initialMark);
    int im = engine.getMargin(small, true);
    int expected = 100e18 - int(1_000 * params.initialMark * 6 / 100);
    assertApproxEqAbs(im, expected, 1e14, "100 USDC less 6% of one contract's notional");
  }

  function testTheCapIsEnforced() public {
    _setup();
    _enable();
    _holdIndexes();
    uint aliceAcc = _account(alice);
    uint bobAcc = _account(bob);
    _depositUsdc(alice, aliceAcc, 10_000e6);
    _depositUsdc(bob, bobAcc, 10_000e6);
    _trade(bobAcc, aliceAcc, 9e18, params.initialMark); // 18 over both sides: the cap
    vm.expectRevert();
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
  }

  ///////////////////
  //   lifecycle   //
  ///////////////////

  /// @dev EUR strengthens 1% at the index; the forward follows (index + the published premium) and the pulled mark with
  ///      it: the long gains (mark1 - mark0) x 1,000 EURC a contract, paid in USDC through the pool.
  function testALongGainsWhenEurcRisesAndIsPaidInUsdc() public {
    _setup();
    _enable();
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = params.initialMark;
    _trade(bobAcc, aliceAcc, 2e18, mark0); // alice long 2,000 EURC forward

    vm.warp(block.timestamp + 1 hours);
    uint index1 = eurIndex * 101 / 100;
    _holdEurIndex(index1);
    int96 premium = int96(int(mark0) - int(eurIndex)); // the premium at deploy, carried
    _publishForward(premium);
    vm.prank(address(0xbeef)); // anyone
    d.future.pullMark(d.subId);

    uint mark1 = d.future.futureContracts(d.subId).markPrice;
    assertEq(mark1, uint(int(index1) + premium), "index + diff, as is");
    assertGt(mark1, mark0, "EUR up, mark up");
    int expectedVM = int(2 * 1_000 * (mark1 - mark0));
    assertEq(d.future.getPendingVM(aliceAcc, d.subId), expectedVM, "the long gains");
    assertEq(d.future.getPendingVM(bobAcc, d.subId), -expectedVM, "the short pays");

    int poolBefore = _cash(engine.accId());
    int aliceBefore = _settledCash(aliceAcc);
    int bobBefore = _settledCash(bobAcc);
    engine.settleAccount(bobAcc);
    assertEq(_cash(engine.accId()) - poolBefore, expectedVM, "the loser pays the pool first");
    engine.settleAccount(aliceAcc);
    assertEq(_cash(aliceAcc) - aliceBefore, expectedVM, "alice paid in USDC");
    assertEq(_cash(bobAcc) - bobBefore, -expectedVM, "bob paid in USDC");
    assertEq(_cash(engine.accId()), poolBefore, "the pool nets to zero");
  }

  /// @dev And the other way: EUR weakens 2%, the long pays.
  function testALongPaysWhenEurcFalls() public {
    _setup();
    _enable();
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = params.initialMark;
    _trade(bobAcc, aliceAcc, 1e18, mark0);
    vm.warp(block.timestamp + 1 hours);
    _holdEurIndex(eurIndex * 98 / 100);
    _publishForward(int96(int(mark0) - int(eurIndex)));
    d.future.pullMark(d.subId);
    assertLt(d.future.getPendingVM(aliceAcc, d.subId), 0, "EUR down: the long pays");
    assertGt(d.future.getPendingVM(bobAcc, d.subId), 0, "and the short gains");
  }

  /// @dev Signed orders through the live Matching and TradeModule: no quote leg, the fill price carried to the future.
  ///      Bought 0.5% over the mark, the long pays that difference as VM within the fill.
  function testItFillsThroughTheLiveTradeModule() public {
    _setup();
    _enable();
    _holdIndexes();
    matching = IEMatching(IETradeModule(params.tradeModule).matching());
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);
    uint takerAcc = _matchingAccount(vm.addr(takerPk), 1_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 1_000e6);

    int takerCash = _cash(takerAcc);
    int makerCash = _cash(makerAcc);
    int price = int(params.initialMark * 1005 / 1000);
    _fill(takerAcc, makerAcc, 1e18, price);

    assertEq(subAccounts.getBalance(takerAcc, d.future, d.subId), 1e18, "taker long one contract");
    assertEq(subAccounts.getBalance(makerAcc, d.future, d.subId), -1e18, "maker short one contract");
    int paid = takerCash - _cash(takerAcc);
    assertApproxEqAbs(paid, int(1_000 * (uint(price) - params.initialMark)), 1e12, "the long paid fill - mark");
    assertApproxEqAbs(_cash(makerAcc) - makerCash, paid, 1e12, "the short received it");
  }

  /// @dev A fill outside the 3% band is refused by the future.
  function testAFillOutsideTheIndexBandIsRefused() public {
    _setup();
    _enable();
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    vm.expectRevert(IFutureAsset.FA_FillOutsideIndexBand.selector);
    _trade(bobAcc, aliceAcc, 1e18, eurIndex * 104 / 100);
  }

  /// @dev The last pulled mark before last trade, then the fixing at the index: the final VM is (index - last mark) x
  ///      size, the position closes out, and real USDC comes out.
  function testExpirySettlesAtTheIndexFixingInUsdc() public {
    _setup();
    _enable();
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _trade(bobAcc, aliceAcc, 2e18, params.initialMark);

    // the last mark: 90 minutes before expiry, the forward's premium nearly gone
    uint64 expiry = params.expiry;
    vm.warp(expiry - 90 minutes);
    _holdIndexes();
    _publishForward(int96(int(eurIndex / 10_000)));
    d.future.pullMark(d.subId);
    uint lastMark = d.future.futureContracts(d.subId).markPrice;
    assertEq(lastMark, eurIndex + eurIndex / 10_000);
    engine.settleAccount(bobAcc);
    engine.settleAccount(aliceAcc);
    vm.warp(expiry - 30 minutes);
    vm.expectRevert(IFutureAsset.FA_MarkingClosed.selector);
    d.future.pullMark(d.subId);

    // the fixing: sampled every 10 minutes over the last hour, flat at the index
    uint index = eurIndex * 1005 / 1000;
    _holdEurIndex(index);
    for (uint t = expiry - 1 hours; t <= expiry; t += 10 minutes) {
      vm.warp(t);
      d.future.recordFixingSample(d.subId);
    }
    vm.prank(address(0xf1));
    d.future.fixSettlementFromIndex(d.subId);
    assertEq(d.future.futureContracts(d.subId).markPrice, index, "settles at the index, as is");

    int finalVM = int(2 * 1_000) * (int(index) - int(lastMark));
    assertGt(finalVM, 0);
    int aliceBefore = _settledCash(aliceAcc);
    engine.closeOutExpired(bobAcc, d.subId);
    engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 0);
    assertEq(subAccounts.getBalance(bobAcc, d.future, d.subId), 0);
    assertEq(d.future.totalPosition(engine), 0, "no open interest left");
    assertEq(_cash(aliceAcc) - aliceBefore, finalVM, "the last VM, at the fixing");

    engine.settleInterest(aliceAcc);
    uint out = uint(_cash(aliceAcc)) / 1e12;
    vm.prank(alice);
    CashAsset(params.cash).withdraw(aliceAcc, out, alice);
    assertEq(IERC20Metadata(USDC).balanceOf(alice), out, "real USDC out");
  }

  ///////////////////
  // the neighbours//
  ///////////////////

  /// @dev EURC's batches change nothing cNGN-30NOV26 or either spot market reads.
  function testCngnSeriesAndSpotSettingsUnchanged() public {
    bytes32 before = _neighbourSettings();
    _setup();
    _enable();
    assertEq(_neighbourSettings(), before, "market 1, both escrows and the cNGN future as they were");
  }

  /// @dev Both futures open (cNGN from its own enable artifact), held in one account: each series marks, fixes and
  ///      closes out on its own. cNGN closes out at 14:00 while EURC still trades to 15:00.
  function testBothSeriesTradeAndCloseOutIndependently() public {
    _setup();
    _enable();
    _executeFile("MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS", 2);
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint cngnMark = cngnFuture.futureContracts(CNGN_EXPIRY).markPrice;
    _tradeOn(cngnFuture, CNGN_EXPIRY, bobAcc, aliceAcc, 1e18, cngnMark);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    assertEq(subAccounts.getBalance(aliceAcc, cngnFuture, CNGN_EXPIRY), 1e18);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);

    for (uint t = CNGN_EXPIRY - 1 hours; t <= CNGN_EXPIRY; t += 10 minutes) {
      vm.warp(t);
      cngnFuture.recordFixingSample(CNGN_EXPIRY);
    }
    cngnFuture.fixSettlementFromIndex(CNGN_EXPIRY);
    engine.closeOutExpired(aliceAcc, CNGN_EXPIRY);
    engine.closeOutExpired(bobAcc, CNGN_EXPIRY);
    assertEq(subAccounts.getBalance(aliceAcc, cngnFuture, CNGN_EXPIRY), 0, "cNGN closed out");
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18, "EURC still open");

    // EURC still trades after cNGN's expiry, until its own last trade
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 2e18);
  }

  /// @dev Why the script refuses cNGN's expiry: at one subId, cNGN's close-out reverts until EURC's series has fixed too.
  function testOneExpiryWouldCoupleTheCloseOuts() public {
    DeployEurcFutureV2.Params memory p = params;
    p.expiry = CNGN_EXPIRY;
    p.lastTradeTime = CNGN_EXPIRY - 1 hours;
    p.initialMark = script.fairForward(p);
    d = script.deploy(p); // the script's check skipped, as an operator could not
    params = p;
    _setup();
    _enable();
    _executeFile("MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS", 2);
    _holdIndexes();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _tradeOn(cngnFuture, CNGN_EXPIRY, bobAcc, aliceAcc, 1e18, cngnFuture.futureContracts(CNGN_EXPIRY).markPrice);

    for (uint t = CNGN_EXPIRY - 1 hours; t <= CNGN_EXPIRY; t += 10 minutes) {
      vm.warp(t);
      cngnFuture.recordFixingSample(CNGN_EXPIRY);
    }
    cngnFuture.fixSettlementFromIndex(CNGN_EXPIRY);
    vm.expectRevert(IMarginEngine.ME_NotSettled.selector);
    engine.closeOutExpired(aliceAcc, CNGN_EXPIRY);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  function _neighbourSettings() internal view returns (bytes32 h) {
    for (uint id = 1; id <= 2; ++id) {
      (uint f, uint s) = engine.baseMarginParams(id);
      (ISpotFeed spot, IForwardFeed fwd, IVolFeed vol) = engine.getMarketFeeds(id);
      address base = address(engine.assetMap(id, IMarginEngine.AssetType.Base));
      h = keccak256(
        abi.encode(
          h,
          f,
          s,
          address(spot),
          address(fwd),
          address(vol),
          base,
          WrappedERC20Asset(base).totalPositionCap(engine),
          WrappedERC20Asset(base).whitelistedManager(address(engine))
        )
      );
    }
    (uint mm, uint im) = engine.futureMarginRequirements(1);
    IFutureAsset.FutureContract memory c = cngnFuture.futureContracts(CNGN_EXPIRY);
    h = keccak256(
      abi.encode(
        h,
        address(engine.assetMap(1, IMarginEngine.AssetType.Future)),
        mm,
        im,
        cngnFuture.totalPositionCap(engine),
        c.markPrice,
        c.lastMarkTime,
        IETradeModule(params.tradeModule).isDatedFutureAsset(address(cngnFuture)),
        engine.accId(),
        engine.lastMarketId()
      )
    );
  }

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
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(forwardPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = params.forwardSigner;
    d.forwardFeed.acceptData(abi.encode(feedData));
  }

  function _setup() internal {
    _execute(script.vaultActionsJson(d, params), script.vaultActionCount());
  }

  function _enable() internal {
    _execute(script.enableActionsJson(d, params), script.enableActionCount());
  }

  function _executeFile(string memory name, uint count) internal {
    _execute(vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/", name, ".json")), count);
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

  function _holdIndexes() internal {
    _holdEurIndex(eurIndex);
    vm.mockCall(cngnIndex, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(cngnSpot, 1e18));
  }

  function _holdEurIndex(uint price) internal {
    vm.mockCall(params.indexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(price, 1e18));
  }

  function _account(address user) internal returns (uint) {
    return subAccounts.createAccountWithApproval(user, address(this), IManager(address(engine)));
  }

  function _fundedAccounts() internal returns (uint aliceAcc, uint bobAcc) {
    aliceAcc = _account(alice);
    bobAcc = _account(bob);
    _depositUsdc(alice, aliceAcc, 1_000e6);
    _depositUsdc(bob, bobAcc, 1_000e6);
  }

  function _depositUsdc(address user, uint acc, uint amount) internal {
    deal(USDC, user, amount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(params.cash, amount);
    CashAsset(params.cash).deposit(acc, amount);
    vm.stopPrank();
  }

  function _trade(uint seller, uint buyer, int amount, uint price) internal {
    _tradeOn(d.future, d.subId, seller, buyer, amount, price);
  }

  function _tradeOn(IAsset future, uint subId, uint seller, uint buyer, int amount, uint price) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: future, subId: subId, amount: amount, assetData: bytes32(price)
      }),
      ""
    );
  }

  function _settledCash(uint acc) internal returns (int) {
    engine.settleInterest(acc);
    return _cash(acc);
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, IAsset(params.cash), 0);
  }

  function _matchingAccount(address owner, uint usdcAmount) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(engine)));
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(params.cash, usdcAmount);
    CashAsset(params.cash).deposit(accountId, usdcAmount);
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  function _fill(uint takerAcc, uint makerAcc, uint amount, int price) internal {
    nonce++;
    EAction[] memory actions = new EAction[](2);
    bytes[] memory sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, takerPk, price, amount);
    (actions[1], sigs[1]) = _sign(makerAcc, false, makerPk, price, amount);
    EFillDetails[] memory fills = new EFillDetails[](1);
    fills[0] = EFillDetails({filledAccount: makerAcc, amountFilled: amount, price: price, fee: 0});
    bytes memory orderData =
      abi.encode(EOrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: ""}));
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _sign(uint accountId, bool isBid, uint pk, int price, uint amount)
    internal
    view
    returns (EAction memory action, bytes memory signature)
  {
    address owner = vm.addr(pk);
    action = EAction({
      subaccountId: accountId,
      nonce: nonce,
      module: params.tradeModule,
      data: abi.encode(
        ETradeData({
          asset: address(d.future),
          subId: d.subId,
          limitPrice: price,
          desiredAmount: int(amount),
          worstFee: 1e18,
          recipientId: accountId,
          isBid: isBid
        })
      ),
      expiry: block.timestamp + 1 days,
      owner: owner,
      signer: owner
    });
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(action)));
    signature = bytes.concat(r, s, bytes1(v));
  }
}
