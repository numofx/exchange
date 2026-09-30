// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {TradeModule} from "src/modules/TradeModule.sol";
import {DeployCngnPerpTradeModule} from "../../scripts/deploy-cngn-perp-trade-module.s.sol";

/**
 * Deploys the perp TradeModule onto a LOCAL anvil fork for end-to-end runs, through the module
 * script's own `deployModule`, against the stack risk-core's DeployPerpStackForE2E wrote to
 * ../risk-core/cache/e2e-perp-stack.json. Writes the module address to cache/e2e-perp-module.json.
 * Refuses any chain id but anvil's.
 */
contract DeployPerpModuleForE2E is DeployCngnPerpTradeModule {
  function runE2E() external {
    require(block.chainid == 31337, "e2e deploy is for a local anvil fork only");
    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/../risk-core/cache/e2e-perp-stack.json"));
    Params memory params = Params({
      matching: 0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191,
      subAccounts: 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843,
      cash: vm.parseJsonAddress(stack, ".cash"),
      srm: vm.parseJsonAddress(stack, ".srm"),
      perp: vm.parseJsonAddress(stack, ".perp"),
      feeRecipientAccount: vm.parseJsonUint(stack, ".feeRecipientAccount"),
      vault: EXPECTED_VAULT
    });
    assertPreconditions(params);

    vm.startBroadcast();
    TradeModule module = deployModule(params);
    vm.stopBroadcast();

    assertModule(module, params);
    vm.serializeAddress("e2e", "matching", params.matching);
    vm.writeJson(
      vm.serializeAddress("e2e", "tradePerp", address(module)),
      string.concat(vm.projectRoot(), "/cache/e2e-perp-module.json")
    );
    // The same vault batch the mainnet run writes, for the review renderer and the local venue.
    vm.writeFile(
      string.concat(vm.projectRoot(), "/cache/e2e-perp-module-vault-actions.json"), vaultActionsJson(module, params)
    );
  }
}
