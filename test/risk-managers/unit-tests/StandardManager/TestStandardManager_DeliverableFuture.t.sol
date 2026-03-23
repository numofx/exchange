// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./TestStandardManagerBase.t.sol";
import {IStandardManager} from "../../../../src/interfaces/IStandardManager.sol";
import {IDeliverableFXFutureAsset} from "../../../../src/interfaces/IDeliverableFXFutureAsset.sol";

contract UNIT_TestStandardManager_DeliverableFuture is TestStandardManagerBase {
  uint internal constant ONE_CONTRACT = 1e18;
  uint internal constant HALF_CONTRACT = 0.5e18;
  uint internal constant SETTLEMENT_PRICE = 1600e18;
  uint internal constant BASE_DELIVERY = 10_000e18;
  uint internal constant QUOTE_DELIVERY = 16_000_000e18;
  uint internal constant VM_DELTA = 1_000_000e18;

  function testVMUsesPreChangePositionOnTradeReduction() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), SETTLEMENT_PRICE);

    ISubAccounts.AssetTransfer memory reduceTransfer = ISubAccounts.AssetTransfer({
      fromAcc: bobAcc,
      toAcc: aliceAcc,
      asset: fxFuture,
      subId: fxSeries,
      amount: int(HALF_CONTRACT),
      assetData: ""
    });
    subAccounts.submitTransfer(reduceTransfer, "");

    assertEq(_getCashBalance(bobAcc), int(2_000_000e18 + VM_DELTA));
    assertEq(_getCashBalance(aliceAcc), int(2_000_000e18 - VM_DELTA));
    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), int(HALF_CONTRACT));
    assertEq(subAccounts.getBalance(aliceAcc, fxFuture, fxSeries), -int(HALF_CONTRACT));
  }

  function testReservationIsIdempotentAndClearsOnFullLiquidation() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    _depositWrapped(cngn, cngnAsset, bobAcc, QUOTE_DELIVERY);
    _depositWrapped(usdc, usdcDeliveryAsset, aliceAcc, BASE_DELIVERY);

    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    manager.refreshDeliverableReservation(fxFuture, bobAcc, fxSeries);
    manager.refreshDeliverableReservation(fxFuture, bobAcc, fxSeries);
    manager.refreshDeliverableReservation(fxFuture, aliceAcc, fxSeries);

    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), QUOTE_DELIVERY);
    assertEq(manager.reservedBalance(aliceAcc, IAsset(address(usdcDeliveryAsset))), BASE_DELIVERY);

    vm.prank(address(manager.liquidation()));
    manager.executeBid(bobAcc, charlieAcc, 1e18, 0, 0);

    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), 0);
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), 0);
    assertEq(subAccounts.getBalance(charlieAcc, fxFuture, fxSeries), int(ONE_CONTRACT));
    assertEq(manager.reservedBalance(charlieAcc, IAsset(address(cngnAsset))), QUOTE_DELIVERY);

    manager.refreshDeliverableReservation(fxFuture, charlieAcc, fxSeries);
    assertEq(manager.reservedBalance(charlieAcc, IAsset(address(cngnAsset))), QUOTE_DELIVERY);
  }

  function testLongMustHoldActualCNGNAfterLastTradeTime() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    _depositWrapped(usdc, usdcDeliveryAsset, aliceAcc, BASE_DELIVERY);
    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    vm.prank(bob);
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    cash.withdraw(bobAcc, 1e18, bob);
  }

  function testShortMustHoldActualUSDCAfterLastTradeTime() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    _depositWrapped(cngn, cngnAsset, bobAcc, QUOTE_DELIVERY);
    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    vm.prank(alice);
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    cash.withdraw(aliceAcc, 1e18, alice);
  }

  function testLiquidationRequiresInheritedDeliveryObligationToBeFunded() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    vm.prank(address(manager.liquidation()));
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    manager.executeBid(bobAcc, charlieAcc, 1e18, 0, 0);
  }

  function testUserTradeIsBlockedAfterLastTradeTimeButManagerAdjustmentSucceeds() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);
    _fundCash(charlieAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));
    _depositWrapped(cngn, cngnAsset, bobAcc, QUOTE_DELIVERY);

    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    ISubAccounts.AssetTransfer memory blockedTransfer = ISubAccounts.AssetTransfer({
      fromAcc: bobAcc,
      toAcc: charlieAcc,
      asset: fxFuture,
      subId: fxSeries,
      amount: int(HALF_CONTRACT),
      assetData: ""
    });

    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_TradingClosed.selector);
    subAccounts.submitTransfer(blockedTransfer, "");

    vm.prank(address(manager.liquidation()));
    manager.executeBid(bobAcc, charlieAcc, 1e18, 0, 0);

    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), 0);
    assertEq(subAccounts.getBalance(charlieAcc, fxFuture, fxSeries), int(ONE_CONTRACT));
  }

  function testSettlementRequiresInventoryAndClearsState() public {
    _fundCash(aliceAcc, 2_000_000e18);
    _fundCash(bobAcc, 2_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    _depositWrapped(cngn, cngnAsset, bobAcc, QUOTE_DELIVERY);
    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxExpiry + 1);

    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    manager.settleDeliverableFuture(fxFuture, bobAcc, fxSeries);

    _depositWrapped(usdc, usdcDeliveryAsset, manager.accId(), BASE_DELIVERY);

    manager.settleDeliverableFuture(fxFuture, bobAcc, fxSeries);

    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), 0);
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), 0);
    assertTrue(manager.accountSettled(bobAcc, fxFuture, fxSeries));
    assertEq(subAccounts.getBalance(bobAcc, usdcDeliveryAsset, 0), int(BASE_DELIVERY));
    assertEq(subAccounts.getBalance(manager.accId(), cngnAsset, 0), int(QUOTE_DELIVERY));
  }

  function testNoCashFallbackAtSettlement() public {
    _fundCash(aliceAcc, 50_000_000e18);
    _fundCash(bobAcc, 50_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    _depositWrapped(usdc, usdcDeliveryAsset, manager.accId(), BASE_DELIVERY);
    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxExpiry + 1);

    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    manager.settleDeliverableFuture(fxFuture, bobAcc, fxSeries);
  }

  function testFullLifecycleSmokeFlow() public {
    _fundCash(aliceAcc, 50_000_000e18);
    _fundCash(bobAcc, 50_000_000e18);
    _fundCash(charlieAcc, 50_000_000e18);

    _openFuturePosition(aliceAcc, bobAcc, int(ONE_CONTRACT));

    ISubAccounts.AssetTransfer memory preFreezeTransfer = ISubAccounts.AssetTransfer({
      fromAcc: bobAcc,
      toAcc: charlieAcc,
      asset: fxFuture,
      subId: fxSeries,
      amount: int(HALF_CONTRACT),
      assetData: ""
    });
    subAccounts.submitTransfer(preFreezeTransfer, "");

    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), int(HALF_CONTRACT));
    assertEq(subAccounts.getBalance(charlieAcc, fxFuture, fxSeries), int(HALF_CONTRACT));

    _depositWrapped(cngn, cngnAsset, bobAcc, QUOTE_DELIVERY);
    _depositWrapped(usdc, usdcDeliveryAsset, aliceAcc, BASE_DELIVERY);

    fxFuture.setSettlementPrice(fxSeries, SETTLEMENT_PRICE);
    vm.warp(fxLastTradeTime + 1);

    ISubAccounts.AssetTransfer memory blockedTransfer = ISubAccounts.AssetTransfer({
      fromAcc: bobAcc,
      toAcc: charlieAcc,
      asset: fxFuture,
      subId: fxSeries,
      amount: int(0.1e18),
      assetData: ""
    });
    vm.expectRevert(IDeliverableFXFutureAsset.DFXF_TradingClosed.selector);
    subAccounts.submitTransfer(blockedTransfer, "");

    vm.prank(address(manager.liquidation()));
    manager.executeBid(charlieAcc, bobAcc, 1e18, 0, 0);

    assertEq(subAccounts.getBalance(charlieAcc, fxFuture, fxSeries), 0);
    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), int(ONE_CONTRACT));
    assertEq(manager.reservedBalance(charlieAcc, IAsset(address(cngnAsset))), 0);
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), QUOTE_DELIVERY);

    vm.warp(fxExpiry + 1);

    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    manager.settleDeliverableFuture(fxFuture, aliceAcc, fxSeries);

    _depositWrapped(cngn, cngnAsset, manager.accId(), QUOTE_DELIVERY);
    manager.settleDeliverableFuture(fxFuture, aliceAcc, fxSeries);

    assertEq(subAccounts.getBalance(aliceAcc, fxFuture, fxSeries), 0);
    assertEq(manager.reservedBalance(aliceAcc, IAsset(address(usdcDeliveryAsset))), 0);
    assertTrue(manager.accountSettled(aliceAcc, fxFuture, fxSeries));

    manager.settleDeliverableFuture(fxFuture, bobAcc, fxSeries);

    assertEq(subAccounts.getBalance(bobAcc, fxFuture, fxSeries), 0);
    assertEq(manager.reservedBalance(bobAcc, IAsset(address(cngnAsset))), 0);
    assertTrue(manager.accountSettled(bobAcc, fxFuture, fxSeries));
    assertEq(subAccounts.getBalance(aliceAcc, cngnAsset, 0), int(QUOTE_DELIVERY));
    assertEq(subAccounts.getBalance(bobAcc, usdcDeliveryAsset, 0), int(BASE_DELIVERY));
  }
}
