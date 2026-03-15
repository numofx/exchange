// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../shared/mocks/MockCash.sol";
import "../../shared/mocks/MockERC20.sol";
import "../../shared/mocks/MockFeeds.sol";
import "../../shared/mocks/MockSpotDiffFeed.sol";
import "../mocks/MockDutchAuction.sol";

import "../../../src/SubAccounts.sol";
import "../../../src/assets/PerpAsset.sol";
import "../../../src/assets/SquaredPerpAsset.sol";
import "../../../src/risk-managers/BasePortfolioViewer.sol";
import "../../../src/risk-managers/SquaredPerpManager.sol";
import {IPerpAsset} from "../../../src/interfaces/IPerpAsset.sol";
import {ISubAccounts} from "../../../src/interfaces/ISubAccounts.sol";

contract UNIT_SquaredPerpManager is Test {
  SubAccounts subAccounts;
  MockERC20 usdc;
  MockCash cash;
  BasePortfolioViewer viewer;
  MockDutchAuction auction;
  SquaredPerpManager manager;

  MockFeeds spotFeed;
  MockSpotDiffFeed linearPerpFeed;
  MockSpotDiffFeed squaredPerpFeed;
  MockSpotDiffFeed linearImpactAsk;
  MockSpotDiffFeed linearImpactBid;
  MockSpotDiffFeed squaredImpactAsk;
  MockSpotDiffFeed squaredImpactBid;

  PerpAsset linearPerp;
  SquaredPerpAsset squaredPerp;

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  uint aliceAcc;
  uint bobAcc;

  function setUp() public {
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LYRA");
    usdc = new MockERC20("USDC", "USDC");
    cash = new MockCash(usdc, subAccounts);
    viewer = new BasePortfolioViewer(subAccounts, cash);
    auction = new MockDutchAuction();

    manager = new SquaredPerpManager(subAccounts, cash, auction, viewer);

    spotFeed = new MockFeeds();
    spotFeed.setSpot(20e18, 1e18);

    linearPerpFeed = new MockSpotDiffFeed(spotFeed);
    squaredPerpFeed = new MockSpotDiffFeed(spotFeed);
    linearImpactAsk = new MockSpotDiffFeed(spotFeed);
    linearImpactBid = new MockSpotDiffFeed(spotFeed);
    squaredImpactAsk = new MockSpotDiffFeed(spotFeed);
    squaredImpactBid = new MockSpotDiffFeed(spotFeed);

    linearPerp = new PerpAsset(subAccounts);
    squaredPerp = new SquaredPerpAsset(subAccounts);

    _configurePerp(linearPerp, linearPerpFeed, linearImpactAsk, linearImpactBid);
    _configurePerp(squaredPerp, squaredPerpFeed, squaredImpactAsk, squaredImpactBid);

    linearPerp.setWhitelistManager(address(manager), true);
    squaredPerp.setWhitelistManager(address(manager), true);

    linearPerp.setTotalPositionCap(manager, type(uint).max);
    squaredPerp.setTotalPositionCap(manager, type(uint).max);

    manager.setPerpRiskParams(
      linearPerp,
      SquaredPerpManager.PerpRiskParams({
        isWhitelisted: true,
        isSquared: false,
        initialMarginRatio: 0.15e18,
        maintenanceMarginRatio: 0.10e18,
        initialMaxLeverage: 4e18,
        maintenanceMaxLeverage: 8e18,
        initialSpotShockUp: 0.20e18,
        initialSpotShockDown: 0.20e18,
        maintenanceSpotShockUp: 0.10e18,
        maintenanceSpotShockDown: 0.10e18
      })
    );

    manager.setPerpRiskParams(
      squaredPerp,
      SquaredPerpManager.PerpRiskParams({
        isWhitelisted: true,
        isSquared: true,
        initialMarginRatio: 0.20e18,
        maintenanceMarginRatio: 0.12e18,
        initialMaxLeverage: 5e18,
        maintenanceMaxLeverage: 5e18,
        initialSpotShockUp: 0.20e18,
        initialSpotShockDown: 0.20e18,
        maintenanceSpotShockUp: 0.10e18,
        maintenanceSpotShockDown: 0.10e18
      })
    );

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);

    usdc.mint(address(this), 1_000_000e18);
    usdc.approve(address(cash), type(uint).max);
  }

  function testSquaredRequirementIncreasesAsSpotRises() public {
    cash.deposit(aliceAcc, 10_000e18);
    cash.deposit(bobAcc, 10_000e18);
    _tradePerp(squaredPerp, aliceAcc, bobAcc, 1e18);

    (uint beforeReq,,) = manager.getIsolatedRisk(squaredPerp, bobAcc, true, 0);
    spotFeed.setSpot(30e18, 1e18);
    (uint afterReq,,) = manager.getIsolatedRisk(squaredPerp, bobAcc, true, 0);

    assertEq(beforeReq, 144e18);
    assertEq(afterReq, 324e18);
    assertGt(afterReq, beforeReq);
  }

  function testMaintenanceMarginCanFlipNegativeUnderAdverseSpotShock() public {
    cash.deposit(aliceAcc, 10_000e18);
    cash.deposit(bobAcc, 600e18);
    _tradePerp(squaredPerp, bobAcc, aliceAcc, 1e18);

    int marginBefore = manager.getMargin(bobAcc, false);
    assertEq(marginBefore, 516e18);

    spotFeed.setSpot(30e18, 1e18);

    int marginAfter = manager.getMargin(bobAcc, false);
    assertEq(marginAfter, -89e18);
    assertLt(marginAfter, 0);
  }

  function testLongSquaredPerpHasWorseDownsideShockThanLinearAtHighSpot() public {
    spotFeed.setSpot(40e18, 1e18);
    cash.deposit(aliceAcc, 20_000e18);
    cash.deposit(bobAcc, 20_000e18);
    _tradePerp(linearPerp, aliceAcc, bobAcc, 1e18);
    _tradePerp(squaredPerp, aliceAcc, bobAcc, 1e18);

    (, , uint linearShockLoss) = manager.getIsolatedRisk(linearPerp, bobAcc, true, 2);
    (, , uint squaredShockLoss) = manager.getIsolatedRisk(squaredPerp, bobAcc, true, 2);

    assertEq(linearShockLoss, 8e18);
    assertEq(squaredShockLoss, 576e18);
    assertGt(squaredShockLoss, linearShockLoss);
  }

  function testLinearAndSquaredBooksDoNotReceiveNettingRelief() public {
    cash.deposit(aliceAcc, 20_000e18);
    cash.deposit(bobAcc, 205e18);

    _tradePerp(squaredPerp, aliceAcc, bobAcc, 1e18);
    _tradePerp(linearPerp, bobAcc, aliceAcc, 1e18);

    (uint squaredReq,,) = manager.getIsolatedRisk(squaredPerp, bobAcc, true, 0);
    (uint linearReq,,) = manager.getIsolatedRisk(linearPerp, bobAcc, true, 0);
    int margin = manager.getMargin(bobAcc, true);

    assertEq(squaredReq, 144e18);
    assertEq(linearReq, 5e18);
    assertEq(margin, 56e18);
    assertEq(margin, 205e18 - int(squaredReq + linearReq));
  }

  function _configurePerp(
    PerpAsset perp,
    MockSpotDiffFeed perpFeed,
    MockSpotDiffFeed impactAsk,
    MockSpotDiffFeed impactBid
  ) internal {
    perp.setRateBounds(0.0075e18);
    perp.setSpotFeed(spotFeed);
    perp.setPerpFeed(perpFeed);
    perp.setImpactFeeds(impactAsk, impactBid);
  }

  function _tradePerp(IPerpAsset perp, uint fromAcc, uint toAcc, int amount) internal {
    ISubAccounts.AssetTransfer memory transfer =
      ISubAccounts.AssetTransfer({fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: ""});
    subAccounts.submitTransfer(transfer, "");
  }
}
