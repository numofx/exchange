// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {StreamsIndexAdapter} from "../../src/feeds/StreamsIndexAdapter.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {OnchainBook} from "../../src/periphery/OnchainBook.sol";

import {DeployOnchainBook} from "../../scripts/deploy-onchain-book.s.sol";

/**
 * deploy-onchain-book.s.sol against the live EURC v3 stack on Base: the script's own deploy, its postconditions, its
 * two vault batches replayed from their JSON as the vault, and a take after enable priced from real Data Streams
 * reports that Chainlink's verifier checks (the fixture of OnchainBookFork). Every pre-flight refusal is exercised.
 *
 * Requires BASE_RPC_URL.
 */
contract OnchainBookDeployFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint constant FEE_ACCOUNT = 22;

  /// @dev As OnchainBookFork: the block before the keeper's report post in 57,985,893, v3 open for trading. Pinned.
  uint constant FORK_BLOCK = 57_985_892;
  uint constant POST_TIME = 1_794_787_554;
  uint constant FEE_RATE = 0.0005e18;

  DeployOnchainBook script;
  DeployOnchainBook.Params params;
  OnchainBook book;
  SubAccounts subAccounts;
  bytes reports;

  address maker = address(0x3a4e);
  address bob = address(0xb0b);

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    vm.warp(POST_TIME);
    reports = vm.parseBytes(vm.readFile("test/fork/fixtures/eurc-streams-reports-57985893.hex"));

    script = new DeployOnchainBook();
    params = script.loadChainParams();
    params.takerFeeRate = FEE_RATE;
    params.makerOwner = maker;
    // the attached reports' age at POST_TIME (OnchainBookFork derives the same): a take counts them fresh
    params.takeMaxAge = _reportAge();
    script.checkParams(params);
    subAccounts = SubAccounts(params.subAccounts);

    book = script.deploy(params);
  }

  /////////////
  // Helpers //
  /////////////

  function _reportAge() internal view returns (uint32) {
    bytes[] memory r = abi.decode(reports, (bytes[]));
    uint oldest = type(uint).max;
    for (uint i; i < r.length; ++i) {
      (, bytes memory data) = abi.decode(r[i], (bytes32[3], bytes));
      StreamsIndexAdapter.ReportV3 memory rep = abi.decode(data, (StreamsIndexAdapter.ReportV3));
      if (rep.observationsTimestamp < oldest) oldest = rep.observationsTimestamp;
    }
    uint age = POST_TIME - oldest;
    return uint32(age == 0 ? 1 : age);
  }

  function _execute(string memory json, uint count) internal {
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      bytes32 digest = vm.parseJsonBytes32(json, string.concat(key, ".digest"));
      assertEq(digest, keccak256(abi.encodePacked(to, keccak256(data))), "digest must match its own action");
      assertEq(to, address(book), "every action is on the book: nothing on the engine or the future");
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, string.concat("vault action ", vm.toString(i), " failed"));
    }
  }

  function _setup() internal {
    _execute(script.vaultActionsJson(address(book), params), script.vaultActionCount());
  }

  function _enable() internal {
    _execute(script.enableActionsJson(address(book), params), script.enableActionCount());
  }

  function _account(address owner, uint usdc) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, IManager(params.engine));
    deal(USDC, owner, usdc);
    vm.startPrank(owner);
    IERC20Metadata(USDC).approve(params.cash, usdc);
    CashAsset(params.cash).deposit(acc, usdc);
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(IAsset(params.future), type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(params.cash), type(uint).max, type(uint).max);
    subAccounts.setAssetAllowances(acc, address(book), a);
    vm.stopPrank();
  }

  /// @dev The maker registers and quotes 100 ticks around the index: what it can do between setup and enable.
  function _quote() internal returns (uint acc) {
    acc = _account(maker, 20_000e6);
    OnchainBook.Region[] memory r = new OnchainBook.Region[](1);
    r[0] = OnchainBook.Region(1000, 0);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(1, acc, 0, 100, 1, 1, 0, 0, 0, 1 hours, 1);
    vm.startPrank(maker);
    book.setCurve(1, r);
    book.registerMaker(1, acc);
    book.updateSplines(u);
    vm.stopPrank();
  }

  function _order(uint takerAcc, uint lots) internal view returns (OnchainBook.TakeOrder memory) {
    return OnchainBook.TakeOrder({
      marketId: 1,
      takerAccountId: takerAcc,
      isBuy: true,
      amount: lots * params.lotSize,
      limitPrice: 2e18,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 255,
      selfTradeMode: OnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
  }

  function _refuses(DeployOnchainBook.Params memory p, string memory why) internal {
    vm.expectRevert(bytes(why));
    script.checkParams(p);
  }

  ////////////////
  // the script //
  ////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(book, params, address(script));
  }

  function testTheBookIsOnTheSeriesAndTheTradeModulesFeeAccount() public view {
    assertEq(params.feeRecipient, FEE_ACCOUNT, "the TradeModule's fee account, read live");
    assertEq(params.future, 0xC350243c1d07Ff598770ECe12323799D2EFbB227);
    assertEq(params.subId, 1796050800);
    assertEq(params.adapter, 0x9E9aB6ee5ccf0b050Eba0b64Ce9429334D49FfEB);
    assertEq(params.engine, 0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950);
    assertEq(params.cash, 0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272);
  }

  /// Setup accepts and allows the maker, who can then register and quote; nothing fills until enable, and after it
  /// a take priced from real reports fills on the live engine with the fee at #22.
  function testClosedUntilEnableThenATakeFills() public {
    _setup();
    assertEq(book.owner(), VAULT);
    assertTrue(book.makerAllowed(maker));
    uint makerAcc = _quote();
    uint bobAcc = _account(bob, 10_000e6);

    vm.prank(bob);
    vm.expectRevert(OnchainBook.OB_MarketDisabled.selector);
    book.take(_order(bobAcc, 150), reports);

    _enable();
    int feeBefore = subAccounts.getBalance(FEE_ACCOUNT, IAsset(params.cash), 0);
    vm.prank(bob);
    (uint filled,) = book.take(_order(bobAcc, 150), reports);
    assertEq(filled, 150 * params.lotSize);
    assertEq(subAccounts.getBalance(makerAcc, IAsset(params.future), params.subId), -int(150 * params.lotSize));
    assertGt(subAccounts.getBalance(FEE_ACCOUNT, IAsset(params.cash), 0), feeBefore, "fee at #22");
  }

  /// Enable sets exactly what was deployed, opened: nothing else moves.
  function testEnableChangesOnlyEnabled() public {
    _setup();
    _enable();
    OnchainBook.Market memory m = script.marketOf(book);
    assertTrue(m.enabled);
    assertEq(m.takerFeeRate, params.takerFeeRate);
    assertEq(m.takeMaxAge, params.takeMaxAge);
    assertEq(m.maxTtl, params.maxTtl);
    assertEq(m.maxMakers, params.maxMakers);
    assertEq(m.tickSize, params.tickSize);
    assertEq(address(m.future), params.future);
  }

  function testOnlyTheNamedMakerMayRegister() public {
    _setup();
    address other = address(0x0e1);
    uint acc = _account(other, 1_000e6);
    vm.prank(other);
    vm.expectRevert(OnchainBook.OB_MakerNotAllowed.selector);
    book.registerMaker(1, acc);
  }

  /// Before setup nobody is allowed, the maker included; after it, the deployer holds nothing.
  function testTheDeployerHoldsNothingOnceTheVaultAccepts() public {
    uint acc = _account(maker, 1_000e6);
    vm.prank(maker);
    vm.expectRevert(OnchainBook.OB_MakerNotAllowed.selector);
    book.registerMaker(1, acc);

    _setup();
    vm.prank(address(script));
    vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(script)));
    book.setMarketParams(1, FEE_RATE, 1, 1 hours, 10, true);
  }

  /////////////////////////
  // pre-flight refusals //
  /////////////////////////

  function testTheFeeMustBeChosenNotDefaulted() public {
    vm.expectRevert(bytes("set TAKER_FEE_RATE (18 dp): it has no default"));
    script.resolveRequired(type(uint).max, "TAKER_FEE_RATE");
    assertEq(script.resolveRequired(0, "TAKER_FEE_RATE"), 0, "a zero fee is a choice");
  }

  function testParameterBoundsAreChecked() public {
    DeployOnchainBook.Params memory p = params;
    p.takeMaxAge = 0;
    _refuses(p, "TAKE_MAX_AGE must be positive and no longer than the index's own max age (B6a)");
    p.takeMaxAge = 61;
    _refuses(p, "TAKE_MAX_AGE must be positive and no longer than the index's own max age (B6a)");
    p = params;
    p.maxMakers = 11;
    _refuses(p, "MAX_MAKERS: 1 to 10 (B10: 10 makers is 6.6M gas a take)");
    p = params;
    p.gasFloor = 599_999;
    _refuses(p, "GAS_FLOOR under 600,000 skips honest makers (B5a, B10)");
    p = params;
    p.priorityTaxRate = 1;
    _refuses(p, "PRIORITY_TAX_RATE must be 0 at rollout (B12: tax off)");
    p = params;
    p.takerFeeRate = 0.01e18 + 1;
    _refuses(p, "TAKER_FEE_RATE over 1%: give it 18dp (5 bps is 5e14)");
    p = params;
    p.tickSize = 1e15 + 1;
    _refuses(p, "TICK_SIZE: 1 to 1e15 (0.001 USDC per EURC)");
    p = params;
    p.lotSize = 0;
    _refuses(p, "LOT_SIZE: 1 to 1e18 (one contract)");
    p = params;
    p.maxTtl = 1 days + 1;
    _refuses(p, "MAX_TTL: 1 s to 1 day");
  }

  function testTheMakerOwnerIsChecked() public {
    DeployOnchainBook.Params memory p = params;
    p.makerOwner = address(0);
    _refuses(p, "set MAKER_OWNER: the address owning the maker's account (B3)");
    p.makerOwner = VAULT;
    _refuses(p, "MAKER_OWNER is the vault");
    (bool ok, bytes memory ret) = params.tradeModule.staticcall(abi.encodeWithSignature("matching()"));
    assertTrue(ok);
    p.makerOwner = abi.decode(ret, (address));
    _refuses(p, "MAKER_OWNER is Matching: the book cannot reach accounts Matching holds (B3)");
  }

  function testTheSeriesIsChecked() public {
    DeployOnchainBook.Params memory p = params;
    p.future = address(0xdead);
    _refuses(p, "market 2's future is not the EURC v3 series");
    p = params;
    p.lastTradeTime = params.lastTradeTime - 1;
    _refuses(p, "the series' last trade is not the artifact's");
    p = params;
    p.indexFeed = address(0xbeef);
    _refuses(p, "the future's index is not the artifact's");
    p = params;
    p.adapter = address(0xbeef);
    _refuses(p, "the index's adapter is not the artifact's");
    p = params;
    p.cash = address(0xbeef);
    _refuses(p, "engine cash is not the series artifact's");
    vm.warp(params.lastTradeTime - 2 hours);
    _refuses(params, "under 2 hours to the series' last trade");
  }

  function testTheDeployerIsChecked() public {
    vm.expectRevert(
      bytes("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)")
    );
    script.checkDeployer(params, address(0xd1), 5, address(0));
    script.checkDeployer(params, address(0xd1), 5, address(0xd1));
    vm.expectRevert(bytes("deployer is the vault"));
    script.checkDeployer(params, VAULT, 0, address(0));
    vm.expectRevert(bytes("deployer is the maker owner"));
    script.checkDeployer(params, maker, 0, address(0));
    vm.expectRevert(bytes("run with --account <keystore> (or --private-key): no sender given"));
    script.checkDeployer(params, 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, 0, address(0));
  }

  /// The postconditions are not vacuous: a book the engine trusts, or one deployed open, is refused.
  function testThePostconditionsCatchWhatTheyClaim() public {
    vm.mockCall(params.engine, abi.encodeWithSignature("trustedRiskAssessor(address)", address(book)), abi.encode(true));
    vm.expectRevert(bytes("the book is a trustedRiskAssessor"));
    script.assertDeployment(book, params, address(script));
    vm.clearMockedCalls();

    vm.prank(address(script));
    book.setMarketParams(1, FEE_RATE, params.takeMaxAge, params.maxTtl, params.maxMakers, true);
    vm.expectRevert(bytes("the market must deploy closed"));
    script.assertDeployment(book, params, address(script));
  }
}
