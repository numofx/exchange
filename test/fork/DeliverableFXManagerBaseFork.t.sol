// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/SubAccounts.sol";
import "../../src/assets/CashAsset.sol";
import "../../src/assets/WrappedERC20Asset.sol";
import "../../src/assets/WLWrappedERC20Asset.sol";
import "../../src/assets/DeliverableFXFutureAsset.sol";
import "../../src/interfaces/IAsset.sol";
import "../../src/interfaces/ISpotFeed.sol";
import "../../src/interfaces/IStandardManager.sol";
import "../../src/risk-managers/DeliverableFXManager.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

contract FORK_TestDeliverableFXManagerBase is Test {
  uint internal constant ONE_INCREMENT = 0.001e18;
  uint internal constant TWO_INCREMENTS = 0.002e18;
  uint internal constant SETTLEMENT_PRICE = 1600e18;
  uint internal constant BASE_PER_INCREMENT_18 = 10e18;
  uint internal constant QUOTE_PER_INCREMENT_18 = 16_000e18;
  uint internal constant CASH_MARGIN_USDC = 1_000 * 1e6;
  uint internal constant MANAGER_CNGN_FUND = 64_000e18;

  address internal deployer;

  SubAccounts internal subAccounts;
  CashAsset internal cash;
  WrappedERC20Asset internal usdcDeliveryAsset;
  WrappedERC20Asset internal cngnAsset;
  DeliverableFXFutureAsset internal future;
  DeliverableFXManager internal manager;
  ISpotFeed internal quoteSpotFeed;

  IERC20Metadata internal usdc;
  IERC20Metadata internal cngn;

  uint internal managerAccId;
  uint96 internal liveSeries;
  uint internal liveExpiry;
  uint internal liveLastTradeTime;

  uint internal aliceAcc;
  uint internal bobAcc;
  uint internal charlieAcc;
  address internal alice = address(0xaa01);
  address internal bob = address(0xbb01);
  address internal charlie = address(0xcc01);

  function setUp() public virtual {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));

    string memory root = vm.projectRoot();
    string memory coreJson = vm.readFile(string.concat(root, "/deployments/8453/core.json"));
    string memory sharedJson = vm.readFile(string.concat(root, "/deployments/8453/shared.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json"));
    string memory futureJson = vm.readFile(string.concat(root, "/deployments/8453/CNGN_APR30_2026_FUTURE.json"));

    deployer = vm.envAddress("DEPLOYER_ADDRESS");

    subAccounts = SubAccounts(vm.parseJsonAddress(coreJson, ".subAccounts"));
    cash = CashAsset(vm.parseJsonAddress(coreJson, ".cash"));
    usdc = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".usdc"));
    cngn = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".cngn"));
    usdcDeliveryAsset = WrappedERC20Asset(vm.parseJsonAddress(futureJson, ".baseAsset"));
    cngnAsset = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    future = DeliverableFXFutureAsset(vm.parseJsonAddress(futureJson, ".future"));
    manager = DeliverableFXManager(vm.parseJsonAddress(futureJson, ".manager"));
    quoteSpotFeed = manager.quoteSpotFeed();

    managerAccId = manager.accId();
    liveSeries = uint96(vm.parseJsonUint(futureJson, ".expiry"));
    liveExpiry = vm.parseJsonUint(futureJson, ".expiry");
    liveLastTradeTime = vm.parseJsonUint(futureJson, ".lastTradeTime");

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);
    charlieAcc = subAccounts.createAccountWithApproval(charlie, address(this), manager);

    vm.startPrank(deployer);
    WLWrappedERC20Asset(address(cngnAsset)).setSubAccountWL(bobAcc, true);
    WLWrappedERC20Asset(address(cngnAsset)).setSubAccountWL(charlieAcc, true);
    WLWrappedERC20Asset(address(cngnAsset)).setSubAccountWL(managerAccId, true);
    vm.stopPrank();

    vm.deal(address(this), 10 ether);
    vm.deal(alice, 10 ether);
    vm.deal(bob, 10 ether);
    vm.deal(charlie, 10 ether);

    deal(address(usdc), address(this), 1_000_000 * 1e6);
    deal(address(cngn), address(this), 1_000_000_000e18);

    usdc.approve(address(cash), type(uint).max);
    usdc.approve(address(usdcDeliveryAsset), type(uint).max);
    cngn.approve(address(cngnAsset), type(uint).max);

    _mockFreshQuoteSpot(1500e18, 1e18);
  }

  function _fundCash(uint accountId, uint underlyingUsdc) internal {
    cash.deposit(accountId, underlyingUsdc);
  }

  function _depositWrappedUSDC(uint accountId, uint underlyingUsdc) internal {
    usdcDeliveryAsset.deposit(accountId, underlyingUsdc);
  }

  function _depositWrappedCNGN(uint accountId, uint amount18) internal {
    cngnAsset.deposit(accountId, amount18);
  }

  function _transferFuture(uint fromAcc, uint toAcc, uint96 subId, int amount) internal {
    ISubAccounts.AssetTransfer memory transfer = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc,
      toAcc: toAcc,
      asset: future,
      subId: subId,
      amount: amount,
      assetData: ""
    });
    subAccounts.submitTransfer(transfer, "");
  }

  function _mockFreshQuoteSpot(uint spotPrice, uint confidence) internal {
    vm.mockCall(address(quoteSpotFeed), abi.encodeCall(ISpotFeed.getSpot, ()), abi.encode(spotPrice, confidence));
  }
}

contract FORK_TestDeliverableFXManagerAcceptance is FORK_TestDeliverableFXManagerBase {
  function testFork_LifecycleAcceptanceAgainstLiveDeployment() public {
    _fundCash(aliceAcc, CASH_MARGIN_USDC);
    _fundCash(bobAcc, CASH_MARGIN_USDC);
    _fundCash(charlieAcc, CASH_MARGIN_USDC);

    vm.warp(liveLastTradeTime - 1);
    _transferFuture(aliceAcc, bobAcc, liveSeries, int(TWO_INCREMENTS));

    vm.prank(deployer);
    future.setMarkPrice(liveSeries, uint64(block.timestamp), SETTLEMENT_PRICE);

    _transferFuture(aliceAcc, bobAcc, liveSeries, -int(ONE_INCREMENT));

    assertEq(subAccounts.getBalance(bobAcc, future, liveSeries), int(ONE_INCREMENT));
    assertEq(subAccounts.getBalance(aliceAcc, future, liveSeries), -int(ONE_INCREMENT));
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), int(3_000e18));
    assertEq(subAccounts.getBalance(aliceAcc, cash, 0), -int(1_000e18));

    vm.prank(deployer);
    future.setSettlementPrice(liveSeries, SETTLEMENT_PRICE);

    vm.warp(liveLastTradeTime + 1);

    ISubAccounts.AssetTransfer memory blocked = ISubAccounts.AssetTransfer({
      fromAcc: aliceAcc,
      toAcc: bobAcc,
      asset: future,
      subId: liveSeries,
      amount: int(ONE_INCREMENT),
      assetData: ""
    });
    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_TradingClosed.selector);
    subAccounts.submitTransfer(blocked, "");

    _depositWrappedCNGN(charlieAcc, QUOTE_PER_INCREMENT_18);

    vm.prank(address(manager.liquidation()));
    manager.executeBid(bobAcc, charlieAcc, 1e18, 0, 0);

    assertEq(subAccounts.getBalance(bobAcc, future, liveSeries), 0);
    assertEq(subAccounts.getBalance(charlieAcc, future, liveSeries), int(ONE_INCREMENT));
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), 0);
    assertEq(manager.reservedBalance(charlieAcc, IAsset(address(cngnAsset))), QUOTE_PER_INCREMENT_18);

    _depositWrappedUSDC(aliceAcc, 10 * 1e6);

    vm.warp(liveExpiry + 1);

    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    manager.settleDeliverableFuture(future, charlieAcc, liveSeries);

    _depositWrappedCNGN(managerAccId, MANAGER_CNGN_FUND);

    manager.settleDeliverableFuture(future, aliceAcc, liveSeries);

    assertEq(subAccounts.getBalance(aliceAcc, future, liveSeries), 0);
    assertEq(manager.reservedBalance(aliceAcc, IAsset(address(usdcDeliveryAsset))), 0);
    assertTrue(manager.accountSettled(aliceAcc, liveSeries));
    assertEq(subAccounts.getBalance(aliceAcc, cngnAsset, 0), int(QUOTE_PER_INCREMENT_18));

    manager.settleDeliverableFuture(future, charlieAcc, liveSeries);

    assertEq(subAccounts.getBalance(charlieAcc, future, liveSeries), 0);
    assertEq(manager.reservedBalance(charlieAcc, IAsset(address(cngnAsset))), 0);
    assertTrue(manager.accountSettled(charlieAcc, liveSeries));
    assertEq(subAccounts.getBalance(charlieAcc, usdcDeliveryAsset, 0), int(BASE_PER_INCREMENT_18));

    vm.expectRevert(IStandardManager.SRM_UnsupportedAsset.selector);
    manager.settleDeliverableFuture(future, charlieAcc, liveSeries);
  }

  function testFork_SecondSeriesAggregatesReservationsAcrossSharedAssets() public {
    _fundCash(aliceAcc, CASH_MARGIN_USDC);
    _fundCash(bobAcc, CASH_MARGIN_USDC);

    uint64 secondExpiry = uint64(block.timestamp + 45 days);
    uint64 secondLastTrade = secondExpiry - 1 days;

    vm.prank(deployer);
    uint96 secondSeries = future.createSeries(
      secondExpiry,
      secondLastTrade,
      address(usdcDeliveryAsset),
      address(cngnAsset),
      10_000e18,
      0.001e18,
      1e18,
      1550e18
    );

    vm.warp(liveLastTradeTime - 1);
    _transferFuture(aliceAcc, bobAcc, liveSeries, int(ONE_INCREMENT));
    _transferFuture(aliceAcc, bobAcc, secondSeries, int(ONE_INCREMENT));

    vm.prank(deployer);
    future.setSettlementPrice(liveSeries, SETTLEMENT_PRICE);
    vm.prank(deployer);
    future.setSettlementPrice(secondSeries, 1550e18);

    _depositWrappedCNGN(bobAcc, QUOTE_PER_INCREMENT_18);

    vm.warp(secondLastTrade + 1);
    manager.refreshDeliverableReservation(future, bobAcc, liveSeries);

    uint expectedAggregate = QUOTE_PER_INCREMENT_18 + 15_500e18;
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), expectedAggregate);
    assertFalse(manager.canSettleDeliverableFuture(future, bobAcc, liveSeries));

    _depositWrappedCNGN(bobAcc, 15_500e18);
    manager.refreshDeliverableReservation(future, bobAcc, secondSeries);
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), expectedAggregate);
  }
}
