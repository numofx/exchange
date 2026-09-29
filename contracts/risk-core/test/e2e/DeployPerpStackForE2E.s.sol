// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployCngnPerpStack} from "../../scripts/deploy-cngn-perp-stack.s.sol";

/**
 * Deploys the perp stack onto a LOCAL anvil fork for the services' end-to-end tests, through the
 * deploy script's own `deployStack`, and writes the addresses to cache/e2e-perp-stack.json.
 *
 * Never run against a real network: it bypasses the script's `run()` (and so its artifact writes
 * and vault check) on purpose. Refuses any chain id but anvil's.
 *
 *   anvil --fork-url $BASE_RPC_URL --chain-id 31337 --port 8600 &
 *   FEED_SIGNER=<addr> forge script test/e2e/DeployPerpStackForE2E.s.sol --sig "runE2E()" \
 *     --rpc-url http://127.0.0.1:8600 --broadcast \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 */
contract DeployPerpStackForE2E is DeployCngnPerpStack {
  /// @dev Inherits the deploy script and calls `deployStack` internally, exactly as its `run()`
  ///      does: every contract is then a CREATE broadcast from the EOA. Deploying the script itself
  ///      and calling it would not be (and at 111kB it is far over the 24kB code-size limit).
  function runE2E() external {
    require(block.chainid == 31337, "e2e deploy is for a local anvil fork only");

    DeployCngnPerpStack.Params memory params = DeployCngnPerpStack.Params({
      subAccounts: 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843,
      usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
      vault: 0x1dcA42ab54Bd3862853A821F84B29BF65245F435,
      feedSigner: vm.envAddress("FEED_SIGNER"),
      perpOICap: 50_000_000e18
    });

    vm.startBroadcast();
    DeployCngnPerpStack.Stack memory stack = deployStack(params);
    vm.stopBroadcast();

    string memory obj = "e2e";
    vm.serializeAddress(obj, "cash", address(stack.cash));
    vm.serializeAddress(obj, "srm", address(stack.srm));
    vm.serializeAddress(obj, "auction", address(stack.auction));
    vm.serializeAddress(obj, "securityModule", address(stack.securityModule));
    vm.serializeAddress(obj, "indexFeed", address(stack.indexFeed));
    vm.serializeAddress(obj, "markFeed", address(stack.markFeed));
    vm.serializeAddress(obj, "impactAskFeed", address(stack.impactAskFeed));
    vm.serializeAddress(obj, "impactBidFeed", address(stack.impactBidFeed));
    vm.serializeAddress(obj, "perp", address(stack.perp));
    vm.serializeUint(obj, "securityModuleAccount", stack.securityModule.accountId());
    vm.serializeUint(obj, "feeRecipientAccount", stack.feeRecipientAccount);
    vm.serializeUint(obj, "blockNumber", block.number);
    vm.serializeUint(obj, "launchOICap", params.perpOICap);
    string memory json = vm.serializeAddress(obj, "owned", ownedContracts(stack));
    vm.writeJson(json, string.concat(vm.projectRoot(), "/cache/e2e-perp-stack.json"));
  }
}
