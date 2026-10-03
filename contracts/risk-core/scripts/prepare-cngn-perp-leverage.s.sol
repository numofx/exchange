// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";

import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {CNGNPerpLeverageBatch} from "./cngn-perp-leverage-batch.sol";
import {Utils} from "./utils.sol";

/**
 * Writes the stage (B) leverage batch for review: CNGN_PERP_LEVERAGE.json (the parameters and the
 * batch hash) and CNGN_PERP_LEVERAGE_VAULT_ACTIONS.json (two vault calls, in order). Deploys nothing
 * and broadcasts nothing; it reads live chain state, checks the structural preconditions, and
 * reports whether the SecurityModule already holds the floor the proposer will insist on.
 *
 *   forge script scripts/prepare-cngn-perp-leverage.s.sol --rpc-url $BASE_RPC_URL
 *
 * Overrides (18dp unless noted): PERP_MM_REQ (0.12), PERP_IM_REQ (0.2), CNGN_MARGIN_FACTOR (0.35),
 * SECURITY_MODULE_FLOOR_USD (whole dollars, 6000).
 */
contract PrepareCngnPerpLeverage is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_PERP_LEVERAGE";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_PERP_LEVERAGE_VAULT_ACTIONS";
  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  /// @dev 5x: sized by CngnPerpFiveXFork with the factor below.
  uint public constant DEFAULT_MM_REQ = 0.12e18;
  uint public constant DEFAULT_IM_REQ = 0.2e18;
  /// @dev Solvent through a 25% step at MM 12% with a long-naira account on cNGN alone (bound 0.36).
  uint public constant DEFAULT_MARGIN_FACTOR = 0.35e18;
  /// @dev The SecurityModule covers the 25% USDC case at either bid timing and the 40% case with the keeper.
  uint public constant DEFAULT_SECURITY_MODULE_FLOOR = 6_000e18;

  function run() external {
    CNGNPerpLeverageBatch.Ctx memory ctx = loadCtx();
    CNGNPerpLeverageBatch.checkPreconditions(ctx);

    int held = ISubAccounts(ctx.subAccounts).getBalance(ctx.securityModuleAccount, IAsset(ctx.cash), 0);
    bool funded = held >= int(ctx.securityModuleFloor);

    _writeGeneratedArtifact(ARTIFACT_NAME, artifactJson(ctx, held));
    _writeGeneratedArtifact(VAULT_ACTIONS_NAME, vaultActionsJson(ctx));

    console2.log("perp margin requirements after: MM / IM (18dp):", ctx.mmReq, ctx.imReq);
    console2.log("cNGN margin factor after (18dp):", ctx.marginFactor);
    console2.log("SecurityModule cash now ($, 18dp, signed):", held);
    console2.log("SecurityModule floor ($, 18dp):", ctx.securityModuleFloor);
    console2.log(funded ? "SecurityModule holds the floor" : "SecurityModule BELOW the floor: fund it before proposing");
    console2.log("batch hash:", vm.toString(CNGNPerpLeverageBatch.hash(ctx)));
    console2.log("Vault executes the %s calls in %s.json IN ORDER, after the SecurityModule top-up.", CNGNPerpLeverageBatch.ACTION_COUNT, VAULT_ACTIONS_NAME);
  }

  function loadCtx() public view returns (CNGNPerpLeverageBatch.Ctx memory ctx) {
    string memory stack = _readDeploymentFile("CNGN_PERP_STACK");
    ctx.vault = EXPECTED_VAULT;
    ctx.srm = vm.parseJsonAddress(stack, ".srm");
    ctx.cash = vm.parseJsonAddress(stack, ".cash");
    ctx.securityModuleAccount = vm.parseJsonUint(stack, ".securityModuleAccount");
    ctx.marketId = vm.parseJsonUint(stack, ".marketId");
    ctx.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    // The IM scale is the one batch 4 set; this batch leaves it alone.
    ctx.imScale = vm.parseJsonUint(_readDeploymentFile("CNGN_PERP_COLLATERAL"), ".imScale");
    ctx.mmReq = vm.envOr("PERP_MM_REQ", DEFAULT_MM_REQ);
    ctx.imReq = vm.envOr("PERP_IM_REQ", DEFAULT_IM_REQ);
    ctx.marginFactor = vm.envOr("CNGN_MARGIN_FACTOR", DEFAULT_MARGIN_FACTOR);
    ctx.securityModuleFloor = vm.envOr("SECURITY_MODULE_FLOOR_USD", DEFAULT_SECURITY_MODULE_FLOOR / 1e18) * 1e18;
  }

  function artifactJson(CNGNPerpLeverageBatch.Ctx memory ctx, int securityModuleCashNow) public returns (string memory) {
    string memory obj = "leverage";
    vm.serializeAddress(obj, "vault", ctx.vault);
    vm.serializeAddress(obj, "srm", ctx.srm);
    vm.serializeAddress(obj, "cash", ctx.cash);
    vm.serializeAddress(obj, "subAccounts", ctx.subAccounts);
    vm.serializeUint(obj, "securityModuleAccount", ctx.securityModuleAccount);
    vm.serializeUint(obj, "marketId", ctx.marketId);
    vm.serializeUint(obj, "mmReq", ctx.mmReq);
    vm.serializeUint(obj, "imReq", ctx.imReq);
    vm.serializeUint(obj, "marginFactor", ctx.marginFactor);
    vm.serializeUint(obj, "imScale", ctx.imScale);
    vm.serializeUint(obj, "securityModuleFloor", ctx.securityModuleFloor);
    vm.serializeInt(obj, "securityModuleCashAtRender", securityModuleCashNow);
    vm.serializeString(obj, "hedgeMode", "1:1, unchanged (markets-service and app; not on chain)");
    return vm.serializeBytes32(obj, "batchHash", CNGNPerpLeverageBatch.hash(ctx));
  }

  /// @dev The batch in the recorded vault-action format, one object per call, in order.
  function vaultActionsJson(CNGNPerpLeverageBatch.Ctx memory ctx) public pure returns (string memory json) {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = CNGNPerpLeverageBatch.build(ctx);
    json = "[";
    for (uint i = 0; i < to.length; i++) {
      json = string.concat(
        json,
        i == 0 ? "" : ",",
        '{"description":"',
        descriptions[i],
        '","to":"',
        vm.toString(to[i]),
        '","value":"0","data":"',
        vm.toString(data[i]),
        '","digest":"',
        vm.toString(CNGNPerpLeverageBatch.actionHash(to[i], data[i])),
        '"}'
      );
    }
    json = string.concat(json, "]");
  }
}
