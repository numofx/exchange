// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployCngnPerpCollateral} from "../../scripts/deploy-cngn-perp-collateral.s.sol";
import {CNGNPerpCollateralBatch} from "../../scripts/cngn-perp-collateral-batch.sol";

/**
 * Deploys the perp's cNGN collateral escrow onto a LOCAL anvil fork for the local venue, through
 * the deploy script's own `deployEscrow`, against the e2e perp stack (cache/e2e-perp-stack.json),
 * and writes cache/e2e-perp-collateral.json plus the vault batch the venue applies as the vault.
 *
 * Never run against a real network: it bypasses `run()` (artifact writes, the vault check) on
 * purpose. Refuses any chain id but anvil's.
 */
contract DeployCngnPerpCollateralForE2E is DeployCngnPerpCollateral {
  function runE2E() external {
    require(block.chainid == 31337, "e2e deploy is for a local anvil fork only");

    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/cache/e2e-perp-stack.json"));
    DeployCngnPerpCollateral.Params memory params = DeployCngnPerpCollateral.Params({
      subAccounts: 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843,
      cngnToken: 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F,
      srm: vm.parseJsonAddress(stack, ".srm"),
      cash: vm.parseJsonAddress(stack, ".cash"),
      indexFeed: vm.parseJsonAddress(stack, ".indexFeed"),
      marketId: 1,
      vault: 0x1dcA42ab54Bd3862853A821F84B29BF65245F435,
      marginFactor: SIZED_MARGIN_FACTOR,
      imScale: DEFAULT_IM_SCALE,
      cap: DEFAULT_COLLATERAL_CAP,
      rateFloor: DEFAULT_RATE_FLOOR
    });

    vm.startBroadcast();
    Deployed memory deployed = deploy(params);
    vm.stopBroadcast();

    CNGNPerpCollateralBatch.Ctx memory ctx = batchCtx(deployed, params);
    string memory obj = "e2e-collateral";
    vm.serializeAddress(obj, "escrow", address(deployed.escrow));
    vm.serializeAddress(obj, "rateModel", address(deployed.rateModel));
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "cngnToken", params.cngnToken);
    vm.serializeAddress(obj, "srm", params.srm);
    vm.serializeUint(obj, "marginFactor", params.marginFactor);
    vm.serializeUint(obj, "imScale", params.imScale);
    string memory json = vm.serializeUint(obj, "collateralCap", params.cap);
    vm.writeJson(json, string.concat(vm.projectRoot(), "/cache/e2e-perp-collateral.json"));
    vm.writeFile(
      string.concat(vm.projectRoot(), "/cache/e2e-perp-collateral-vault-actions.json"), vaultActionsJson(ctx)
    );
    vm.writeFile(
      string.concat(vm.projectRoot(), "/cache/e2e-perp-collateral-enable-vault-actions.json"), enableActionsJson(ctx)
    );
  }
}
