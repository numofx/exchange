// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployCngnDatedFuture} from "../../scripts/deploy-cngn-dated-future.s.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {DutchAuction} from "../../src/liquidation/DutchAuction.sol";
import {StandardManager} from "../../src/risk-managers/StandardManager.sol";
import {IDatedFutureAsset} from "../../src/interfaces/IDatedFutureAsset.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";

interface IOwnableLike {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

interface ITradeModuleLike {
  function isDatedFutureAsset(address) external view returns (bool);
}

/**
 * Runs deploy-cngn-dated-future.s.sol's own `deploy` on a Base fork at head, plays the vault's side by executing the
 * generated batches exactly as written, and takes a position through its life on the live perp cash, cNGN escrow and
 * index feed: open, daily marks, the index fixing, close-out, and withdrawal of real USDC and cNGN.
 *
 * At head because it is about deploying into the world as it is now. The index feed goes stale once the test warps
 * past its heartbeat, so from the first warp it is held at its live value with mockCall; that is the only thing
 * mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract CngnDatedFutureDeployFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address treasury = address(0x7ea5);

  DeployCngnDatedFuture script;
  DeployCngnDatedFuture.Params params;
  DeployCngnDatedFuture.Deployment d;
  SubAccounts subAccounts;

  uint spot; // USDC per cNGN, live
  uint index; // cNGN per USDC
  uint perpMarketsBefore;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    script = new DeployCngnDatedFuture();

    // The initial mark is the operator's input; here, 1% over the live index, as a forward would sit.
    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json"));
    (spot,) = ISpotFeed(vm.parseJsonAddress(stack, ".indexFeed")).getSpot();
    index = 1e36 / spot;
    vm.setEnv("INITIAL_MARK", vm.toString(index * 101 / 100));

    params = script.loadParams();
    subAccounts = SubAccounts(params.subAccounts);
    perpMarketsBefore = StandardManager(params.perpSrm).lastMarketId();
    d = script.deploy(params);
  }

  ///////////////////
  //  the script   //
  ///////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(d, params);
  }

  function testInitialMarkOutsideTheIndexBandIsRefused() public {
    DeployCngnDatedFuture.Params memory p = params;
    p.initialMark = index * 111 / 100;
    vm.expectRevert(bytes("INITIAL_MARK is outside the index band"));
    script.checkParams(p);
  }

  function testLastTradeAfterTheFixingWindowStartIsRefused() public {
    DeployCngnDatedFuture.Params memory p = params;
    p.lastTradeTime = p.expiry - 30 minutes;
    vm.expectRevert(bytes("last trade must be no later than the fixing window's start"));
    script.checkParams(p);
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
    assertTrue(CashAsset(params.cash).whitelistedManager(address(d.manager)), "cash takes the manager");
    assertTrue(WrappedERC20Asset(params.cngnEscrow).whitelistedManager(address(d.manager)), "escrow takes it");
    assertEq(WrappedERC20Asset(params.cngnEscrow).totalPositionCap(d.manager), params.futureCngnCap);
    assertTrue(DutchAuction(params.auction).managerWhitelisted(address(d.manager)), "auction takes it");

    vm.prank(address(script));
    vm.expectRevert();
    d.future.setTotalPositionCap(d.manager, type(uint).max);
  }

  function testDeploysClosedUntilTheEnableBatch() public {
    _executeVaultBatch();
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    // read before expectRevert: an external call in the arguments would be the call it expects to revert
    uint mark = d.future.futureContracts(d.subId).markPrice;
    vm.expectRevert(bytes4(keccak256("BM_AssetCapExceeded()")));
    _trade(bobAcc, aliceAcc, 1e18, mark);

    _executeEnableBatch();
    assertEq(d.future.totalPositionCap(d.manager), params.futureOICap);
    assertTrue(ITradeModuleLike(params.perpTradeModule).isDatedFutureAsset(address(d.future)), "registered");
    _trade(bobAcc, aliceAcc, 1e18, mark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);
  }

  function testThePerpIsUntouched() public {
    _executeVaultBatch();
    _executeEnableBatch();
    StandardManager perpSrm = StandardManager(params.perpSrm);
    assertEq(perpSrm.lastMarketId(), perpMarketsBefore, "perp srm gained a market");
    assertFalse(d.future.whitelistedManager(params.perpSrm), "future must not accept the perp srm");
    assertEq(address(perpSrm.cashAsset()), params.cash, "perp cash moved");
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
    d.future.setDailyMark(d.subId, uint64(block.timestamp), mark1);

    int expectedVM = int(2 * 1_000 * (mark1 - mark0));
    assertEq(d.future.getPendingVM(aliceAcc, d.subId), expectedVM);
    d.manager.settleAccount(bobAcc);
    d.manager.settleAccount(aliceAcc);
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
    d.manager.closeOutExpired(bobAcc, d.subId);
    d.manager.closeOutExpired(aliceAcc, d.subId);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 0);
    assertEq(subAccounts.getBalance(bobAcc, d.future, d.subId), 0);
    assertEq(d.future.totalPosition(d.manager), 0, "no open interest left");

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
    d.future.setDailyMark(d.subId, uint64(block.timestamp), mark0 * 102 / 100);

    // accrue interest first, so the delta below is the VM payment alone
    d.manager.settleInterest(aliceAcc);
    int cashBefore = subAccounts.getBalance(aliceAcc, _cash(), 0);
    d.manager.settleAccount(aliceAcc);
    int cashAfter = subAccounts.getBalance(aliceAcc, _cash(), 0);
    uint vmCngn = 1_000 * (mark0 * 102 / 100 - mark0);
    assertApproxEqAbs(cashAfter - cashBefore, int(vmCngn * spot / 1e18), 1, "paid the cNGN's value in USDC");
    assertLt(subAccounts.getBalance(d.poolAccount, _cash(), 0), 0, "the pool owes the cash until treasury tops up");
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

  function _cash() internal view returns (CashAsset) {
    return CashAsset(params.cash);
  }

  function _account(address user) internal returns (uint) {
    return subAccounts.createAccountWithApproval(user, address(this), IManager(address(d.manager)));
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
