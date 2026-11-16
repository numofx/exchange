// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {StreamsIndexAdapter} from "../../src/feeds/StreamsIndexAdapter.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IFutureAssetV3} from "../../src/interfaces/IFutureAssetV3.sol";
import {OnchainBook, IOnchainBookManager} from "../../src/periphery/OnchainBook.sol";

/**
 * OnchainBook against the live EURC-30NOV26 v3 stack on Base (docs/eurc-usdc-futures-spec.md, B10, B11): the
 * deployed SubAccounts, MarginEngine v2, FutureAsset v3, StreamsIndexAdapter, the fee account #22 under the perp SRM,
 * and **Chainlink's real verifier**. Nothing is mocked.
 *
 * The reports are real: the ones the v3 keeper posted in block 57,985,893 (tx 0x3fc53469…96db), taken from its
 * calldata (fixtures/eurc-streams-reports-57985893.hex). The fork is the block before, so they are newer than anything
 * the adapter holds, and the taker attaches them: the take is priced from reports the real verifier checks.
 *
 * Gas (B10) is logged by testGas*: run with -vv.
 *
 * Requires BASE_RPC_URL.
 */
contract OnchainBookFork is Test {
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  IFutureAssetV3 constant FUTURE = IFutureAssetV3(0xC350243c1d07Ff598770ECe12323799D2EFbB227);
  uint96 constant SUB_ID = 1796050800;
  StreamsIndexAdapter constant ADAPTER = StreamsIndexAdapter(0x9E9aB6ee5ccf0b050Eba0b64Ce9429334D49FfEB);
  MarginEngine constant ENGINE = MarginEngine(0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950);
  CashAsset constant CASH = CashAsset(0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272);
  uint constant FEE_ACCOUNT = 22;

  /// @dev The block before the keeper's report post in 57,985,893 (timestamp 1,794,787,554). Pinned: the world
  ///      before the post (CLAUDE.md: chain state moves under tests).
  uint constant FORK_BLOCK = 57_985_892;
  uint constant POST_TIME = 1_794_787_554;

  uint constant TICK = 1e12;
  uint constant LOT = 1e15;
  uint constant FEE_RATE = 0.0005e18;

  SubAccounts subAccounts;
  OnchainBook book;
  uint mkt;
  bytes reports;
  uint index; // the ratio the attached reports set
  uint32 takeMaxAge;

  address bob = address(0xb0b);
  uint bobAcc;
  uint[] makerAccs;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    subAccounts = SubAccounts(address(ENGINE.subAccounts()));
    reports = vm.parseBytes(vm.readFile("test/fork/fixtures/eurc-streams-reports-57985893.hex"));

    // the age of the older report at the post, so takes at POST_TIME count it fresh
    bytes[] memory r = abi.decode(reports, (bytes[]));
    uint oldest = type(uint).max;
    uint base;
    uint quote;
    for (uint i; i < r.length; ++i) {
      (, bytes memory data) = abi.decode(r[i], (bytes32[3], bytes));
      StreamsIndexAdapter.ReportV3 memory rep = abi.decode(data, (StreamsIndexAdapter.ReportV3));
      if (rep.observationsTimestamp < oldest) oldest = rep.observationsTimestamp;
      if (rep.feedId == ADAPTER.baseFeedId()) base = uint(uint192(rep.benchmarkPrice));
      else quote = uint(uint192(rep.benchmarkPrice));
    }
    index = base * 1e18 / quote;
    vm.warp(POST_TIME);
    takeMaxAge = uint32(POST_TIME - oldest);
    if (takeMaxAge == 0) takeMaxAge = 1;

    book = new OnchainBook(subAccounts, IAsset(address(CASH)), FEE_ACCOUNT);
    mkt = book.createMarket(FUTURE, SUB_ID, IOnchainBookManager(address(ENGINE)), ADAPTER, TICK, LOT);
    book.setMarketParams(mkt, FEE_RATE, takeMaxAge, 1 hours, 10, true);
    bobAcc = _account(bob, 10_000e6);
  }

  /////////////
  // Helpers //
  /////////////

  function _account(address owner, uint usdc) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, IManager(address(ENGINE)));
    deal(USDC, owner, usdc);
    vm.startPrank(owner);
    IERC20Metadata(USDC).approve(address(CASH), usdc);
    CASH.deposit(acc, usdc);
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(FUTURE, type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(address(CASH)), type(uint).max, type(uint).max);
    subAccounts.setAssetAllowances(acc, address(book), a);
    vm.stopPrank();
  }

  /// @dev `n` makers, each with a curve of `regions` regions of 200 lots, 50 ticks apart, quoting both sides 100 ticks
  ///      around the index; maker i is i ticks worse than maker 0, so a take walks them in turn.
  function _makers(uint n, uint regions) internal {
    for (uint i; i < n; ++i) {
      address owner = address(uint160(0x1000 + i));
      book.setMakerAllowed(owner, true);
      uint acc = _account(owner, 20_000e6);
      makerAccs.push(acc);
      OnchainBook.Region[] memory r = new OnchainBook.Region[](regions);
      for (uint j; j < regions; ++j) {
        r[j] = OnchainBook.Region(200, uint32(j * 50));
      }
      vm.startPrank(owner);
      book.setCurve(1, r);
      book.registerMaker(mkt, acc);
      OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
      u[0] = OnchainBook.SplineUpdate(mkt, acc, int32(int(i)), 100, 1, 1, 0, 0, 0, 1 hours, 1);
      book.updateSplines(u);
      vm.stopPrank();
    }
  }

  function _order(bool isBuy, uint lots) internal view returns (OnchainBook.TakeOrder memory) {
    return OnchainBook.TakeOrder({
      marketId: mkt,
      takerAccountId: bobAcc,
      isBuy: isBuy,
      amount: lots * LOT,
      limitPrice: isBuy ? 2e18 : 0,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 255,
      selfTradeMode: OnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
  }

  function _takeGas(OnchainBook.TakeOrder memory o, bytes memory report) internal returns (uint gas, uint filled) {
    vm.prank(bob);
    uint before = gasleft();
    (filled,) = book.take(o, report);
    gas = before - gasleft();
  }

  ///////////
  // Tests //
  ///////////

  /// The keeper's stored reports are older than takeMaxAge here, so without the attached ones nothing is quoted.
  function testWithoutTheAttachedReportsNothingFills() public {
    _makers(1, 1);
    (, uint64 storedAt) = ADAPTER.latest(ADAPTER.baseFeedId());
    assertGt(POST_TIME - storedAt, takeMaxAge, "the stored report is stale for a take");
    vm.prank(bob);
    (uint filled,) = book.take(_order(true, 100), "");
    assertEq(filled, 0);
  }

  /// A take priced from real reports that Chainlink's verifier checks inside the take, filled through the live
  /// engine, with the fee paid to #22 under the perp SRM.
  function testATakeVerifiesRealReportsAndFillsOnTheLiveEngine() public {
    _makers(1, 1);
    uint maker = makerAccs[0];
    int feeBefore = subAccounts.getBalance(FEE_ACCOUNT, CASH, 0);
    uint oiBefore = _oi();

    vm.prank(bob);
    (uint filled, uint avg) = book.take(_order(true, 150), reports);

    (uint stored,) = ADAPTER.latest(ADAPTER.baseFeedId());
    assertGt(stored, 0);
    uint indexTicks = index / TICK;
    assertEq(avg, (indexTicks + 100) * TICK, "the ask 100 ticks above the verified index");
    assertEq(filled, 150 * LOT);
    assertEq(subAccounts.getBalance(bobAcc, FUTURE, SUB_ID), int(150 * LOT));
    assertEq(subAccounts.getBalance(maker, FUTURE, SUB_ID), -int(150 * LOT));
    uint fee = (150 * LOT * 1_000 * avg / 1e18 * FEE_RATE + 1e18 - 1) / 1e18;
    // #22's cash accrues the live interest rate when touched: a few seconds on its balance, far under a micro-USDC
    assertApproxEqAbs(
      subAccounts.getBalance(FEE_ACCOUNT, CASH, 0) - feeBefore, int(fee), 1e12, "fee at #22, under the perp SRM"
    );
    assertGe(subAccounts.getBalance(FEE_ACCOUNT, CASH, 0) - feeBefore, int(fee));
    assertEq(_oi(), oiBefore + 2 * 150 * LOT, "both legs counted: totalPosition sums |positions|");
  }

  /// The verification is real: one flipped bit in a report's signatures and Chainlink's verifier refuses the take.
  function testATamperedSignatureIsRefusedByTheRealVerifier() public {
    _makers(1, 1);
    bytes[] memory r = abi.decode(reports, (bytes[]));
    (bytes32[3] memory ctx, bytes memory data, bytes32[] memory rs, bytes32[] memory ss, bytes32 v) =
      abi.decode(r[0], (bytes32[3], bytes, bytes32[], bytes32[], bytes32));
    rs[0] ^= bytes32(uint(1));
    r[0] = abi.encode(ctx, data, rs, ss, v);
    vm.prank(bob);
    vm.expectRevert(bytes4(0x4df18f07)); // raised by the verifier 0x2237…fB83 behind the proxy
    book.take(_order(true, 150), abi.encode(r));
  }

  function testASellFillsTooAndPositionsNet() public {
    _makers(2, 2);
    vm.prank(bob);
    (uint filled,) = book.take(_order(false, 500), reports);
    assertEq(filled, 500 * LOT);
    int net = subAccounts.getBalance(bobAcc, FUTURE, SUB_ID);
    for (uint i; i < makerAccs.length; ++i) {
      net += subAccounts.getBalance(makerAccs[i], FUTURE, SUB_ID);
    }
    assertEq(net, 0);
  }

  /// B10: one take against 1 maker with and without the report verification, then 2, 5 and 10 makers one level
  /// each, and 1 maker with 10 levels. Logged, and held under ceilings so a regression shows.
  function testGasPerTake() public {
    _makers(10, 10);
    uint snap = vm.snapshotState();

    (uint withReports,) = _takeGas(_order(true, 200), reports);
    vm.revertToState(snap);
    snap = vm.snapshotState();
    ADAPTER.acceptData(reports);
    (uint oneMaker,) = _takeGas(_order(true, 200), "");
    vm.revertToState(snap);
    console.log("take, 1 maker, 1 level, reports attached:", withReports);
    console.log("take, 1 maker, 1 level, reports already posted:", oneMaker);
    console.log("  so verifying both reports costs:", withReports - oneMaker);

    // maker i quotes i ticks worse, regions 50 ticks apart: a take of k x 200 lots fills makers 0..k-1 at region 0
    uint[3] memory ks = [uint(2), 5, 10];
    for (uint j; j < ks.length; ++j) {
      snap = vm.snapshotState();
      ADAPTER.acceptData(reports);
      (uint g, uint filled) = _takeGas(_order(true, 200 * ks[j]), "");
      vm.revertToState(snap);
      assertEq(filled, 200 * ks[j] * LOT);
      console.log("take, makers filled:", ks[j], "gas:", g);
    }

    // one maker, ten levels: only maker 0 quoted
    for (uint i = 1; i < makerAccs.length; ++i) {
      book.removeMaker(mkt, makerAccs[i]);
    }
    ADAPTER.acceptData(reports);
    (uint tenLevels, uint f10) = _takeGas(_order(true, 2000), "");
    assertEq(f10, 2000 * LOT);
    console.log("take, 1 maker, 10 levels:", tenLevels);
    assertLt(oneMaker, 1_500_000, "ceiling: one maker");
  }

  /// B10: updateSplines for 1 and for 10 markets in one call.
  function testGasPerSplineUpdate() public {
    _makers(1, 1);
    address owner = subAccounts.ownerOf(makerAccs[0]);
    uint[] memory ids = new uint[](10);
    ids[0] = mkt;
    for (uint i = 1; i < 10; ++i) {
      ids[i] = book.createMarket(FUTURE, SUB_ID, IOnchainBookManager(address(ENGINE)), ADAPTER, TICK, LOT);
      book.setMarketParams(ids[i], FEE_RATE, takeMaxAge, 1 hours, 10, true);
      vm.prank(owner);
      book.registerMaker(ids[i], makerAccs[0]);
    }
    OnchainBook.SplineUpdate[] memory one = new OnchainBook.SplineUpdate[](1);
    one[0] = OnchainBook.SplineUpdate(mkt, makerAccs[0], 3, 100, 1, 1, 0, 0, 0, 1 hours, 2);
    OnchainBook.SplineUpdate[] memory ten = new OnchainBook.SplineUpdate[](10);
    for (uint i; i < 10; ++i) {
      ten[i] = OnchainBook.SplineUpdate(ids[i], makerAccs[0], 4, 100, 1, 1, 0, 0, 0, 1 hours, 3);
    }
    vm.startPrank(owner);
    uint before = gasleft();
    book.updateSplines(one);
    uint g1 = before - gasleft();
    before = gasleft();
    book.updateSplines(ten);
    uint g10 = before - gasleft();
    vm.stopPrank();
    console.log("updateSplines, 1 market (warm):", g1);
    console.log("updateSplines, 10 markets:", g10);
  }

  function _oi() internal view returns (uint) {
    (bool ok, bytes memory ret) =
      address(FUTURE).staticcall(abi.encodeWithSignature("totalPosition(address)", address(ENGINE)));
    require(ok, "totalPosition");
    return abi.decode(ret, (uint));
  }
}
