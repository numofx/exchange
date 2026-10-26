// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployMarginEngineV2} from "../../scripts/deploy-margin-engine-v2.s.sol";
import {MarginEngineV1} from "../../src/legacy/v1/MarginEngineV1.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {BaseLyraFeed} from "../../src/feeds/BaseLyraFeed.sol";

interface IOwnableLike {
  function owner() external view returns (address);
}

interface ITradeModuleLike {
  function isDatedFutureAsset(address) external view returns (bool);
}

/**
 * Runs deploy-margin-engine-v2.s.sol's own `deploy` on a Base fork at head, executes the generated batches as the vault,
 * and proves on the live stack that:
 *   - v2 margins every base market exactly as the live v1 engine does (parity), and lists no perp;
 *   - the cNGN-<expiry> future is in American terms end to end: the initial mark sits at the index's forward
 *     discount, marks pull the forward as is, VM moves as real USDC cash, and the fixing settles at the index as is;
 *   - a v1 account and a v2 account trade spot cNGN against USDC directly, so the migration needs no second book;
 *   - the live v1 engine is never touched.
 *
 * At head because it is about deploying into the world as it is now. The index is held at its live value with
 * mockCall from the first warp on (it goes stale past its heartbeat); that is the only thing mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract MarginEngineV2DeployFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

  uint constant CARRY = 0.2e18;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);

  uint forwardPk = uint(keccak256("cngn-future-v2-deploy-fork-forward-signer"));
  address forwardSigner = vm.addr(forwardPk);

  DeployMarginEngineV2 script;
  DeployMarginEngineV2.Params params;
  DeployMarginEngineV2.Deployment d;
  SubAccounts subAccounts;
  MarginEngineV1 v1;

  uint spot; // USDC per cNGN, live: the index, as v2 reads it
  uint v1MarketsBefore;
  uint v1EscrowCapBefore;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    script = new DeployMarginEngineV2();

    string memory v1Artifact = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/MARGIN_ENGINE.json"));
    v1 = MarginEngineV1(vm.parseJsonAddress(v1Artifact, ".manager"));
    (ISpotFeed index,,) = v1.getMarketFeeds(1);
    (spot,) = index.getSpot();

    // The operator's inputs, supplied here rather than through the environment: forge runs suites in parallel in one
    // process, and v1's deploy suites read INITIAL_MARK in cNGN per USDC. The initial mark is exactly the fair forward,
    // index / (1 + carry * tau).
    params = script.loadChainParams();
    uint tau = uint(params.expiry) - block.timestamp;
    params.carry = CARRY;
    params.initialMark = spot * 1e18 / (1e18 + CARRY * tau / 365 days);
    params.forwardSigner = forwardSigner;
    script.checkParams(params);

    subAccounts = SubAccounts(params.subAccounts);
    v1MarketsBefore = v1.lastMarketId();
    v1EscrowCapBefore = WrappedERC20Asset(params.escrows[0]).totalPositionCap(IManager(address(v1)));
    d = script.deploy(params);
  }

  ///////////////////
  //  the script   //
  ///////////////////

  function testScriptPostconditionsHold() public view {
    script.assertDeployment(d, params);
  }

  function testItCopiesEveryV1MarketAndNoPerp() public view {
    assertEq(d.engine.lastMarketId(), v1.lastMarketId(), "one v2 market per v1 market");
    for (uint id = 1; id <= d.engine.lastMarketId(); ++id) {
      assertEq(
        address(d.engine.assetMap(id, IMarginEngine.AssetType.Base)),
        address(v1.assetMap(id, IMarginEngine.AssetType.Base)),
        "the same escrow at the same id"
      );
      assertEq(address(d.engine.assetMap(id, IMarginEngine.AssetType.Perpetual)), address(0), "no perp on v2");
    }
  }

  function testTheContractIsAMillionCngn() public view {
    assertEq(d.future.contractSize(), 1_000_000e18);
  }

  /// @dev In American terms positive NGN carry puts the forward under the index. v1's direction (index x (1 + carry x
  ///      tau)) is ~2x the carry away, outside the 2% tolerance, and refused.
  function testTheForwardSitsAtADiscountToTheIndex() public {
    assertLt(script.fairForward(params), spot, "cNGN is cheaper forward");
    DeployMarginEngineV2.Params memory p = params;
    uint tau = uint(p.expiry) - block.timestamp;
    p.initialMark = spot + spot * CARRY / 1e18 * tau / 365 days;
    vm.expectRevert(bytes("INITIAL_MARK is outside the band around index / (1 + carry * tau)"));
    script.checkParams(p);
  }

  function testInitialMarkOutsideTheIndexBandIsRefused() public {
    DeployMarginEngineV2.Params memory p = params;
    p.initialMark = spot * 89 / 100;
    vm.expectRevert(bytes("INITIAL_MARK is outside the index band"));
    script.checkParams(p);
  }

  function testLaunchMarginIsIM25MM15() public view {
    (uint mm, uint im) = d.engine.futureMarginRequirements(1);
    assertEq(im, 0.25e18);
    assertEq(mm, 0.15e18);
  }

  function testVaultBatchHandsOverAndWires() public {
    _executeVaultBatch();
    address[] memory owned = script.ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      assertEq(IOwnableLike(owned[i]).owner(), VAULT, "the vault owns it");
    }
    assertTrue(CashAsset(params.cash).whitelistedManager(address(d.engine)), "cash");
    for (uint i = 0; i < params.escrows.length; ++i) {
      WrappedERC20Asset escrow = WrappedERC20Asset(params.escrows[i]);
      assertTrue(escrow.whitelistedManager(address(d.engine)), "escrow");
      assertEq(
        escrow.totalPositionCap(IManager(address(d.engine))),
        i + 1 == 2 ? 0 : params.escrowCaps[i],
        "v1's cap; EUR's 0 until eurc-cap (the venue's EURC is sized to depth)"
      );
    }
    assertEq(d.engine.guardian(), params.guardian, "v1's guardian");
  }

  function testDeploysClosedUntilTheEnableBatch() public {
    _executeVaultBatch();
    _holdIndex(spot);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark = d.future.futureContracts(d.subId).markPrice;
    vm.expectRevert();
    _trade(bobAcc, aliceAcc, 1e18, mark);

    _executeEnableBatch();
    _trade(bobAcc, aliceAcc, 1e18, mark);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 1e18);
    assertTrue(ITradeModuleLike(params.tradeModule).isDatedFutureAsset(address(d.future)), "on the TradeModule");
  }

  function testTheLiveV1IsUntouched() public {
    _executeVaultBatch();
    _executeEnableBatch();
    assertEq(v1.lastMarketId(), v1MarketsBefore, "no market added to v1");
    assertEq(
      WrappedERC20Asset(params.escrows[0]).totalPositionCap(IManager(address(v1))),
      v1EscrowCapBefore,
      "v1's escrow cap unchanged"
    );
  }

  ///////////////////
  //   lifecycle   //
  ///////////////////

  /// @dev Two contracts, a 2% rally in cNGN, the fixing at the index, and real USDC out: VM is USDC throughout, and
  ///      nothing moves as cNGN.
  function testPositionLivesAndSettlesInUsdcOnTheRealStack() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);

    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 2e18, mark0); // alice long 2,000,000 cNGN

    vm.warp(block.timestamp + 1 days);
    uint mark1 = mark0 * 102 / 100; // cNGN 2% stronger forward
    vm.prank(VAULT);
    d.future.setMark(d.subId, uint64(block.timestamp), mark1);

    int expectedVM = int(2 * 1_000_000 * (mark1 - mark0));
    assertEq(d.future.getPendingVM(aliceAcc, d.subId), expectedVM, "the mark move x 2 x 1,000,000 cNGN, in USDC");

    int aliceBefore = _settledCash(aliceAcc);
    int bobBefore = _settledCash(bobAcc);
    d.engine.settleAccount(bobAcc);
    d.engine.settleAccount(aliceAcc);
    assertEq(_cashBalance(aliceAcc) - aliceBefore, expectedVM, "alice paid in USDC");
    assertEq(_cashBalance(bobAcc) - bobBefore, -expectedVM, "bob paid in USDC");
    assertEq(_cngnBalance(aliceAcc), 500_000e18, "no cNGN moved");
    assertEq(_cngnBalance(bobAcc), 500_000e18, "no cNGN moved");

    // the fixing: sampled every 10 minutes over the last hour, flat at the live index
    uint64 expiry = params.expiry;
    for (uint t = expiry - 1 hours; t <= expiry; t += 10 minutes) {
      vm.warp(t);
      d.future.recordFixingSample(d.subId);
    }
    vm.warp(expiry);
    vm.prank(address(0xf1));
    d.future.fixSettlementFromIndex(d.subId);
    assertEq(d.future.futureContracts(d.subId).markPrice, spot, "settles at the index, as is");

    d.engine.closeOutExpired(bobAcc, d.subId);
    d.engine.closeOutExpired(aliceAcc, d.subId);
    assertEq(subAccounts.getBalance(aliceAcc, d.future, d.subId), 0);
    assertEq(d.future.totalPosition(d.engine), 0, "no open interest left");

    // real USDC out
    d.engine.settleInterest(aliceAcc);
    uint out = uint(_cashBalance(aliceAcc)) / 1e12;
    vm.prank(alice);
    CashAsset(params.cash).withdraw(aliceAcc, out, alice);
    assertEq(IERC20Metadata(USDC).balanceOf(alice), out);
  }

  /// @dev forward = index + diff, read as is: a diff 2% under the index is a mark 2% under it, no inversion.
  function testMarksArePulledFromTheSignedForwardAsIs() public {
    _executeVaultBatch();
    _executeEnableBatch();
    _holdIndex(spot);
    (uint aliceAcc, uint bobAcc) = _fundedAccounts();
    uint mark0 = d.future.futureContracts(d.subId).markPrice;
    _trade(bobAcc, aliceAcc, 1e18, mark0);

    vm.warp(block.timestamp + 1 hours);
    int96 diff = -int96(int(spot * 2 / 100));
    _publishForward(diff);
    vm.prank(address(0xbeef)); // anyone
    d.future.pullMark(d.subId);

    uint mark1 = uint(int(spot) + diff);
    assertEq(d.future.futureContracts(d.subId).markPrice, mark1, "index + diff");
    assertEq(
      d.future.getPendingVM(aliceAcc, d.subId), int(1_000_000) * (int(mark1) - int(mark0)), "VM from the pulled mark"
    );
  }

  ///////////////////
  //   migration   //
  ///////////////////

  /// @dev The question that decides whether spot needs a second book while holders migrate: a v1-managed account and a
  ///      v2-managed account trade cNGN for USDC directly, each side held to its own engine's risk check.
  function testAV1AccountAndAV2AccountTradeSpotCngnDirectly() public {
    _executeVaultBatch();
    _holdIndex(spot);

    uint seller = subAccounts.createAccountWithApproval(alice, address(this), IManager(address(v1)));
    uint buyer = _account(bob);
    _depositCngn(alice, seller, 1_000_000e6);
    _depositUsdc(bob, buyer, 1_000e6);

    uint cngnAmount = 100_000e18;
    int usdcAmount = int(cngnAmount * spot / 1e18);
    ISubAccounts.AssetTransfer[] memory legs = new ISubAccounts.AssetTransfer[](2);
    legs[0] = ISubAccounts.AssetTransfer({
      fromAcc: seller,
      toAcc: buyer,
      asset: WrappedERC20Asset(params.escrows[0]),
      subId: 0,
      amount: int(cngnAmount),
      assetData: bytes32(0)
    });
    legs[1] = ISubAccounts.AssetTransfer({
      fromAcc: buyer, toAcc: seller, asset: CashAsset(params.cash), subId: 0, amount: usdcAmount, assetData: bytes32(0)
    });
    subAccounts.submitTransfers(legs, "");

    assertEq(_cngnBalance(buyer), int(cngnAmount), "the v2 account holds the cNGN");
    assertEq(address(subAccounts.manager(seller)), address(v1), "the seller is still under v1");
    assertGt(_cashBalance(seller), 0, "and was paid in USDC");
  }

  ///////////////////
  //    helpers    //
  ///////////////////

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

  function _executeVaultBatch() internal {
    _execute(script.vaultActionsJson(d, params), script.vaultActionCount(d, params));
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

  function _holdIndex(uint price) internal {
    vm.mockCall(params.indexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(price, 1e18));
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
    IERC20Metadata(CNGN).approve(params.escrows[0], amount);
    WrappedERC20Asset(params.escrows[0]).deposit(acc, amount);
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

  /// @dev the account's cash with interest accrued to now, so a delta after it is the VM payment alone
  function _settledCash(uint acc) internal returns (int) {
    d.engine.settleInterest(acc);
    return _cashBalance(acc);
  }

  function _cashBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, CashAsset(params.cash), 0);
  }

  function _cngnBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, WrappedERC20Asset(params.escrows[0]), 0);
  }
}
