// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IManager} from "../src/interfaces/IManager.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IDeliverableFXFutureAsset} from "../src/interfaces/IDeliverableFXFutureAsset.sol";
import {BasePortfolioViewer} from "../src/risk-managers/BasePortfolioViewer.sol";
import {DeliverableFXManager} from "../src/risk-managers/DeliverableFXManager.sol";
import {DeliverableFXFutureAsset} from "../src/assets/DeliverableFXFutureAsset.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";

contract DeployDeliverableFXManager is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_APR30_2026_FUTURE";
  string internal constant ONCHAIN_MARKET_NAME = "USDC/cNGN APR-30-2026";

  uint64 internal constant EXPIRY = 1777507200;
  uint64 internal constant LAST_TRADE_TIME = 1777420800;
  uint internal constant CONTRACT_SIZE_BASE = 10_000e18;
  uint internal constant MIN_TRADE_INCREMENT = 0.001e18;
  uint internal constant TICK_SIZE = 1e18;
  uint internal constant INITIAL_MARK_PRICE = 1500e18;
  uint internal constant POSITION_CAP = 1e36;
  uint internal constant NORMAL_IM = 0.01e18;
  uint internal constant NORMAL_MM = 0.005e18;

  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    if (LAST_TRADE_TIME >= EXPIRY) revert("invalid future schedule");

    address usdcDeliverableAsset = vm.envAddress("WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS");
    if (usdcDeliverableAsset == address(0)) revert("WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS is required");

    string memory cngnDeployment = _readDeploymentFile("CNGN");
    address wrappedCngnAsset = vm.parseJsonAddress(cngnDeployment, ".base");
    address cngnSpotFeed = vm.parseJsonAddress(cngnDeployment, ".spotFeed");
    if (wrappedCngnAsset == address(0) || cngnSpotFeed == address(0)) revert("WRAPPED_CNGN deployment incomplete");

    Deployment memory deployment = _loadDeployment();

    BasePortfolioViewer viewer = new BasePortfolioViewer(deployment.subAccounts, deployment.cash);
    DeliverableFXManager manager =
      new DeliverableFXManager(deployment.subAccounts, deployment.cash, deployment.auction, viewer);
    DeliverableFXFutureAsset future = new DeliverableFXFutureAsset(deployment.subAccounts);

    deployment.auction.setWhitelistManager(address(manager), true);
    deployment.cash.setWhitelistManager(address(manager), true);

    WrappedERC20Asset(usdcDeliverableAsset).setWhitelistManager(address(manager), true);
    WrappedERC20Asset(wrappedCngnAsset).setWhitelistManager(address(manager), true);
    future.setWhitelistManager(address(manager), true);

    WrappedERC20Asset(usdcDeliverableAsset).setTotalPositionCap(IManager(address(manager)), POSITION_CAP);
    WrappedERC20Asset(wrappedCngnAsset).setTotalPositionCap(IManager(address(manager)), POSITION_CAP);
    future.setTotalPositionCap(IManager(address(manager)), POSITION_CAP);

    manager.setProduct(
      IDeliverableFXFutureAsset(address(future)), IAsset(usdcDeliverableAsset), IAsset(wrappedCngnAsset), ISpotFeed(cngnSpotFeed)
    );
    manager.setMarginParams(NORMAL_IM, NORMAL_MM);

    uint96 subId = future.createSeries(
      EXPIRY,
      LAST_TRADE_TIME,
      usdcDeliverableAsset,
      wrappedCngnAsset,
      uint128(CONTRACT_SIZE_BASE),
      uint128(MIN_TRADE_INCREMENT),
      uint128(TICK_SIZE),
      INITIAL_MARK_PRICE
    );

    _writeDeploymentArtifact(manager, viewer, future, subId, usdcDeliverableAsset, wrappedCngnAsset, cngnSpotFeed);

    console2.log("Deliverable FX manager deployed:", address(manager));
    console2.log("Deliverable FX viewer deployed:", address(viewer));
    console2.log("Deliverable FX future deployed:", address(future));
    console2.log("Series subId:", uint(subId));
    console2.log("CNGN_APR30_2026_FUTURE_ASSET_ADDRESS=%s", address(future));
    console2.log("CNGN_APR30_2026_FUTURE_SUB_ID=%s", vm.toString(uint(subId)));

    vm.stopBroadcast();
  }

  function _writeDeploymentArtifact(
    DeliverableFXManager manager,
    BasePortfolioViewer viewer,
    DeliverableFXFutureAsset future,
    uint96 subId,
    address usdcDeliverableAsset,
    address wrappedCngnAsset,
    address cngnSpotFeed
  ) internal {
    string memory objKey = "deliverable-fx-future";

    vm.serializeAddress(objKey, "manager", address(manager));
    vm.serializeAddress(objKey, "viewer", address(viewer));
    vm.serializeAddress(objKey, "future", address(future));
    vm.serializeString(objKey, "symbol", ONCHAIN_MARKET_NAME);
    vm.serializeString(objKey, "subId", vm.toString(uint(subId)));
    vm.serializeUint(objKey, "expiry", EXPIRY);
    vm.serializeUint(objKey, "lastTradeTime", LAST_TRADE_TIME);
    vm.serializeAddress(objKey, "baseAsset", usdcDeliverableAsset);
    vm.serializeAddress(objKey, "quoteAsset", wrappedCngnAsset);
    vm.serializeAddress(objKey, "spotFeed", cngnSpotFeed);
    vm.serializeString(objKey, "contractSizeBase", vm.toString(CONTRACT_SIZE_BASE));
    vm.serializeString(objKey, "minTradeIncrement", vm.toString(MIN_TRADE_INCREMENT));
    vm.serializeString(objKey, "tickSize", vm.toString(TICK_SIZE));
    vm.serializeString(objKey, "initialMarkPrice", vm.toString(INITIAL_MARK_PRICE));
    vm.serializeString(objKey, "normalIM", vm.toString(NORMAL_IM));
    vm.serializeString(objKey, "normalMM", vm.toString(NORMAL_MM));
    vm.serializeAddress(objKey, "CNGN_APR30_2026_FUTURE_ASSET_ADDRESS", address(future));
    string memory finalObj = vm.serializeString(objKey, "CNGN_APR30_2026_FUTURE_SUB_ID", vm.toString(uint(subId)));

    _writeToDeployments(ARTIFACT_NAME, finalObj);
  }
}
