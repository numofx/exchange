// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployEurcFutureV3} from "../../scripts/deploy-eurc-future-v3.s.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {FutureAsset} from "../../src/assets/FutureAsset.sol";
import {StreamsIndexAdapter, IStreamsVerifierProxy} from "../../src/feeds/StreamsIndexAdapter.sol";
import {EurcIndexFeed} from "../../src/feeds/EurcIndexFeed.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../../src/interfaces/IFutureAssetV3.sol";
import {IPositionTracking} from "../../src/interfaces/IPositionTracking.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";

/// @dev contracts/execution's Matching and TradeModule, as deployed (as in EurcFutureV2Fork).
struct V3Action {
  uint subaccountId;
  uint nonce;
  address module;
  bytes data;
  uint expiry;
  address owner;
  address signer;
}

struct V3TradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct V3FillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct V3OrderData {
  uint takerAccount;
  uint takerFee;
  V3FillDetails[] fillDetails;
  bytes managerData;
}

interface IV3Matching {
  function verifyAndMatch(V3Action[] memory actions, bytes[] memory signatures, bytes memory actionData) external;
  function depositSubAccount(uint accountId) external;
  function setTradeExecutor(address tradeExecutor, bool canExecute) external;
  function domainSeparator() external view returns (bytes32);
  function getActionHash(V3Action memory action) external pure returns (bytes32);
}

interface IV3TradeModule {
  function matching() external view returns (address);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

interface IV3Ownable {
  function owner() external view returns (address);
}

/**
 * Runs deploy-eurc-future-v3.s.sol's own `deploy` on a Base fork against the live MarginEngine v2, after the v2
 * EURC-30NOV26 was retired (cap 0, off the TradeModule, zero open interest) and before any v3 deploy; executes its
 * setup and enable batches as the vault; and proves (docs/eurc-usdc-futures-spec.md, A1.2, A5):
 *   - setup replaces the retired series in market 2's one future slot, and refuses while that series has open
 *     interest, a cap, a TradeModule registration or any pending VM;
 *   - it fills through the live Matching and TradeModule against reports a keeper posted, and refuses a fill with no
 *     fresh index; reports attached to an order revert on the fee account's manager (A2.2);
 *   - a fixing sampled from posted reports settles at their ratio, positions close out, and USDC comes out;
 *   - a broken fixing settles through a recovery window;
 *   - cNGN-30NOV26 is untouched.
 *
 * Mocked: the Data Streams verifier's `verify` (returns the report data, as it does for a validly signed report;
 * real verification was checked on Base by eth_call, A2.2) and, from the first warp, the two push feeds MarginEngine
 * reads for margin (market 2's Chainlink EURC/USD, the cNGN index), which go stale past their heartbeats.
 *
 * Requires BASE_RPC_URL.
 */
contract EurcFutureV3Fork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant VERIFIER = 0xDE1A28D87Afd0f546505B28AB50410A5c3a7387a;
  address constant LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
  bytes32 constant EURC_FEED = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 constant USDC_FEED = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;
  address constant RETIRED = 0x6Ff7084D6F1760a57b9475a41F54b12279cD7744;
  uint64 constant CNGN_EXPIRY = 1796047200;
  uint64 constant RETIRED_EXPIRY = 1796054400;

  /// @dev After the retirement (cap 0 in 57,622,309, off the TradeModule in 57,623,890, 2026-11-15 03:59 UTC), before any v3 deploy. The
  ///      world before the setup batch, pinned (CLAUDE.md: chain state moves under tests).
  uint constant FORK_BLOCK = 57_624_000;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address executor = address(0xE1EC);
  uint forwardPk = uint(keccak256("numo.eurc-future-v3-fork.forward-signer"));
  uint makerPk = uint(keccak256("numo.eurc-future-v3-fork.maker"));
  uint takerPk = uint(keccak256("numo.eurc-future-v3-fork.taker"));

  DeployEurcFutureV3 script;
  DeployEurcFutureV3.Params params;
  DeployEurcFutureV3.Deployment d;
  SubAccounts subAccounts;
  MarginEngine engine;
  address cngnFuture;
  uint refPrice; // market 2's push feed, USD per EURC
  uint cngnSpot;
  uint nonce;
  IV3Matching matching;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    script = new DeployEurcFutureV3();
    params = script.loadChainParams();
    params.forwardSigner = vm.addr(forwardPk);
    params.futureOICap = 18e18;
    params.initialMark = script.fairForward(params);
    script.checkParams(params);

    subAccounts = SubAccounts(params.subAccounts);
    engine = MarginEngine(params.engine);
    cngnFuture = address(engine.assetMap(1, IMarginEngine.AssetType.Future));
    (refPrice,) = ISpotFeed(params.referenceFeed).getSpot();
    (cngnSpot,) = ISpotFeed(params.cngnIndexFeed).getSpot();

    d = script.deploy(params);
  }

  ///////////////////
  //  the script   //
  ///////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(d, params);
  }

  function testTheDefaultSeriesIs30Nov1500() public view {
    assertEq(d.subId, 1796050800, "2026-11-30 15:00 UTC");
    assertEq(params.lastTradeTime, 1796050800 - 30 minutes);
    assertEq(d.future.feedTimelock(), 24 hours);
    assertEq(d.indexFeed.indexMaxAge(), 60);
  }

  /// @dev The world the setup batch replaces: market 2's slot held by the retired series, closed and empty.
  function testTheSlotHolderIsTheRetiredSeriesClosedAndEmpty() public view {
    assertEq(address(engine.assetMap(2, IMarginEngine.AssetType.Future)), RETIRED);
    assertEq(IPositionTracking(RETIRED).totalPosition(IManager(address(engine))), 0);
    assertEq(IPositionTracking(RETIRED).totalPositionCap(IManager(address(engine))), 0);
    assertFalse(IV3TradeModule(params.tradeModule).isDatedFutureAsset(RETIRED));
    script.checkSlotFree(params);
  }

  /// @dev Each way the retired series could still be in use refuses the deploy (and the proposer's re-read).
  function testTheSlotCheckRefusesAnythingStillInUse() public {
    IManager m = IManager(address(engine));
    vm.mockCall(RETIRED, abi.encodeCall(IPositionTracking.totalPosition, (m)), abi.encode(uint(1e15)));
    vm.expectRevert(bytes("retired series still has open interest"));
    script.checkSlotFree(params);
    vm.clearMockedCalls();

    vm.mockCall(RETIRED, abi.encodeCall(IPositionTracking.totalPositionCap, (m)), abi.encode(uint(18e18)));
    vm.expectRevert(bytes("retired series' cap is not 0"));
    script.checkSlotFree(params);
    vm.clearMockedCalls();

    vm.mockCall(params.tradeModule, abi.encodeCall(IV3TradeModule.isDatedFutureAsset, (RETIRED)), abi.encode(true));
    vm.expectRevert(bytes("retired series is still on the TradeModule"));
    script.checkSlotFree(params);
    vm.clearMockedCalls();

    vm.mockCall(RETIRED, abi.encodeCall(IFutureAsset.getPendingVM, (40, RETIRED_EXPIRY)), abi.encode(int(-1)));
    vm.expectRevert(bytes("an account has VM pending on it"));
    script.checkSlotFree(params);
    vm.clearMockedCalls();

    vm.mockCall(
      params.engine,
      abi.encodeWithSignature("assetMap(uint256,uint8)", 2, uint8(IMarginEngine.AssetType.Future)),
      abi.encode(address(0xdead))
    );
    vm.expectRevert(bytes("market 2's future is not the retired EURC-30NOV26: stop and investigate"));
    script.checkSlotFree(params);
  }

  /// @dev 14:00 is cNGN-30NOV26's, and 16:00 the retired series' while it holds the slot: both refused.
  function testExpiriesOtherSeriesHoldAreRefused() public {
    DeployEurcFutureV3.Params memory p = params;
    p.expiry = CNGN_EXPIRY;
    p.lastTradeTime = CNGN_EXPIRY - 30 minutes;
    p.initialMark = script.fairForward(p);
    vm.expectRevert(bytes("EXPIRY is a series another market lists: closeOutExpired would couple them"));
    script.checkParams(p);
    p.expiry = RETIRED_EXPIRY;
    p.lastTradeTime = RETIRED_EXPIRY - 30 minutes;
    p.initialMark = script.fairForward(p);
    vm.expectRevert(bytes("EXPIRY is a series another market lists: closeOutExpired would couple them"));
    script.checkParams(p);
  }

  function testIndexMaxAgeMustFitInsideTheSampleGap() public {
    DeployEurcFutureV3.Params memory p = params;
    p.indexMaxAge = 3 minutes;
    vm.expectRevert(bytes("INDEX_MAX_AGE must be positive and no longer than MAX_SAMPLE_GAP"));
    script.checkParams(p);
  }

  ///////////////////
  //   batches     //
  ///////////////////

  function testSetupReplacesTheRetiredSeriesAndOpensNothing() public {
    _setup();
    assertEq(IV3Ownable(address(d.future)).owner(), VAULT);
    assertEq(IV3Ownable(address(d.forwardFeed)).owner(), VAULT);
    assertEq(address(engine.assetMap(2, IMarginEngine.AssetType.Future)), address(d.future));
    assertFalse(engine.assetDetails(IAsset(RETIRED)).isWhitelisted, "the retired series is de-listed");
    assertTrue(engine.assetDetails(d.future).isWhitelisted);
    assertEq(address(engine.assetMap(1, IMarginEngine.AssetType.Future)), cngnFuture, "cNGN untouched");
    (uint mm, uint im) = engine.futureMarginRequirements(2);
    assertEq(mm, 0.1e18, "MM 10%, sized for a depeg (A7)");
    assertEq(im, 0.15e18, "IM 15%");
    assertEq(d.future.totalPositionCap(engine), 0, "still closed");
    assertFalse(IV3TradeModule(params.tradeModule).isDatedFutureAsset(address(d.future)));

    _holdPushFeeds();
    _postReports(block.timestamp, 1.1e18, 1e18);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
  }

  function testDeploysClosedUntilEnable() public {
    _setup();
    _enable();
    _holdPushFeeds();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    // no report yet: the index reverts, and so does a priced fill
    vm.expectRevert(EurcIndexFeed.EIF_NoReport.selector);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    _postReports(block.timestamp, int(refPrice), 1e18);
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);
  }

  /// @dev Uncapped (spec A6.0a, decided 2026-11-15): the enable batch opens the cap at type(uint).max, and a position
  ///      far over any measured cap (50 contracts, against the measurement's 4) fills. Nothing else bounds it on chain.
  function testUncappedDeploysAndFillsFarOverTheMeasuredCap() public {
    params.futureOICap = script.UNCAPPED();
    script.checkParams(params);
    d = script.deploy(params);
    _setup();
    _enable();
    assertEq(d.future.totalPositionCap(engine), type(uint).max);
    _holdPushFeeds();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _depositUsdc(alice, aliceAcc, 9_000e6);
    _depositUsdc(bob, bobAcc, 9_000e6);
    _postReports(block.timestamp, int(refPrice), 1e18);
    _trade(bobAcc, aliceAcc, 50e18, params.initialMark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 50e18);
  }

  function testTheCapMustBeChosenNotDefaulted() public {
    assertEq(script.resolveOICap(true, 0), type(uint).max);
    assertEq(script.resolveOICap(false, 4e18), 4e18);
    vm.expectRevert("set exactly one of FUTURE_OI_CAP or FUTURE_OI_UNCAPPED=true");
    script.resolveOICap(false, 0);
    vm.expectRevert("set exactly one of FUTURE_OI_CAP or FUTURE_OI_UNCAPPED=true");
    script.resolveOICap(true, 4e18);
  }

  ///////////////////
  //  live Matching //
  ///////////////////

  /// @dev Stage 1's path: a keeper posts reports, and a fill through the live Matching and TradeModule is checked
  ///      against them. With no fresh index the same fill reverts.
  function testItFillsThroughTheLiveTradeModuleAgainstKeeperReports() public {
    _setup();
    _enable();
    _holdPushFeeds();
    _liveMatching();
    uint takerAcc = _matchingAccount(vm.addr(takerPk), 1_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 1_000e6);

    _fillExpectingRevert(takerAcc, makerAcc, 1e18, int(params.initialMark), ""); // no report yet

    _postReports(block.timestamp, int(refPrice), 1e18);
    _fill(takerAcc, makerAcc, 1e18, int(params.initialMark), "");
    assertEq(subAccounts.getBalance(takerAcc, d.future, d.subId), 1e18, "taker long one contract");
    assertEq(subAccounts.getBalance(makerAcc, d.future, d.subId), -1e18, "maker short one contract");

    vm.warp(block.timestamp + 61); // past indexMaxAge with no new report
    _holdPushFeeds();
    _fillExpectingRevert(takerAcc, makerAcc, 1e18, int(params.initialMark), "");
  }

  /// @dev Attaching reports to an order does NOT work on the live venue (spec A2.2): the TradeModule pays the taker
  ///      fee to account #22, which sits under the perp SRM, and every manager a trade touches re-reads managerData
  ///      and requires the receiver on its own whitelist. Whitelisting the adapter on v2 alone is not enough, even with
  ///      it set here. If this starts passing, someone whitelisted it on the SRM: revisit A2.2.
  function testAttachedReportsRevertOnTheFeeAccountsManager() public {
    _setup();
    _enable();
    _holdPushFeeds();
    _liveMatching();
    vm.prank(VAULT);
    engine.setWhitelistedCallee(address(d.adapter), true);
    uint takerAcc = _matchingAccount(vm.addr(takerPk), 1_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 1_000e6);
    assertEq(subAccounts.ownerOf(22) != address(0), true);
    assertEq(address(subAccounts.manager(22)), 0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4, "fee account under the SRM");

    bytes memory attached = _attachedReports(block.timestamp, int(refPrice), 1e18);
    nonce++;
    (V3Action[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(takerAcc, makerAcc, 1e18, int(params.initialMark), attached);
    vm.expectRevert(IBaseManager.BM_UnauthorizedCall.selector);
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  ///////////////////
  //   fixing      //
  ///////////////////

  /// @dev Reports every 2 minutes through the 30-minute window at EURC/USD 1.105 and USDC/USD 0.9995: the series
  ///      settles at their ratio, positions close out, and USDC comes out.
  function testExpirySettlesAtTheStreamsRatioInUsdc() public {
    _setup();
    _enable();
    _holdPushFeeds();
    _postReports(block.timestamp, int(refPrice), 1e18);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _trade(bobAcc, aliceAcc, 2e18, params.initialMark);

    uint64 expiry = params.expiry;
    int eurc = 1.105e18;
    int usdc = 0.9995e18;
    uint ratio = uint(eurc) * 1e18 / uint(usdc);
    for (uint t = expiry - 30 minutes; t <= expiry; t += 2 minutes) {
      vm.warp(t);
      _holdPushFeeds();
      _postReports(t, eurc, usdc);
      d.future.recordFixingSample(d.subId);
    }
    vm.warp(expiry + 1);
    _holdPushFeeds();
    vm.prank(address(0xf1)); // anyone
    d.future.fixSettlementFromIndex(d.subId);
    assertEq(d.future.futureContracts(d.subId).markPrice, ratio, "settles at EURC/USD / USDC/USD");

    int aliceBefore = _settledCash(aliceAcc);
    int pending = d.future.getPendingVM(aliceAcc, d.subId);
    engine.closeOutExpired(bobAcc, d.subId);
    engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 0);
    assertEq(d.future.totalPosition(engine), 0, "no open interest left");
    assertEq(_cash(aliceAcc) - aliceBefore, pending, "the last VM, at the fixing");
    assertEq(pending, int(2 * 1_000) * (int(ratio) - int(params.initialMark)), "(fixing - entry) x 2,000 EURC");

    engine.settleInterest(aliceAcc);
    uint out = uint(_cash(aliceAcc)) / 1e12;
    vm.prank(alice);
    CashAsset(params.cash).withdraw(aliceAcc, out, alice);
    assertEq(IERC20Metadata(USDC).balanceOf(alice), out, "real USDC out");
  }

  /// @dev Reports stop for 5 minutes mid-window: the fixing cannot complete; anyone opens a recovery window, which
  ///      settles the series from fresh reports an hour later. No owner price exists to fall back on.
  function testABrokenFixingSettlesThroughARecoveryWindow() public {
    _setup();
    _enable();
    _holdPushFeeds();
    _postReports(block.timestamp, int(refPrice), 1e18);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    _trade(bobAcc, aliceAcc, 1e18, params.initialMark);

    uint64 expiry = params.expiry;
    for (uint t = expiry - 30 minutes; t <= expiry; t += 2 minutes) {
      if (t > expiry - 16 minutes && t < expiry - 10 minutes) continue; // the outage
      vm.warp(t);
      _holdPushFeeds();
      _postReports(t, 1.1e18, 1e18);
      d.future.recordFixingSample(d.subId);
    }
    vm.warp(expiry + 1);
    _holdPushFeeds();
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    d.future.fixSettlementFromIndex(d.subId);

    vm.prank(address(0xf2)); // anyone
    d.future.openRecoveryWindow(d.subId);
    IFutureAssetV3.Fixing memory f = d.future.fixings(d.subId);
    assertEq(f.round, 1);
    assertEq(f.windowStart, expiry + 1 + 1 hours, "starts a recovery delay later");

    for (uint t = f.windowStart; t <= f.windowEnd; t += 2 minutes) {
      vm.warp(t);
      _holdPushFeeds();
      _postReports(t, 1.12e18, 1e18);
      d.future.recordFixingSample(d.subId);
    }
    vm.warp(f.windowEnd + 1);
    _holdPushFeeds();
    d.future.fixSettlementFromIndex(d.subId);
    assertEq(d.future.futureContracts(d.subId).markPrice, 1.12e18, "the recovery window's price, not the broken one's");
    engine.closeOutExpired(bobAcc, d.subId);
    engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(d.future.totalPosition(engine), 0);
  }

  ///////////////////
  //   helpers     //
  ///////////////////

  function _setup() internal {
    _execute(script.vaultActionsJson(d, params), script.vaultActionCount());
  }

  function _enable() internal {
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

  function _holdPushFeeds() internal {
    vm.mockCall(params.referenceFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(refPrice, 1e18));
    vm.mockCall(params.cngnIndexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(cngnSpot, 1e18));
  }

  /// @dev A V3 report as the Data Streams API serves it, with the verifier mocked to return its report data for
  ///      exactly this payload and the adapter's parameter payload.
  function _report(bytes32 feedId, uint observedAt, int price) internal returns (bytes memory full) {
    StreamsIndexAdapter.ReportV3 memory r = StreamsIndexAdapter.ReportV3({
      feedId: feedId,
      validFromTimestamp: uint32(observedAt),
      observationsTimestamp: uint32(observedAt),
      nativeFee: 0,
      linkFee: 0,
      expiresAt: uint32(observedAt + 30 days),
      benchmarkPrice: int192(price),
      bid: int192(price),
      ask: int192(price)
    });
    bytes32[3] memory ctx;
    bytes memory data = abi.encode(r);
    full = abi.encode(ctx, data, new bytes32[](0), new bytes32[](0), bytes32(0));
    vm.mockCall(VERIFIER, abi.encodeCall(IStreamsVerifierProxy.verify, (full, abi.encode(LINK))), abi.encode(data));
  }

  function _reports(uint observedAt, int eurc, int usdc) internal returns (bytes[] memory reports) {
    reports = new bytes[](2);
    reports[0] = _report(EURC_FEED, observedAt, eurc);
    reports[1] = _report(USDC_FEED, observedAt, usdc);
  }

  function _postReports(uint observedAt, int eurc, int usdc) internal {
    d.adapter.postReports(_reports(observedAt, eurc, usdc));
  }

  function _attachedReports(uint observedAt, int eurc, int usdc) internal returns (bytes memory) {
    IBaseManager.ManagerData[] memory data = new IBaseManager.ManagerData[](1);
    data[0] =
      IBaseManager.ManagerData({receiver: address(d.adapter), data: abi.encode(_reports(observedAt, eurc, usdc))});
    return abi.encode(data);
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
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller, toAcc: buyer, asset: d.future, subId: d.subId, amount: amount, assetData: bytes32(price)
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

  function _liveMatching() internal {
    matching = IV3Matching(IV3TradeModule(params.tradeModule).matching());
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);
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

  function _fill(uint takerAcc, uint makerAcc, uint amount, int price, bytes memory managerData) internal {
    _match(takerAcc, makerAcc, amount, price, managerData, false);
  }

  function _fillExpectingRevert(uint takerAcc, uint makerAcc, uint amount, int price, bytes memory managerData)
    internal
  {
    _match(takerAcc, makerAcc, amount, price, managerData, true);
  }

  function _match(uint takerAcc, uint makerAcc, uint amount, int price, bytes memory managerData, bool reverts)
    internal
  {
    nonce++;
    (V3Action[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(takerAcc, makerAcc, amount, price, managerData);
    if (reverts) vm.expectRevert();
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _order(uint takerAcc, uint makerAcc, uint amount, int price, bytes memory managerData)
    internal
    view
    returns (V3Action[] memory actions, bytes[] memory sigs, bytes memory orderData)
  {
    actions = new V3Action[](2);
    sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, takerPk, price, amount);
    (actions[1], sigs[1]) = _sign(makerAcc, false, makerPk, price, amount);
    V3FillDetails[] memory fills = new V3FillDetails[](1);
    fills[0] = V3FillDetails({filledAccount: makerAcc, amountFilled: amount, price: price, fee: 0});
    orderData =
      abi.encode(V3OrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: managerData}));
  }

  function _sign(uint accountId, bool isBid, uint pk, int price, uint amount)
    internal
    view
    returns (V3Action memory action, bytes memory signature)
  {
    address owner = vm.addr(pk);
    action = V3Action({
      subaccountId: accountId,
      nonce: nonce,
      module: params.tradeModule,
      data: abi.encode(
        V3TradeData({
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
