// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {Deployment, ConfigJson} from "./types.sol";
import {Utils} from "./utils.sol";
import "./config-mainnet.sol";

/// @dev deploys the wrapped cNGN asset and its spot feed; run after deploy-core,
///      before deploy-deliverable-fx-manager (which whitelists the manager on the asset)
contract DeployWrappedCNGN is Utils {
  string internal constant ARTIFACT_NAME = "CNGN";

  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    ConfigJson memory config = _loadConfig();
    address cngn = vm.parseJsonAddress(_readDeploymentFile("shared"), ".cngn");
    if (cngn == address(0)) revert("shared.cngn missing");
    if (config.feedSigners.length == 0) revert("shared.feedSigners empty");

    Deployment memory deployment = _loadDeployment();

    WrappedERC20Asset wrappedCngn = new WrappedERC20Asset(deployment.subAccounts, IERC20Metadata(cngn));

    LyraSpotFeed spotFeed = new LyraSpotFeed();
    spotFeed.setHeartbeat(Config.SPOT_HEARTBEAT);
    for (uint i = 0; i < config.feedSigners.length; ++i) {
      spotFeed.addSigner(config.feedSigners[i], true);
    }
    spotFeed.setRequiredSigners(config.requiredSigners);

    address[] memory owned = new address[](2);
    owned[0] = address(wrappedCngn);
    owned[1] = address(spotFeed);
    _transferOwnership(owned);

    string memory objKey = "wrapped-cngn";
    vm.serializeAddress(objKey, "base", address(wrappedCngn));
    vm.serializeAddress(objKey, "spotFeed", address(spotFeed));
    vm.serializeAddress(objKey, "wrappedAsset", cngn);
    string memory finalObj = vm.serializeString(objKey, "symbol", "CNGN");
    _writeToDeployments(ARTIFACT_NAME, finalObj);

    console2.log("Wrapped cNGN asset deployed:", address(wrappedCngn));
    console2.log("cNGN spot feed deployed:", address(spotFeed));

    vm.stopBroadcast();
  }
}
