// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {IPerpAsset} from "v2-core/src/interfaces/IPerpAsset.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {CashAsset} from "v2-core/src/assets/CashAsset.sol";
import {PerpAsset} from "v2-core/src/assets/PerpAsset.sol";

import {Matching} from "../src/Matching.sol";
import {TradeModule} from "../src/modules/TradeModule.sol";
import {IMatching} from "../src/interfaces/IMatching.sol";
import {Utils} from "./utils.sol";

/**
 * @title DeployCngnPerpTradeModule
 *
 * @dev The TradeModule for USDCcNGN-PERP. Its immutable `quoteAsset` is the perp stack's CashAsset
 *      (risk-core/deployments/8453/CNGN_PERP_STACK.json), so the price-vs-mark leg of a fill and its
 *      fees move in the same backed cash the SRM settles PnL and funding in. The spot module
 *      (quoted in wrapped USDC) is not touched: the two books run side by side, one module each.
 *
 * @dev FEES. CashAsset asks for an allowance only on the debit side, so the fee account can be
 *      credited without granting anything -- unlike the wrapped-quote module, whose fee account had
 *      to pre-grant one. The account is the stack's `feeRecipientAccount`: created by the stack
 *      script under the new SRM and owned by the vault, so no id is resolved off chain here.
 *
 * @dev FEEDS. TradeModule forwards OrderData.managerData to each feed's acceptData BEFORE it builds
 *      the transfers (TradeModule.sol, "Update feeds in advance"), so the matcher can carry freshly
 *      signed index/mark/impact data on every fill. The feeds check their own signatures.
 *
 * @dev CUSTODY. Born owned by the deployer, then nominated to the vault. Its owner can call
 *      setDatedFutureAsset, which zeroes the quote leg of every fill in that asset, so the vault
 *      batch accepts ownership FIRST and allowlists the module on Matching SECOND.
 *
 * Usage:
 *   PRIVATE_KEY=<deployer> forge script scripts/deploy-cngn-perp-trade-module.s.sol \
 *     --rpc-url $BASE_RPC_URL --broadcast
 */
contract DeployCngnPerpTradeModule is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_PERP_TRADE_MODULE";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS";

  /// @dev The vault recorded in risk-core/DEPLOYED_ADDRESSES.md, compared against Matching's owner.
  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  struct Params {
    address matching;
    address subAccounts;
    address cash;
    address srm;
    address perp;
    uint feeRecipientAccount;
    address vault;
  }

  function run() external {
    Params memory params = loadParams();
    assertPreconditions(params);

    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);
    TradeModule module = deployModule(params);
    vm.stopBroadcast();

    assertModule(module, params);
    _writeArtifacts(module, params);
  }

  function loadParams() public view returns (Params memory params) {
    string memory stack = _readRiskCoreArtifact("CNGN_PERP_STACK");
    params.cash = vm.parseJsonAddress(stack, ".cash");
    params.srm = vm.parseJsonAddress(stack, ".srm");
    params.perp = vm.parseJsonAddress(stack, ".perp");
    params.feeRecipientAccount = vm.parseJsonUint(stack, ".feeRecipientAccount");
    params.subAccounts = vm.parseJsonAddress(_readRiskCoreArtifact("core"), ".subAccounts");
    params.matching = vm.parseJsonAddress(_readMatchingDeploymentFile("matching"), ".matching");
    params.vault = EXPECTED_VAULT;
  }

  // ---------------------------------------------------------------------------------------------
  // preconditions: each is a way the module deploys and then cannot trade, or trades wrongly
  // ---------------------------------------------------------------------------------------------

  function assertPreconditions(Params memory params) public view {
    if (params.matching.code.length == 0) revert("matching has no code - wrong chain?");
    if (params.cash.code.length == 0) revert("perp stack cash has no code - stack not deployed?");
    if (Matching(params.matching).owner() != params.vault) revert("matching owner is not the recorded vault");

    // The quote must be THIS stack's cash, the one its SRM settles in; any other and the price leg
    // and the PnL leg of a fill land in different assets.
    if (address(PerpAsset(params.perp).subAccounts()) != params.subAccounts) revert("perp on another ledger");
    if (!CashAsset(params.cash).whitelistedManager(params.srm)) revert("cash does not whitelist the stack srm");
    if (!PerpAsset(params.perp).whitelistedManager(params.srm)) revert("perp does not whitelist the stack srm");

    ISubAccounts subAccounts = ISubAccounts(params.subAccounts);
    if (subAccounts.ownerOf(params.feeRecipientAccount) != params.vault) revert("fee account is not vault-owned");
    if (address(subAccounts.manager(params.feeRecipientAccount)) != params.srm) {
      revert("fee account is not under the stack srm");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deployModule(Params memory params) public returns (TradeModule module) {
    module = new TradeModule(IMatching(params.matching), IAsset(params.cash), params.feeRecipientAccount);
    module.setPerpAsset(IPerpAsset(params.perp), true);
    module.transferOwnership(params.vault);
  }

  function assertModule(TradeModule module, Params memory params) public view {
    if (address(module.quoteAsset()) != params.cash) revert("module quote is not the stack cash");
    if (!module.isPerpAsset(IPerpAsset(params.perp))) revert("perp not registered on the module");
    if (module.feeRecipient() != params.feeRecipientAccount) revert("fee recipient mismatch");
    if (module.pendingOwner() != params.vault) revert("module not nominated to the vault");
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(TradeModule module, Params memory params) internal {
    string memory obj = "cngn-perp-trade-module";
    vm.serializeAddress(obj, "tradePerp", address(module));
    vm.serializeAddress(obj, "quoteAsset", params.cash);
    vm.serializeAddress(obj, "perp", params.perp);
    vm.serializeAddress(obj, "matching", params.matching);
    string memory json = vm.serializeUint(obj, "feeRecipient", params.feeRecipientAccount);
    _writeToDeployments(ARTIFACT_NAME, json);
    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(module, params));

    console2.log("PERP_TRADE_MODULE_ADDRESS=%s", address(module));
    console2.log("PERP_QUOTE_ASSET_ADDRESS=%s", params.cash);
    console2.log("Run the stack's CNGN_PERP_STACK_VAULT_ACTIONS first, then this batch in order.");
  }

  /// @dev 0: take custody of the module. 1: allowlist it on Matching. In that order, always.
  function vaultActionsJson(TradeModule module, Params memory params) public pure returns (string memory) {
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    bytes memory allow = abi.encodeCall(Matching.setAllowedModule, (address(module), true));
    return string.concat(
      "[",
      _action(
        "module.acceptOwnership() [custody first: the owner can zero a fill's quote leg]", address(module), accept
      ),
      ",",
      _action(
        "matching.setAllowedModule(perpTradeModule, true) [opens the USDCcNGN-PERP book]", params.matching, allow
      ),
      "]"
    );
  }

  function _action(string memory description, address to, bytes memory data) internal pure returns (string memory) {
    return string.concat(
      '{"description":"',
      description,
      '","to":"',
      vm.toString(to),
      '","value":"0","data":"',
      vm.toString(data),
      '","digest":"',
      vm.toString(keccak256(abi.encodePacked(to, keccak256(data)))),
      '"}'
    );
  }

  function _readRiskCoreArtifact(string memory name) internal view returns (string memory) {
    return vm.readFile(
      string.concat(vm.projectRoot(), "/../risk-core/deployments/", vm.toString(block.chainid), "/", name, ".json")
    );
  }
}
