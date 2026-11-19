// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {OnchainBook} from "../../src/periphery/OnchainBook.sol";
import {OnchainBookRouter, IRouterCash} from "../../src/periphery/OnchainBookRouter.sol";
import {DeployOnchainBookCngn} from "../../scripts/deploy-onchain-book-cngn.s.sol";

/**
 * deploy-onchain-book-cngn.s.sol against Base: its exact deploy and postconditions, the vault's setup and enable
 * batches as the script writes them, then a self-priced take on cNGN-30NOV26 through the live engine. The cNGN future
 * is FutureAsset v2, read through v3's interface: every call the script and the book make on it is exercised here.
 * Requires BASE_RPC_URL.
 */
contract OnchainBookCngnDeployFork is Test {
  uint constant FORK_BLOCK = 59_240_000;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant MAKER = 0x7b96cFc1C909318Ed55F50ABD7D2EFC52f1eBE4d;
  address constant DEPLOYER = 0x4FECe4c226b5eF0C235aEA97216e61b69FE5263f;
  uint constant FEE = 1.5e15;

  DeployOnchainBookCngn script;
  DeployOnchainBookCngn.Params params;
  OnchainBook book;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    script = new DeployOnchainBookCngn();
    vm.setEnv("TAKER_FEE_RATE", vm.toString(FEE));
    vm.setEnv("MAKER_OWNER", vm.toString(MAKER));
    params = script.loadParams();
    vm.startPrank(DEPLOYER);
    book = script.deploy(params);
    vm.stopPrank();
  }

  function _vault(bytes memory data) internal {
    vm.prank(params.vault);
    (bool ok, bytes memory ret) = address(book).call(data);
    if (!ok) {
      assembly {
        revert(add(ret, 32), mload(ret))
      }
    }
  }

  function testThePostconditionsHold() public view {
    script.assertDeployment(book, params, DEPLOYER);
    assertEq(params.tickSize, 1e10);
    assertEq(params.subId, 1796047200);
    assertEq(book.indexFeedOf(1), 0xFaC420d160C7c219A72DC676971670980bAC20a5);
  }

  function testTheRouterPostconditionsHold() public {
    OnchainBookRouter router = new OnchainBookRouter(book, IRouterCash(params.cash));
    script.assertRouter(router, book, params);
  }

  function testAUsedDeployerMustBeNamed() public {
    vm.expectRevert(
      bytes("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)")
    );
    script.checkDeployer(params, DEPLOYER, 7, address(0));
    script.checkDeployer(params, DEPLOYER, 7, DEPLOYER);
  }

  /// The bounds a mistyped env would cross. checkParams on an edited copy: tests run in parallel and share the
  /// process environment, so none of them changes it.
  function testTheBoundsHold() public {
    DeployOnchainBookCngn.Params memory p = params;
    p.tickSize = 1e15;
    vm.expectRevert(bytes("TICK_SIZE: 1 to 1e12 (0.000001 USDC per cNGN)"));
    script.checkParams(p);
    p = params;
    p.takerFeeRate = 0.02e18;
    vm.expectRevert(bytes("TAKER_FEE_RATE over 1%: give it 18dp (15 bps is 1.5e15)"));
    script.checkParams(p);
    p = params;
    p.makerOwner = address(0);
    vm.expectRevert(bytes("set MAKER_OWNER: the address owning the maker's account"));
    script.checkParams(p);
    p = params;
    p.indexFeed = address(0xfeed);
    vm.expectRevert(bytes("the future's index is not the artifact's"));
    script.checkParams(p);
    script.checkParams(params);
  }

  /// The vault's two batches, then a take: the book opens, and fills, only after enable.
  function testSetupThenEnableThenATakeFills() public {
    // setup: accept, allow the maker (the script's vaultActionsJson)
    _vault(abi.encodeWithSignature("acceptOwnership()"));
    _vault(abi.encodeWithSignature("setMakerAllowed(address,bool)", MAKER, true));
    assertEq(book.owner(), params.vault);

    SubAccounts sa = SubAccounts(params.subAccounts);
    uint makerAcc = _account(sa, MAKER, 5_000e6);
    uint takerAcc = _account(sa, address(0xb0b), 5_000e6);
    (uint index,) = FutureAssetLike(params.future).indexFeed().getSpot();

    OnchainBook.Region[] memory r = new OnchainBook.Region[](1);
    r[0] = OnchainBook.Region(1000, 0);
    vm.startPrank(MAKER);
    book.setCurve(1, r);
    book.registerMaker(1, makerAcc);
    OnchainBook.SplineUpdate[] memory u = new OnchainBook.SplineUpdate[](1);
    u[0] = OnchainBook.SplineUpdate(1, makerAcc, int32(int(index / params.tickSize)), 20, 1, 1, 0, 0, 0, 60, 1, true);
    book.updateSplines(u);
    vm.stopPrank();

    OnchainBook.TakeOrder memory o = OnchainBook.TakeOrder({
      marketId: 1,
      takerAccountId: takerAcc,
      isBuy: true,
      amount: 100 * params.lotSize,
      limitPrice: index * 2,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 255,
      selfTradeMode: OnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
    vm.prank(address(0xb0b));
    vm.expectRevert(OnchainBook.OB_MarketDisabled.selector);
    book.take(o, "");

    _vault(script.enableCalldata(params));
    vm.prank(address(0xb0b));
    (uint filled,) = book.take(o, "");
    assertEq(filled, 100 * params.lotSize);
    assertEq(sa.getBalance(takerAcc, IAsset(params.future), params.subId), int(100 * params.lotSize));
  }

  function _account(SubAccounts sa, address owner, uint usdc) internal returns (uint acc) {
    acc = sa.createAccount(owner, IManager(params.engine));
    deal(USDC, owner, usdc);
    vm.startPrank(owner);
    IERC20Metadata(USDC).approve(params.cash, usdc);
    CashAsset(params.cash).deposit(acc, usdc);
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](2);
    a[0] = IAllowances.AssetAllowance(IAsset(params.future), type(uint).max, type(uint).max);
    a[1] = IAllowances.AssetAllowance(IAsset(params.cash), type(uint).max, type(uint).max);
    sa.setAssetAllowances(acc, address(book), a);
    vm.stopPrank();
  }
}

interface SpotLike {
  function getSpot() external view returns (uint, uint);
}

interface FutureAssetLike {
  function indexFeed() external view returns (SpotLike);
}
