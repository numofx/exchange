// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../shared/mocks/MockFeeds.sol";
import "../../../shared/mocks/MockManager.sol";
import "../../../shared/mocks/MockSpotDiffFeed.sol";

import "../../../../src/SubAccounts.sol";
import "../../../../src/assets/SquaredPerpAsset.sol";
import {ISubAccounts} from "../../../../src/interfaces/ISubAccounts.sol";

contract UNIT_SquaredPerpAsset is Test {
  SquaredPerpAsset perp;
  MockManager manager;
  SubAccounts subAccounts;
  MockFeeds spotFeed;
  MockSpotDiffFeed perpFeed;
  MockSpotDiffFeed impactAsk;
  MockSpotDiffFeed impactBid;

  address alice = address(0xaaaa);
  address bob = address(0xbbbb);
  uint aliceAcc;
  uint bobAcc;

  function setUp() public {
    subAccounts = new SubAccounts("Lyra", "LYRA");

    spotFeed = new MockFeeds();
    spotFeed.setSpot(20e18, 1e18);

    perpFeed = new MockSpotDiffFeed(spotFeed);
    impactAsk = new MockSpotDiffFeed(spotFeed);
    impactBid = new MockSpotDiffFeed(spotFeed);

    manager = new MockManager(address(subAccounts));
    perp = new SquaredPerpAsset(subAccounts);

    perp.setRateBounds(0.0075e18);
    perp.setSpotFeed(spotFeed);
    perp.setPerpFeed(perpFeed);
    perp.setImpactFeeds(impactAsk, impactBid);
    perp.setWhitelistManager(address(manager), true);

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);
  }

  function testSquaresIndexAndPerpPrice() public {
    perpFeed.setSpotDiff(2e18, 1e18);

    (uint indexPrice,) = perp.getIndexPrice();
    (uint perpPrice,) = perp.getPerpPrice();

    assertEq(indexPrice, 400e18);
    assertEq(perpPrice, 484e18);
  }

  function testUsesSquaredMarkForPnl() public {
    perpFeed.setSpotDiff(0, 1e18);
    _tradePerpContract(aliceAcc, bobAcc, 1e18);

    spotFeed.setSpot(22e18, 1e18);
    perpFeed.setSpotDiff(0, 1e18);

    assertEq(perp.getUnsettledAndUnrealizedCash(bobAcc), 84e18);
    assertEq(perp.getUnsettledAndUnrealizedCash(aliceAcc), -84e18);
  }

  function _tradePerpContract(uint fromAcc, uint toAcc, int amount) internal {
    ISubAccounts.AssetTransfer memory transfer =
      ISubAccounts.AssetTransfer({fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: ""});
    subAccounts.submitTransfer(transfer, "");
  }
}
