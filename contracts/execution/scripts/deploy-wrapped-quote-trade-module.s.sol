// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {Matching} from "../src/Matching.sol";
import {TradeModule} from "../src/modules/TradeModule.sol";

import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";

import {Utils} from "./utils.sol";

interface IOwned {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

/**
 * @title DeployWrappedQuoteTradeModule
 *
 * @notice Deploys a second TradeModule for the USDC/cNGN spot book whose `quoteAsset` is the
 *         existing WRAPPED_USDC_DELIVERABLE WrappedERC20Asset instead of CashAsset, so BOTH legs
 *         of a spot fill are wrapped-token transfers and the settlement ledger leaves the trade
 *         path entirely.
 *
 * @dev WHAT THIS SCRIPT DOES (deployer key):
 *        1. deploys TradeModule(matching, wrappedUsdc, feeRecipient)
 *        2. optionally registers a dated future asset on it
 *        3. hands ownership to the vault (Ownable2Step: sets pendingOwner only)
 *
 * @dev WHAT IT CANNOT DO. Matching is owned by the MPC vault
 *      (DEPLOYED_ADDRESSES.md), so `setAllowedModule` is onlyOwner and cannot be broadcast from a
 *      deployer key. The script therefore writes the vault's calldata to
 *      deployments/{chainId}/WRAPPED_QUOTE_TRADE_VAULT_ACTIONS.json, following the same pattern as
 *      risk-core's CNGN_SPOT_SRM_VAULT_ACTIONS.json. Until the vault executes action 0, the module
 *      exists but Matching.verifyAndMatch reverts M_OnlyAllowedModule for it -- which is the safe
 *      resting state.
 *
 * @dev THE FEE ALLOWANCE, and why there is a third action.
 *      WrappedERC20Asset.handleAdjustment returns `needAllowance = true` for EVERY non-zero
 *      adjustment (risk-core/src/assets/WrappedERC20Asset.sol:125), where CashAsset returns
 *      `amount < 0` (CashAsset.sol:392). SubAccounts spends allowance on the credit side too
 *      (SubAccounts.sol:401-403), and Matching only transfers the subaccounts NAMED IN THE ACTIONS
 *      to the module (Matching.sol:89-97) -- never the fee recipient. So the moment a fee is
 *      non-zero, TradeModule's fee transfer reverts unless the fee-recipient subaccount's owner has
 *      granted this module a positive allowance on the wrapped quote asset.
 *
 *      This is only expressible if the fee-recipient subaccount is held by an address that can call
 *      setAssetAllowances. A subaccount deposited into Matching cannot: Matching exposes no such
 *      call. The script reads ownerOf(feeRecipient) and refuses to pretend otherwise.
 *
 * @dev THE OLD MODULE IS DELIBERATELY LEFT ENABLED. The cash-quoted TradeModule also carries the
 *      SEP-16-2026 deliverable FX future (DEPLOYED_ADDRESSES.md); disabling it would take the
 *      futures market down with the spot migration. Migration is done by pointing
 *      services/execution and services/markets at the new TRADE_MODULE_ADDRESS, not by revoking
 *      the old one.
 *
 * Usage:
 *   PRIVATE_KEY=... FEE_RECIPIENT=1 MATCHING_OWNER=0x1dcA... \
 *     forge script scripts/deploy-wrapped-quote-trade-module.s.sol --rpc-url $BASE_RPC_URL --broadcast
 */
contract DeployWrappedQuoteTradeModule is Utils {
  string internal constant ARTIFACT_NAME = "TRADE_MODULE_WRAPPED_USDC_QUOTE";
  string internal constant VAULT_ACTIONS_NAME = "WRAPPED_QUOTE_TRADE_VAULT_ACTIONS";

  /// @dev the wrapped-USDC allowance granted to the module on the fee-recipient subaccount.
  ///      Allowance is consumed as it is spent, so this is a budget, not a switch: it has to be
  ///      topped up. Sized well above any plausible fee take between top-ups.
  uint internal constant FEE_ALLOWANCE = 1_000_000e18;

  function run() external {
    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);

    Matching matching = Matching(_matchingAddress());
    address wrappedUsdc = _wrappedUsdcAddress();
    ISubAccounts subAccounts = ISubAccounts(_coreAddress("subAccounts"));
    address srm = _coreAddress("srm");
    address cash = _coreAddress("cash");

    uint feeRecipient = vm.envOr("FEE_RECIPIENT", uint(1));
    address vault = vm.envOr("MATCHING_OWNER", IOwned(address(matching)).owner());

    _checkPreconditions(matching, subAccounts, wrappedUsdc, cash, srm, feeRecipient, vault);

    vm.startBroadcast(deployerPrivateKey);

    TradeModule module = new TradeModule(matching, IAsset(wrappedUsdc), feeRecipient);

    address datedFuture = vm.envOr("DATED_FUTURE_ASSET", address(0));
    if (datedFuture != address(0)) {
      module.setDatedFutureAsset(datedFuture, true);
    }

    module.transferOwnership(vault);

    vm.stopBroadcast();

    // post-deploy assertions: cheap, and the failure they catch is a wrong-quote-asset module
    // sitting on a real address forever, because quoteAsset is immutable.
    require(address(module.quoteAsset()) == wrappedUsdc, "POST: quoteAsset is not the wrapped USDC asset");
    require(address(module.quoteAsset()) != cash, "POST: quoteAsset is still CashAsset");
    require(address(module.matching()) == address(matching), "POST: module points at a different Matching");
    require(module.feeRecipient() == feeRecipient, "POST: feeRecipient mismatch");
    require(IOwned(address(module)).pendingOwner() == vault, "POST: ownership handoff not initiated");

    console2.log("deployer:                 ", deployer);
    console2.log("TradeModule (wrapped USDC quote):", address(module));
    console2.log("  quoteAsset:             ", wrappedUsdc);
    console2.log("  feeRecipient subaccount:", feeRecipient);
    console2.log("  pendingOwner:           ", vault);

    _writeArtifacts(module, matching, subAccounts, wrappedUsdc, feeRecipient, vault);
  }

  // -----------------------------------------------------------------------------------------
  // preconditions
  // -----------------------------------------------------------------------------------------

  function _checkPreconditions(
    Matching matching,
    ISubAccounts subAccounts,
    address wrappedUsdc,
    address cash,
    address srm,
    uint feeRecipient,
    address vault
  ) internal view {
    require(wrappedUsdc != address(0) && wrappedUsdc.code.length > 0, "PRE: wrapped USDC asset has no code");
    require(wrappedUsdc != cash, "PRE: WRAPPED_USDC_DELIVERABLE resolves to CashAsset - wrong artifact");
    require(address(matching).code.length > 0, "PRE: matching has no code");
    require(vault != address(0), "PRE: vault is zero");

    // The manager must accept the asset as a Base asset, or every fill reverts SRM_UnsupportedAsset.
    IStandardManager.AssetDetail memory detail = IStandardManager(srm).assetDetails(IAsset(wrappedUsdc));
    require(detail.isWhitelisted, "PRE: wrapped USDC is not whitelisted on the SRM");
    require(detail.assetType == IStandardManager.AssetType.Base, "PRE: wrapped USDC is not registered as Base");

    // ...and the asset must accept the manager, or handleAdjustment reverts in the other direction.
    require(
      WrappedERC20Asset(wrappedUsdc).whitelistedManager(srm), "PRE: SRM is not a whitelisted manager on wrapped USDC"
    );

    require(feeRecipient != 0, "PRE: feeRecipient 0 cannot receive a transfer");
    address feeOwner = subAccounts.ownerOf(feeRecipient);
    require(feeOwner != address(0), "PRE: fee recipient subaccount does not exist");
    require(
      address(subAccounts.manager(feeRecipient)) == srm, "PRE: fee recipient subaccount is not managed by the SRM"
    );

    if (feeOwner == address(matching)) {
      // Not fatal: with fees at zero the trade path never touches the fee account, and
      // WrappedERC20Asset short-circuits a zero adjustment before asking for allowance. It is fatal
      // the moment a fee is turned on, so it must not be discovered then.
      console2.log("");
      console2.log("WARNING: fee recipient subaccount %s is held by Matching.", feeRecipient);
      console2.log("  Matching cannot call setAssetAllowances, so this module can never be granted the");
      console2.log("  positive allowance a wrapped-asset fee credit requires. Fees MUST stay at 0, or");
      console2.log("  setFeeRecipient() to a subaccount held by the vault before enabling them.");
      console2.log("");
    }
  }

  // -----------------------------------------------------------------------------------------
  // artifacts
  // -----------------------------------------------------------------------------------------

  function _writeArtifacts(
    TradeModule module,
    Matching matching,
    ISubAccounts subAccounts,
    address wrappedUsdc,
    uint feeRecipient,
    address vault
  ) internal {
    string memory objKey = "wrapped-quote-trade-module";
    vm.serializeAddress(objKey, "trade", address(module));
    vm.serializeAddress(objKey, "quoteAsset", wrappedUsdc);
    vm.serializeAddress(objKey, "matching", address(matching));
    vm.serializeUint(objKey, "feeRecipient", feeRecipient);
    string memory finalObj = vm.serializeAddress(objKey, "pendingOwner", vault);
    _writeToDeployments(ARTIFACT_NAME, finalObj);

    _writeVaultActions(module, matching, subAccounts, wrappedUsdc, feeRecipient);
  }

  function _writeVaultActions(
    TradeModule module,
    Matching matching,
    ISubAccounts subAccounts,
    address wrappedUsdc,
    uint feeRecipient
  ) internal {
    address[] memory to = new address[](3);
    bytes[] memory data = new bytes[](3);
    string[] memory descriptions = new string[](3);

    to[0] = address(module);
    data[0] = abi.encodeWithSignature("acceptOwnership()");
    descriptions[0] = "newTradeModule.acceptOwnership() [take custody before it can be matched on]";

    to[1] = address(matching);
    data[1] = abi.encodeWithSelector(Matching.setAllowedModule.selector, address(module), true);
    descriptions[1] =
      "matching.setAllowedModule(newTradeModule, true) [THE ENABLING SWITCH - nothing can be matched before this]";

    IAllowances.AssetAllowance[] memory allowances = new IAllowances.AssetAllowance[](1);
    allowances[0] = IAllowances.AssetAllowance({asset: IAsset(wrappedUsdc), positive: FEE_ALLOWANCE, negative: 0});
    to[2] = address(subAccounts);
    data[2] = abi.encodeWithSelector(ISubAccounts.setAssetAllowances.selector, feeRecipient, address(module), allowances);
    descriptions[2] = string.concat(
      "subAccounts.setAssetAllowances(feeRecipient, newTradeModule, +wrappedUSDC)",
      " [ONLY IF the vault owns the fee subaccount AND fees are non-zero; skip while fees are 0]"
    );

    console2.log("");
    console2.log("Vault actions (execute in order, as the vault):");

    string memory json = "[";
    for (uint i = 0; i < to.length; ++i) {
      console2.log("  [%s] %s", i, descriptions[i]);
      console2.log("      to     %s", vm.toString(to[i]));
      console2.log("      digest %s", vm.toString(keccak256(abi.encodePacked(to[i], data[i]))));
      json = string.concat(json, i == 0 ? "" : ",", _vaultAction(descriptions[i], to[i], data[i]));
    }
    json = string.concat(json, "]");

    _writeToDeployments(VAULT_ACTIONS_NAME, json);
  }

  function _vaultAction(string memory description, address to, bytes memory data)
    internal
    pure
    returns (string memory)
  {
    return string.concat(
      '{"description":"',
      description,
      '","to":"',
      vm.toString(to),
      '","value":"0","data":"',
      vm.toString(data),
      '","digest":"',
      vm.toString(keccak256(abi.encodePacked(to, data))),
      '"}'
    );
  }

  // -----------------------------------------------------------------------------------------
  // deployment file lookups
  // -----------------------------------------------------------------------------------------

  function _matchingAddress() internal view returns (address) {
    return abi.decode(vm.parseJson(_readMatchingDeploymentFile("matching"), ".matching"), (address));
  }

  function _coreAddress(string memory key) internal view returns (address) {
    return abi.decode(vm.parseJson(_readRiskCoreFile("core"), string.concat(".", key)), (address));
  }

  function _wrappedUsdcAddress() internal view returns (address) {
    return abi.decode(vm.parseJson(_readRiskCoreFile("WRAPPED_USDC_DELIVERABLE"), ".base"), (address));
  }

  /// @dev risk-core's deployments live at contracts/risk-core/deployments, reachable through the
  ///      committed `v2-core` symlink. Utils._readV2CoreDeploymentFile still points at the
  ///      pre-monorepo `../../exchange-core` layout, so prefer the symlink and fall back.
  function _readRiskCoreFile(string memory name) internal view returns (string memory) {
    string memory linked = string.concat(
      vm.projectRoot(), "/v2-core/deployments/", vm.toString(block.chainid), "/", name, ".json"
    );
    if (vm.exists(linked)) return vm.readFile(linked);
    return _readV2CoreDeploymentFile(name);
  }
}
