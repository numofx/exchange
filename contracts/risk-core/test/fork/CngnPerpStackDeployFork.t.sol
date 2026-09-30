// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployCngnPerpStack} from "../../scripts/deploy-cngn-perp-stack.s.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {BaseLyraFeed} from "../../src/feeds/BaseLyraFeed.sol";
import {StandardManager} from "../../src/risk-managers/StandardManager.sol";

interface IOwnableLike {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

/**
 * Runs deploy-cngn-perp-stack.s.sol's own `deployStack` on a Base fork, then plays the vault's
 * side: executes the generated CNGN_PERP_STACK_VAULT_ACTIONS batch as the vault and checks the
 * stack is governed, tradeable and capped the way the script claims. CngnPerpStackFork.t.sol is
 * the phase-0 insolvency evidence; this one is about the script itself.
 *
 * Requires BASE_RPC_URL.
 */
contract CngnPerpStackDeployFork is Test {
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant LEGACY_SRM = 0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b;
  address constant LEGACY_CASH = 0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6;
  address constant GUARDIAN = address(0x6a2d);

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint signerPk = uint(keccak256("cngn-perp-stack-deploy-fork-signer"));
  address signer = vm.addr(signerPk);

  address alice = address(0xa11ce);
  address bob = address(0xb0b);

  DeployCngnPerpStack script;
  DeployCngnPerpStack.Params params;
  DeployCngnPerpStack.Stack stack;
  SubAccounts subAccounts = SubAccounts(SUB_ACCOUNTS);

  uint legacyMarketsBefore;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    legacyMarketsBefore = StandardManager(LEGACY_SRM).lastMarketId();

    script = new DeployCngnPerpStack();
    params = DeployCngnPerpStack.Params({
      subAccounts: SUB_ACCOUNTS,
      usdc: USDC,
      vault: VAULT,
      feedSigner: signer,
      perpOICap: 50_000_000e18,
      guardian: GUARDIAN
    });
    stack = script.deployStack(params);
  }

  function testScriptPostconditionsHold() public view {
    script.assertStack(stack, params, address(script));
  }

  function testVaultBatchHandsOverEveryContract() public {
    address[] memory owned = script.ownedContracts(stack);
    for (uint i = 0; i < owned.length; i++) {
      assertEq(IOwnableLike(owned[i]).owner(), address(script), "deployer owns until accepted");
    }

    _executeVaultBatch();

    for (uint i = 0; i < owned.length; i++) {
      assertEq(IOwnableLike(owned[i]).owner(), VAULT, "vault must own every contract");
      assertEq(IOwnableLike(owned[i]).pendingOwner(), address(0), "no nomination left pending");
    }

    // And the deployer can no longer change anything.
    vm.prank(address(script));
    vm.expectRevert();
    stack.perp.setTotalPositionCap(stack.srm, type(uint).max);
  }

  /// The guardian is the batch's last action, signed by the vault: before it the SRM has none.
  function testVaultBatchGrantsTheGuardianLast() public {
    assertEq(stack.srm.guardian(), address(0), "no guardian before the batch");
    _executeVaultBatch();
    assertEq(stack.srm.guardian(), GUARDIAN, "the batch sets the hot ops key as guardian");

    string memory json = script.vaultActionsJson(stack, GUARDIAN);
    string memory last = string.concat("[", vm.toString(script.vaultActionCount(stack) - 1), "]");
    assertEq(vm.parseJsonAddress(json, string.concat(last, ".to")), address(stack.srm), "last action targets the srm");
  }

  function testLegacyStackIsUntouched() public view {
    assertEq(StandardManager(LEGACY_SRM).lastMarketId(), legacyMarketsBefore, "legacy srm gained a market");
    assertEq(address(StandardManager(LEGACY_SRM).cashAsset()), LEGACY_CASH, "legacy srm cash moved");
    assertFalse(stack.perp.whitelistedManager(LEGACY_SRM), "perp must not accept the legacy srm");
    assertFalse(stack.cash.whitelistedManager(LEGACY_SRM), "new cash must not accept the legacy srm");
  }

  function testPublishedFeedsLetThePerpTrade() public {
    _executeVaultBatch();
    _enableCap();
    uint aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), stack.srm);
    uint bobAcc = subAccounts.createAccountWithApproval(bob, address(this), stack.srm);
    _deposit(alice, aliceAcc, 5_000e6);
    _deposit(bob, bobAcc, 5_000e6);

    _publish(0.00072e18);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);

    assertEq(subAccounts.getBalance(aliceAcc, stack.perp, 0), 10_000_000e18, "alice should be long");
  }

  /// Feeds cannot ride on a raw transfer's managerData: SubAccounts runs the perp's own
  /// adjustment (which reads mark and index) before the manager processes managerData, so an
  /// unpublished feed reverts first. Publishers push directly; the TradeModule path forwards its
  /// managerData before the transfers (execution-side fork test).
  function testFeedsMustBePublishedBeforeTheTrade() public {
    _executeVaultBatch();
    _enableCap();
    uint aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), stack.srm);
    uint bobAcc = subAccounts.createAccountWithApproval(bob, address(this), stack.srm);
    _deposit(alice, aliceAcc, 5_000e6);
    _deposit(bob, bobAcc, 5_000e6);

    bytes memory managerData = _feedUpdates(0.00072e18);
    vm.expectRevert(IBaseLyraFeed.BLF_DataTooOld.selector);
    _tradePerpWithData(bobAcc, aliceAcc, 10_000_000e18, managerData);
  }

  /// Deployed closed: with live feeds and funded accounts, even a raw SubAccounts transfer -- which
  /// never touches Matching -- cannot open a position until the enable action raises the cap.
  function testStackDeploysClosedToEveryPathNotJustMatching() public {
    _executeVaultBatch();
    uint aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), stack.srm);
    uint bobAcc = subAccounts.createAccountWithApproval(bob, address(this), stack.srm);
    _deposit(alice, aliceAcc, 5_000e6);
    _deposit(bob, bobAcc, 5_000e6);
    _publish(0.00072e18);

    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _tradePerp(bobAcc, aliceAcc, 1e18);
  }

  /// The cap counts |position| on BOTH sides: 50M allows 25M cNGN of open interest.
  function testLowOICapStopsOversizedPositions() public {
    _executeVaultBatch();
    _enableCap();
    uint aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), stack.srm);
    uint bobAcc = subAccounts.createAccountWithApproval(bob, address(this), stack.srm);
    _deposit(alice, aliceAcc, 100_000e6);
    _deposit(bob, bobAcc, 100_000e6);
    _publish(0.00072e18);

    _tradePerp(bobAcc, aliceAcc, 25_000_000e18); // 50M of total position: exactly at the cap

    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _tradePerp(bobAcc, aliceAcc, 1e18);
  }

  /// What perp-feeds' relayer pays per publish, through the live DataSubmitter, cold as a real
  /// transaction: the index alone (every 5 minutes) and index plus mark and impacts (a mark tick).
  /// Logged for the go-live funding sheet; bounded so a regression shows.
  function testFeedPublishGas() public {
    _executeVaultBatch();
    bytes memory all = _feedUpdates(0.00072e18);
    IBaseManager.ManagerData[] memory updates = abi.decode(all, (IBaseManager.ManagerData[]));
    IBaseManager.ManagerData[] memory indexOnly = new IBaseManager.ManagerData[](1);
    indexOnly[0] = updates[0];
    IBaseManager.ManagerData[] memory diffsOnly = new IBaseManager.ManagerData[](3);
    (diffsOnly[0], diffsOnly[1], diffsOnly[2]) = (updates[1], updates[2], updates[3]);

    uint indexGas = _coldSubmit(abi.encode(indexOnly));
    uint diffsGas = _coldSubmit(abi.encode(diffsOnly));
    console2.log("feed publish gas: index", indexGas, "mark + impacts", diffsGas);
    assertLt(indexGas, 150_000, "index publish");
    assertLt(diffsGas, 300_000, "mark + impacts publish");
  }

  function _coldSubmit(bytes memory managerData) internal returns (uint used) {
    address submitter = 0xe0C06DD245f1e8C8bC516c66C66e64648987F912;
    vm.cool(submitter);
    vm.cool(address(stack.indexFeed));
    vm.cool(address(stack.markFeed));
    vm.cool(address(stack.impactAskFeed));
    vm.cool(address(stack.impactBidFeed));
    uint before = gasleft();
    (bool ok,) = submitter.call(abi.encodeWithSignature("submitData(bytes)", managerData));
    used = before - gasleft();
    assertTrue(ok, "submitData");
  }

  // --- helpers ---------------------------------------------------------------------

  /// The cap half of the final enable action, as propose_perp_enable_batch.py emits it.
  function _enableCap() internal {
    vm.prank(VAULT);
    stack.perp.setTotalPositionCap(stack.srm, params.perpOICap);
  }

  function _executeVaultBatch() internal {
    string memory json = script.vaultActionsJson(stack, GUARDIAN);
    for (uint i = 0; i < script.vaultActionCount(stack); i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      bytes32 digest = vm.parseJsonBytes32(json, string.concat(key, ".digest"));
      assertEq(digest, keccak256(abi.encodePacked(to, keccak256(data))), "digest must match its own action");
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, "vault action failed");
    }
  }

  function _deposit(address user, uint acc, uint usdcAmount) internal {
    deal(USDC, user, usdcAmount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(address(stack.cash), usdcAmount);
    stack.cash.deposit(acc, usdcAmount);
    vm.stopPrank();
  }

  function _tradePerp(uint fromAcc, uint toAcc, int amount) internal {
    _tradePerpWithData(fromAcc, toAcc, amount, "");
  }

  function _tradePerpWithData(uint fromAcc, uint toAcc, int amount, bytes memory managerData) internal {
    ISubAccounts.AssetTransfer[] memory transfers = new ISubAccounts.AssetTransfer[](1);
    transfers[0] = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc, toAcc: toAcc, asset: stack.perp, subId: 0, amount: amount, assetData: bytes32(0)
    });
    subAccounts.submitTransfers(transfers, managerData);
  }

  /// Pushes index, mark and impacts directly, as the publishers do.
  function _publish(uint96 index) internal {
    IBaseManager.ManagerData[] memory updates = abi.decode(_feedUpdates(index), (IBaseManager.ManagerData[]));
    for (uint i = 0; i < updates.length; i++) {
      BaseLyraFeed(updates[i].receiver).acceptData(updates[i].data);
    }
  }

  function _feedUpdates(uint96 index) internal returns (bytes memory) {
    vm.warp(block.timestamp + 1);
    IBaseManager.ManagerData[] memory updates = new IBaseManager.ManagerData[](4);
    updates[0] =
      IBaseManager.ManagerData(address(stack.indexFeed), _signed(stack.indexFeed, abi.encode(index, uint64(1e18))));
    updates[1] =
      IBaseManager.ManagerData(address(stack.markFeed), _signed(stack.markFeed, abi.encode(int96(0), uint64(1e18))));
    updates[2] = IBaseManager.ManagerData(
      address(stack.impactAskFeed), _signed(stack.impactAskFeed, abi.encode(int96(0), uint64(1e18)))
    );
    updates[3] = IBaseManager.ManagerData(
      address(stack.impactBidFeed), _signed(stack.impactBidFeed, abi.encode(int96(0), uint64(1e18)))
    );
    return abi.encode(updates);
  }

  function _signed(BaseLyraFeed feed, bytes memory data) internal view returns (bytes memory) {
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
      vm.sign(signerPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = signer;
    return abi.encode(feedData);
  }
}
