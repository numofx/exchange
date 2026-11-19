// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";
import {Utils} from "./utils.sol";
import "../src/periphery/NumoSettlementUtils.sol";


contract DeploySettlementUtils is Utils {
  /// @dev main function
  function run() external {

    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    address deployer = vm.addr(deployerPrivateKey);
    console2.log("deployer: ", deployer);

    NumoSettlementUtils settlementUtils = new NumoSettlementUtils();

    console2.log("settlement utils address: ", address(settlementUtils));
  }
}