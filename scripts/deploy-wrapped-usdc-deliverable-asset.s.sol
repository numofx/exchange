// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";

contract DeployWrappedUSCDeliverableAsset is Utils {
  string internal constant ARTIFACT_NAME = "WRAPPED_USDC_DELIVERABLE";
  string internal constant MARKET_NAME = "WRAPPED_USDC_DELIVERABLE";
  uint internal constant POSITION_CAP = 1e36;
  uint internal constant MARGIN_FACTOR = 0.98e18;
  uint internal constant IM_SCALE = 0.98e18;

  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    address usdc = vm.parseJsonAddress(_readDeploymentFile("shared"), ".usdc");
    if (usdc == address(0)) revert("shared.usdc missing");

    Deployment memory deployment = _loadDeployment();
    WrappedERC20Asset asset = new WrappedERC20Asset(deployment.subAccounts, IERC20Metadata(usdc));

    asset.setWhitelistManager(address(deployment.srm), true);
    asset.setTotalPositionCap(IManager(address(deployment.srm)), POSITION_CAP);

    uint marketId = deployment.srm.createMarket(MARKET_NAME);
    deployment.srm.whitelistAsset(asset, marketId, IStandardManager.AssetType.Base);
    deployment.srm.setOraclesForMarket(marketId, deployment.stableFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    deployment.srm.setBaseAssetMarginFactor(marketId, MARGIN_FACTOR, IM_SCALE);

    IStandardManager.AssetDetail memory detail = deployment.srm.assetDetails(asset);
    if (!detail.isWhitelisted || detail.assetType != IStandardManager.AssetType.Base) revert("usdc base registration failed");
    if (!asset.whitelistedManager(address(deployment.srm))) revert("manager whitelist failed");

    string memory objKey = "wrapped-usdc-deliverable";
    vm.serializeAddress(objKey, "base", address(asset));
    vm.serializeUint(objKey, "marketId", marketId);
    vm.serializeAddress(objKey, "wrappedAsset", usdc);
    vm.serializeString(objKey, "symbol", MARKET_NAME);
    vm.serializeString(objKey, "marginFactor", vm.toString(MARGIN_FACTOR));
    vm.serializeString(objKey, "IMScale", vm.toString(IM_SCALE));
    vm.serializeAddress(objKey, "WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS", address(asset));
    string memory finalObj = vm.serializeString(objKey, "marketName", MARKET_NAME);
    _writeToDeployments(ARTIFACT_NAME, finalObj);

    console2.log("Wrapped USDC deliverable asset deployed:", address(asset));
    console2.log("WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS=%s", address(asset));

    vm.stopBroadcast();
  }
}
