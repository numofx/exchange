// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../../src/SubAccounts.sol";
import "../../../../src/risk-managers/BasePortfolioViewer.sol";
import "../../../../src/risk-managers/DeliverableFXManager.sol";
import {IAsset} from "../../../../src/interfaces/IAsset.sol";
import {ICashAsset} from "../../../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../../../src/interfaces/IDutchAuction.sol";
import "../../../../src/assets/WrappedERC20Asset.sol";
import "../../../../src/assets/DeliverableFXFutureAsset.sol";

import "../../../shared/mocks/MockERC20.sol";
import "../../../shared/mocks/MockFeeds.sol";
import "../../../shared/mocks/MockCash.sol";
import "../../mocks/MockDutchAuction.sol";

contract TestDeliverableFXManagerBase is Test {
  SubAccounts subAccounts;
  DeliverableFXManager manager;
  BasePortfolioViewer portfolioViewer;

  MockCash cash;
  MockERC20 usdc;
  MockERC20 cngn;
  WrappedERC20Asset usdcDeliveryAsset;
  WrappedERC20Asset cngnAsset;
  DeliverableFXFutureAsset fxFuture;
  MockFeeds cngnFeed;

  uint aliceAcc;
  uint bobAcc;
  uint charlieAcc;
  address alice = address(0xaa);
  address bob = address(0xbb);
  address charlie = address(0xcc);

  uint96 fxSeries;
  uint fxLastTradeTime;
  uint fxExpiry;

  function setUp() public virtual {
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    usdc = new MockERC20("USDC", "USDC");
    cngn = new MockERC20("cNGN", "cNGN");
    cash = new MockCash(usdc, subAccounts);
    portfolioViewer = new BasePortfolioViewer(subAccounts, cash);
    manager = new DeliverableFXManager(
      subAccounts, ICashAsset(address(cash)), IDutchAuction(new MockDutchAuction()), portfolioViewer
    );

    usdcDeliveryAsset = new WrappedERC20Asset(subAccounts, usdc);
    cngnAsset = new WrappedERC20Asset(subAccounts, cngn);
    fxFuture = new DeliverableFXFutureAsset(subAccounts);

    usdcDeliveryAsset.setWhitelistManager(address(manager), true);
    cngnAsset.setWhitelistManager(address(manager), true);
    fxFuture.setWhitelistManager(address(manager), true);

    usdcDeliveryAsset.setTotalPositionCap(manager, 1e36);
    cngnAsset.setTotalPositionCap(manager, 1e36);
    fxFuture.setTotalPositionCap(manager, 1e36);

    cngnFeed = new MockFeeds();
    cngnFeed.setSpot(1500e18, 1e18);

    manager.setProduct(fxFuture, usdcDeliveryAsset, cngnAsset, cngnFeed);
    manager.setMarginParams(0.10e18, 0.075e18);

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);
    charlieAcc = subAccounts.createAccountWithApproval(charlie, address(this), manager);

    fxExpiry = block.timestamp + 21 days;
    fxLastTradeTime = fxExpiry - 1 days;
    fxSeries = fxFuture.createSeries(
      uint64(fxExpiry), uint64(fxLastTradeTime), address(usdcDeliveryAsset), address(cngnAsset), 10_000e18, 0.001e18, 1e18, 1500e18
    );

    usdc.mint(address(this), 100_000_000e18);
    usdc.approve(address(cash), type(uint).max);
    usdc.approve(address(usdcDeliveryAsset), type(uint).max);
    cngn.approve(address(cngnAsset), type(uint).max);
  }

  function _fundCash(uint acc, uint amount) internal {
    usdc.mint(address(this), amount);
    cash.deposit(acc, amount);
  }

  function _depositWrapped(MockERC20 token, WrappedERC20Asset asset, uint account, uint amount) internal {
    token.mint(address(this), amount);
    token.approve(address(asset), amount);
    asset.deposit(account, amount);
  }

  function _openFuturePosition(uint shortAcc, uint longAcc, int amount) internal {
    ISubAccounts.AssetTransfer memory transfer = ISubAccounts.AssetTransfer({
      fromAcc: shortAcc,
      toAcc: longAcc,
      asset: fxFuture,
      subId: fxSeries,
      amount: amount,
      assetData: ""
    });
    subAccounts.submitTransfer(transfer, "");
  }

  function _getCashBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  function _createSeries(uint expiryOffset, uint lastTradeLead, uint initialMarkPrice) internal returns (uint96) {
    uint expiry = block.timestamp + expiryOffset;
    return fxFuture.createSeries(
      uint64(expiry),
      uint64(expiry - lastTradeLead),
      address(usdcDeliveryAsset),
      address(cngnAsset),
      10_000e18,
      0.001e18,
      1e18,
      initialMarkPrice
    );
  }
}
