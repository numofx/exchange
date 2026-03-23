// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IManager} from "../src/interfaces/IManager.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {DeliverableFXFutureAsset} from "../src/assets/DeliverableFXFutureAsset.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";

contract DeployDeliverableFXFuture is Utils {
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

    address usdcDeliverableAsset = vm.envAddress("USDC_DELIVERABLE_ASSET_ADDRESS");
    if (usdcDeliverableAsset == address(0)) revert("USDC_DELIVERABLE_ASSET_ADDRESS is required");

    string memory cngnDeployment = _readDeploymentFile("CNGN");
    address cngnBaseAsset = vm.parseJsonAddress(cngnDeployment, ".base");
    address cngnSpotFeed = vm.parseJsonAddress(cngnDeployment, ".spotFeed");
    if (cngnBaseAsset == address(0) || cngnSpotFeed == address(0)) revert("CNGN deployment incomplete");

    Deployment memory deployment = _loadDeployment();
    DeliverableFXFutureAsset future = new DeliverableFXFutureAsset(deployment.subAccounts);

    future.setWhitelistManager(address(deployment.srm), true);
    future.setTotalPositionCap(IManager(address(deployment.srm)), POSITION_CAP);

    uint marketId = deployment.srm.createMarket(ONCHAIN_MARKET_NAME);
    deployment.srm.whitelistAsset(future, marketId, IStandardManager.AssetType.DeliverableFXFuture);
    deployment.srm.setOraclesForMarket(marketId, ISpotFeed(cngnSpotFeed), IForwardFeed(address(0)), IVolFeed(address(0)));
    deployment.srm.setDeliverableFXMarginParams(
      marketId, IStandardManager.DeliverableFXMarginParams({normalIM: NORMAL_IM, normalMM: NORMAL_MM})
    );

    IStandardManager.AssetDetail memory detail = deployment.srm.assetDetails(IAsset(address(future)));
    if (!detail.isWhitelisted || detail.assetType != IStandardManager.AssetType.DeliverableFXFuture) {
      revert("future registration failed");
    }
    if (!future.whitelistedManager(address(deployment.srm))) revert("manager whitelist failed");

    uint96 subId = future.createSeries(
      EXPIRY,
      LAST_TRADE_TIME,
      usdcDeliverableAsset,
      cngnBaseAsset,
      uint128(CONTRACT_SIZE_BASE),
      uint128(MIN_TRADE_INCREMENT),
      uint128(TICK_SIZE),
      INITIAL_MARK_PRICE
    );

    _writeDeploymentArtifact(future, marketId, subId, usdcDeliverableAsset, cngnBaseAsset, cngnSpotFeed);

    console2.log("Deliverable FX future deployed:", address(future));
    console2.log("Series subId:", uint(subId));
    console2.log("Export for downstream services:");
    console2.log("CNGN_APR30_2026_FUTURE_ASSET_ADDRESS=%s", address(future));
    console2.log("CNGN_APR30_2026_FUTURE_SUB_ID=%s", vm.toString(uint(subId)));

    vm.stopBroadcast();
  }

  function _writeDeploymentArtifact(
    DeliverableFXFutureAsset future,
    uint marketId,
    uint96 subId,
    address usdcDeliverableAsset,
    address cngnBaseAsset,
    address cngnSpotFeed
  ) internal {
    string memory objKey = "deliverable-fx-future";

    vm.serializeAddress(objKey, "future", address(future));
    vm.serializeUint(objKey, "marketId", marketId);
    vm.serializeString(objKey, "symbol", ONCHAIN_MARKET_NAME);
    vm.serializeString(objKey, "subId", vm.toString(uint(subId)));
    vm.serializeUint(objKey, "expiry", EXPIRY);
    vm.serializeUint(objKey, "lastTradeTime", LAST_TRADE_TIME);
    vm.serializeAddress(objKey, "baseAsset", usdcDeliverableAsset);
    vm.serializeAddress(objKey, "quoteAsset", cngnBaseAsset);
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
