// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployMarginEngineV2} from "../../scripts/deploy-margin-engine-v2.s.sol";
import {MarginEngineV1} from "../../src/legacy/v1/MarginEngineV1.sol";
import {FutureAssetV1} from "../../src/legacy/v1/FutureAssetV1.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IPositionTracking} from "../../src/interfaces/IPositionTracking.sol";

/**
 * propose_margin_engine_v2_batch.py's v1-close-only on the live v1 engine: every cap v1 holds (each market's base escrow
 * and the future) set to that asset's open interest under v1, as the vault. Proves that afterwards:
 *   - nothing opens under v1: a future trade that adds open interest, a cNGN deposit and a spot buy all revert;
 *   - holders still get out: they close the future between themselves, settle VM, withdraw USDC and cNGN, and sell cNGN
 *     straight to a v2 account (the migration's one book);
 *   - a cap that lands under open interest (open interest rose between the script's read and the vault's approval) is
 *     the same close-only, not a freeze: the deployed viewer skips assets a transfer did not touch.
 *
 * Pinned: it describes v1 before the close-only batch (two fresh accounts open a position in setUp, which v1 refuses
 * once the batch has landed). The v2 engine is deployed with the script's own `deploy` and wired by its setup batch.
 *
 * Requires BASE_RPC_URL.
 */
contract MarginEngineV1CloseOnlyFork is Test {
  uint constant FORK_BLOCK = 52_935_510;

  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

  bytes4 constant CAP_EXCEEDED = bytes4(keccak256("BM_AssetCapExceeded()"));

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address carol = address(0xca401);

  SubAccounts subAccounts;
  MarginEngineV1 v1;
  FutureAssetV1 future;
  uint96 subId;
  WrappedERC20Asset cngnEscrow;
  CashAsset cash;

  DeployMarginEngineV2 script;
  DeployMarginEngineV2.Params params;
  DeployMarginEngineV2.Deployment d;

  uint aliceAcc;
  uint bobAcc;
  uint mark;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);

    string memory v1Artifact = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/MARGIN_ENGINE.json"));
    v1 = MarginEngineV1(vm.parseJsonAddress(v1Artifact, ".manager"));
    future = FutureAssetV1(vm.parseJsonAddress(v1Artifact, ".future"));
    subId = uint96(vm.parseJsonUint(v1Artifact, ".subId"));
    cngnEscrow = WrappedERC20Asset(vm.parseJsonAddress(v1Artifact, ".cngnEscrow"));
    cash = CashAsset(vm.parseJsonAddress(v1Artifact, ".cash"));
    subAccounts = SubAccounts(address(v1.subAccounts()));

    // v2, deployed and wired as the script does, so holders have somewhere to go
    script = new DeployMarginEngineV2();
    params = script.loadChainParams();
    (ISpotFeed index,,) = v1.getMarketFeeds(1);
    (uint spot,) = index.getSpot();
    params.carry = 0.2e18;
    params.initialMark = spot * 1e18 / (1e18 + params.carry * (uint(params.expiry) - block.timestamp) / 365 days);
    params.forwardSigner = address(0xf0f);
    d = script.deploy(params);
    _execute(script.vaultActionsJson(d, params), script.vaultActionCount(d, params));

    // a position under v1 before the batch: bob short two contracts to alice, off the mark so it carries VM
    aliceAcc = _v1Account(alice);
    bobAcc = _v1Account(bob);
    mark = future.futureContracts(subId).markPrice;
    _trade(bobAcc, aliceAcc, 2e18, mark * 101 / 100);

    _closeOnly();
  }

  /// @dev What v1-close-only proposes: every cap v1 holds set to that asset's open interest under v1, as the vault.
  function _closeOnly() internal {
    _closeOnlyLess(0);
  }

  function _closeOnlyLess(uint under) internal {
    for (uint id = 1; id <= v1.lastMarketId(); ++id) {
      IPositionTracking escrow = IPositionTracking(address(v1.assetMap(id, IMarginEngine.AssetType.Base)));
      _setCap(escrow, escrow.totalPosition(IManager(address(v1))) - under);
    }
    _setCap(IPositionTracking(address(future)), future.totalPosition(IManager(address(v1))) - under);
  }

  function _setCap(IPositionTracking asset, uint cap) internal {
    vm.prank(VAULT);
    (bool ok,) = address(asset).call(abi.encodeWithSignature("setTotalPositionCap(address,uint256)", address(v1), cap));
    assertTrue(ok, "the vault sets v1's cap");
  }

  ///////////////////
  //  close-only   //
  ///////////////////

  function testEveryV1CapSitsAtOpenInterest() public view {
    for (uint id = 1; id <= v1.lastMarketId(); ++id) {
      IPositionTracking escrow = IPositionTracking(address(v1.assetMap(id, IMarginEngine.AssetType.Base)));
      assertEq(escrow.totalPositionCap(IManager(address(v1))), escrow.totalPosition(IManager(address(v1))));
    }
    assertEq(future.totalPositionCap(IManager(address(v1))), future.totalPosition(IManager(address(v1))));
    assertGt(future.totalPosition(IManager(address(v1))), 0, "live holders, and ours");
  }

  function testAFutureTradeThatOpensIsRefused() public {
    uint carolAcc = _v1CashAccount(carol);
    vm.expectRevert(CAP_EXCEEDED);
    _trade(carolAcc, aliceAcc, 1e18, mark);
  }

  function testANewV1AccountCannotDepositCngn() public {
    uint carolAcc = subAccounts.createAccountWithApproval(carol, address(this), IManager(address(v1)));
    _depositUsdc(carol, carolAcc, 1_000e6);
    deal(CNGN, carol, 1e6);
    vm.startPrank(carol);
    IERC20Metadata(CNGN).approve(address(cngnEscrow), 1e6);
    vm.expectRevert(CAP_EXCEEDED);
    cngnEscrow.deposit(carolAcc, 1e6);
    vm.stopPrank();
  }

  function testHoldersCloseTheFutureBetweenThemselves() public {
    uint before = future.totalPosition(IManager(address(v1)));
    _trade(aliceAcc, bobAcc, 2e18, mark);
    assertEq(subAccounts.getBalance(aliceAcc, future, subId), 0, "alice is flat");
    assertEq(future.totalPosition(IManager(address(v1))), before - 4e18, "open interest falls by both sides");
  }

  function testVMSettlesUnderCloseOnly() public {
    _markUp(100);
    int pending = future.getPendingVM(bobAcc, subId);
    assertTrue(pending != 0, "a new mark leaves VM pending");
    v1.settleAccount(bobAcc);
    v1.settleAccount(aliceAcc);
    assertEq(future.getPendingVM(bobAcc, subId), 0, "bob's VM realised");
    assertEq(future.getPendingVM(aliceAcc, subId), 0, "alice's VM realised");
  }

  function testHoldersWithdrawButCannotDeposit() public {
    vm.startPrank(alice);
    cngnEscrow.withdraw(aliceAcc, 100_000e6, alice);
    cash.withdraw(aliceAcc, 100e6, alice);
    vm.stopPrank();

    // back to the cap exactly passes; a cNGN-unit past it does not
    deal(CNGN, alice, 100_001e6);
    vm.startPrank(alice);
    IERC20Metadata(CNGN).approve(address(cngnEscrow), 100_001e6);
    cngnEscrow.deposit(aliceAcc, 100_000e6);
    vm.expectRevert(CAP_EXCEEDED);
    cngnEscrow.deposit(aliceAcc, 1e6);
    vm.stopPrank();
  }

  function testAV1HolderSellsCngnToV2ButCannotBuyIt() public {
    uint v2Acc = subAccounts.createAccountWithApproval(carol, address(this), IManager(address(d.engine)));
    _depositUsdc(carol, v2Acc, 1_000e6);
    _depositCngn(carol, v2Acc, 1_000_000e6);

    _spot(aliceAcc, v2Acc, 100_000e18, 70e18);
    assertEq(subAccounts.getBalance(v2Acc, cngnEscrow, 0), 1_100_000e18, "the cNGN moved to v2");

    // buying back what was sold returns v1 to its cap; one cNGN more is refused
    _spot(v2Acc, aliceAcc, 100_000e18, 70e18);
    vm.expectRevert(CAP_EXCEEDED);
    _spot(v2Acc, aliceAcc, 1e18, 1e15);
  }

  /// @dev Open interest rose between the script's read and the vault's approval: the cap lands under it. The deployed
  ///      viewer checks only the assets a transfer touched, so this is close-only as before; under BasePortfolioViewer's
  ///      check (the SRM's) the same cap froze every holder.
  function testACapUnderOpenInterestIsCloseOnlyNotAFreeze() public {
    _closeOnlyLess(1e18);

    vm.startPrank(alice);
    cngnEscrow.withdraw(aliceAcc, 100_000e6, alice);
    cash.withdraw(aliceAcc, 100e6, alice);
    vm.stopPrank();
    v1.settleAccount(bobAcc);
    _trade(aliceAcc, bobAcc, 1e18, mark);

    uint carolAcc = _v1CashAccount(carol);
    vm.expectRevert(CAP_EXCEEDED);
    _trade(carolAcc, aliceAcc, 1e18, mark);
  }

  /// @dev The test above rests on the deployed viewer skipping assets a transfer did not touch. BasePortfolioViewer (the
  ///      SRM's) reads an untouched asset's missing snapshot as a pre-trade position of 0; mocked here to read so, the
  ///      same cap freezes a holder's USDC withdrawal.
  function testUnderTheSrmsCapCheckTheSameCapFreezesHolders() public {
    _closeOnlyLess(1e18);
    bytes memory snapshot = abi.encodeWithSelector(IPositionTracking.totalPositionBeforeTrade.selector);
    vm.mockCall(address(cngnEscrow), snapshot, abi.encode(true, uint(0)));
    vm.mockCall(address(future), snapshot, abi.encode(true, uint(0)));

    vm.prank(alice);
    vm.expectRevert(CAP_EXCEEDED);
    cash.withdraw(aliceAcc, 100e6, alice);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  function _execute(string memory json, uint count) internal {
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      vm.prank(VAULT);
      (bool ok,) =
        vm.parseJsonAddress(json, string.concat(key, ".to")).call(vm.parseJsonBytes(json, string.concat(key, ".data")));
      assertTrue(ok, string.concat("v2 vault action ", vm.toString(i), " failed"));
    }
  }

  function _v1Account(address user) internal returns (uint acc) {
    acc = subAccounts.createAccountWithApproval(user, address(this), IManager(address(v1)));
    _depositUsdc(user, acc, 2_000e6);
    _depositCngn(user, acc, 1_000_000e6);
  }

  /// @dev a v1 account margined in USDC alone: a cNGN deposit adds to v1's escrow open interest, refused once close-only
  function _v1CashAccount(address user) internal returns (uint acc) {
    acc = subAccounts.createAccountWithApproval(user, address(this), IManager(address(v1)));
    _depositUsdc(user, acc, 2_000e6);
  }

  /// @dev the owner's mark `bps` above the last, an hour on, with the index held where it is (it goes stale past its
  ///      heartbeat): the vault owns the future, so no forward signature is needed
  function _markUp(uint bps) internal {
    (ISpotFeed index,,) = v1.getMarketFeeds(1);
    (uint spot,) = index.getSpot();
    vm.warp(block.timestamp + 1 hours);
    vm.mockCall(address(index), abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(spot, 1e18));
    uint next = future.futureContracts(subId).markPrice * (10_000 + bps) / 10_000;
    vm.prank(VAULT);
    future.setMark(subId, uint64(block.timestamp), next);
  }

  function _depositUsdc(address user, uint acc, uint amount) internal {
    deal(USDC, user, amount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(address(cash), amount);
    cash.deposit(acc, amount);
    vm.stopPrank();
  }

  function _depositCngn(address user, uint acc, uint amount) internal {
    deal(CNGN, user, amount);
    vm.startPrank(user);
    IERC20Metadata(CNGN).approve(address(cngnEscrow), amount);
    cngnEscrow.deposit(acc, amount);
    vm.stopPrank();
  }

  function _trade(uint seller, uint buyer, int amount, uint price) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: seller,
        toAcc: buyer,
        asset: IAsset(address(future)),
        subId: subId,
        amount: amount,
        assetData: bytes32(price)
      }),
      ""
    );
  }

  /// @dev `cngnAmount` cNGN from seller to buyer for `usdcAmount` USDC the other way, one transfer
  function _spot(uint seller, uint buyer, uint cngnAmount, uint usdcAmount) internal {
    ISubAccounts.AssetTransfer[] memory legs = new ISubAccounts.AssetTransfer[](2);
    legs[0] = ISubAccounts.AssetTransfer({
      fromAcc: seller, toAcc: buyer, asset: cngnEscrow, subId: 0, amount: int(cngnAmount), assetData: bytes32(0)
    });
    legs[1] = ISubAccounts.AssetTransfer({
      fromAcc: buyer, toAcc: seller, asset: cash, subId: 0, amount: int(usdcAmount), assetData: bytes32(0)
    });
    subAccounts.submitTransfers(legs, "");
  }
}
