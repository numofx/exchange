// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {Utils} from "./utils.sol";

import {NumoERC20} from "../src/l2/NumoERC20.sol";


// Deploy mocked contracts: then write to script/input as input for deploying core and v2 markets
contract DeployERC20s is Utils {

  /// @dev main function
  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);
    address deployer = vm.addr(deployerPrivateKey);

    console2.log("Start deploying ERC20 contracts! deployer: ", deployer);

    address[] memory feedSigners = new address[](1);
    feedSigners[0] = deployer;

    // write to shared file: eg: deployments/31337/shared.json
    string memory objKey = "network-config";
    vm.serializeAddress(objKey, "usdc", address(new NumoERC20("USDC", "USDC", 6)));
    vm.serializeAddress(objKey, "btc", address(new NumoERC20("Numo WBTC", "WBTC", 8)));
    vm.serializeAddress(objKey, "eth", address(new NumoERC20("Numo WETH", "WETH", 18)));
    vm.serializeAddress(objKey, "usdt", address(new NumoERC20("Numo USDT", "USDT", 6)));
    vm.serializeAddress(objKey, "snx", address(new NumoERC20("Numo SNX", "SNX", 18)));
    vm.serializeAddress(objKey, "wsteth", address(new NumoERC20("Numo x Lido wstETH", "wstETH", 18)));
//    vm.serializeAddress(objKey, "rsweth", address(new NumoERC20("Numo rswETH", "wstETH", 18)));
//    vm.serializeAddress(objKey, "susde", address(new NumoERC20("Numo Staked USDe", "sUSDe", 18)));

    vm.serializeAddress(objKey, "feedSigners", feedSigners);
    vm.serializeUint(objKey, "requiredSigners", 1);
    string memory finalObj = vm.serializeBool(objKey, "useMockedFeed", false);

    // build path
    _writeToDeployments("shared", finalObj);

    vm.stopBroadcast();
  }
}