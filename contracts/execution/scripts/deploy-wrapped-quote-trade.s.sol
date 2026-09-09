// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {Matching} from "../src/Matching.sol";
import {TradeModule} from "../src/modules/TradeModule.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";

import {Utils} from "./utils.sol";

interface IERC20BasedAssetView {
  function wrappedAsset() external view returns (address);
}

interface IOwnedView {
  function owner() external view returns (address);
}

/**
 * @title DeployWrappedQuoteTradeModule
 *
 * @notice Deploys a second TradeModule whose `quoteAsset` is a WrappedERC20Asset (wrapped USDC)
 *         instead of the CashAsset, so both legs of a USDC/cNGN spot fill are transfers of tokens
 *         the protocol actually custodies and the cash settlement ledger is out of the trade path.
 *
 * @dev `quoteAsset` is immutable on TradeModule, so this is a new deployment, not an upgrade. The
 *      old cash-quoted module keeps its own `filled`/`seenNonces` state and its own EIP-712 identity
 *      (ACTION_TYPEHASH commits to `module`), so an order signed for one is not a valid order for
 *      the other. They cannot cross-fill on chain; keeping them from crossing in the ORDER BOOK is
 *      an offchain concern -- see the module-address check in services/markets.
 *
 * @dev Deploying is permissionless; wiring it up is not. Matching, and the fee subaccount, are
 *      vault-owned, so the two follow-up calls are written to
 *      deployments/{chainId}/WRAPPED_QUOTE_TRADE_VAULT_ACTIONS.json for the vault to execute.
 *
 * @dev THE FEE ALLOWANCE IS NOT OPTIONAL. WrappedERC20Asset.handleAdjustment returns
 *      `needAllowance = true` for EVERY adjustment, including credits, where CashAsset returns
 *      `adjustment.amount < 0`. The fee subaccount is not one of the signed actions, so the module
 *      does not own it and cannot bypass the allowance. A non-zero fee therefore reverts the whole
 *      batch unless the fee subaccount has granted this module a positive allowance for the quote
 *      asset. Fees are hardcoded to "0" in services/markets today, which is why a missing allowance
 *      would go unnoticed until the day fees are switched on.
 *
 * Usage:
 *   QUOTE_ASSET=0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 \
 *   FEE_RECIPIENT=<subaccount id> \
 *   PRIVATE_KEY=... \
 *   forge script scripts/deploy-wrapped-quote-trade.s.sol --rpc-url $BASE_RPC_URL --broadcast
 *
 * Dry run (no --broadcast) still performs every precondition read.
 */
contract DeployWrappedQuoteTradeModule is Utils {
  string internal constant ARTIFACT_NAME = "WRAPPED_QUOTE_TRADE_VAULT_ACTIONS";

  function run() external {
    address quoteAsset = vm.envAddress("QUOTE_ASSET");
    uint feeRecipient = vm.envUint("FEE_RECIPIENT");

    Matching matching = Matching(_resolveMatching());
    ISubAccounts subAccounts = matching.subAccounts();

    _assertPreconditions(matching, subAccounts, quoteAsset, feeRecipient);

    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    TradeModule trade = new TradeModule(matching, IAsset(quoteAsset), feeRecipient);

    // Register a deliverable FX (dated) future so VM-blended fills price correctly, matching
    // deploy-all.s.sol. Optional; set DATED_FUTURE_ASSET to enable.
    address datedFuture = vm.envOr("DATED_FUTURE_ASSET", address(0));
    if (datedFuture != address(0)) trade.setDatedFutureAsset(datedFuture, true);

    // Ownable2Step: this only sets pendingOwner; the vault must acceptOwnership().
    address newOwner = vm.envOr("MATCHING_OWNER", address(0));
    if (newOwner != address(0)) trade.transferOwnership(newOwner);

    vm.stopBroadcast();

    _writeDeployment(address(trade), quoteAsset, feeRecipient);
    _writeVaultActions(address(matching), address(subAccounts), address(trade), quoteAsset, feeRecipient);

    console2.log("");
    console2.log("wrapped-quote TradeModule:", address(trade));
    console2.log("  quoteAsset  ", quoteAsset);
    console2.log("  feeRecipient", feeRecipient);
    console2.log("");
    console2.log("NOT YET LIVE. The vault must execute both actions in %s.json.", ARTIFACT_NAME);
    console2.log("Until setAllowedModule lands, Matching rejects this module with M_OnlyAllowedModule.");
    console2.log("Until setAssetAllowances lands, any NON-ZERO fee reverts the whole batch.");
  }

  /// @dev matching.json is the source of truth; MATCHING_ADDRESS overrides it for a fresh chain
  function _resolveMatching() internal view returns (address matching) {
    matching = vm.envOr("MATCHING_ADDRESS", address(0));
    if (matching != address(0)) return matching;

    matching = abi.decode(vm.parseJson(_readMatchingDeploymentFile("matching"), ".matching"), (address));
    if (matching == address(0)) revert("matching address unresolved: set MATCHING_ADDRESS");
  }

  /**
   * @dev Every check here is a read against live chain state, not a restatement of the config.
   *      Getting any of them wrong produces a module that deploys fine and then reverts every fill.
   */
  function _assertPreconditions(
    Matching matching,
    ISubAccounts subAccounts,
    address quoteAsset,
    uint feeRecipient
  ) internal view {
    if (address(matching).code.length == 0) revert("matching has no code - wrong chain or address");
    if (quoteAsset.code.length == 0) revert("QUOTE_ASSET has no code - wrong chain or address");
    if (feeRecipient == 0) revert("FEE_RECIPIENT must be a real subaccount: TradeModule always emits a fee transfer");

    // The whole point of the change: the quote leg must be a token-backed wrapper, not the ledger.
    address underlying = IERC20BasedAssetView(quoteAsset).wrappedAsset();
    if (underlying == address(0)) revert("QUOTE_ASSET.wrappedAsset() is zero - not an ERC20-backed asset");
    console2.log("quote asset wraps:", underlying);

    // The fee subaccount must be able to GRANT an allowance. A subaccount held by Matching cannot:
    // Matching exposes no setAssetAllowances, so the credit can never be authorised and every
    // fee-bearing fill would revert. Production's default fee recipient (subaccount 1) is owned by
    // the SecurityModule, which has the same problem.
    address feeOwner = subAccounts.ownerOf(feeRecipient);
    if (feeOwner == address(matching)) {
      revert("FEE_RECIPIENT is held by Matching and can never grant the module an allowance");
    }
    if (feeOwner.code.length != 0) {
      console2.log("WARNING: FEE_RECIPIENT owner is a contract:", feeOwner);
      console2.log("  It must expose a way to call subAccounts.setAssetAllowances or approve.");
      console2.log("  SecurityModule does NOT. Point FEE_RECIPIENT at a vault-owned subaccount.");
    }
    console2.log("fee subaccount owner:", feeOwner);

    // A live module with this exact quote asset already wired in would mean two books on one pair.
    address existingTrade = vm.envOr("EXISTING_TRADE_MODULE", address(0));
    if (existingTrade != address(0)) {
      address existingQuote = address(TradeModule(existingTrade).quoteAsset());
      if (existingQuote == quoteAsset) revert("a module with this quoteAsset is already deployed");
      console2.log("existing module quote asset (stays live until cutover):", existingQuote);
    }

    console2.log("preconditions ok against live chain state");
  }

  function _writeDeployment(address trade, address quoteAsset, uint feeRecipient) internal {
    string memory objKey = "wrapped-quote-trade";
    vm.serializeAddress(objKey, "trade", trade);
    vm.serializeAddress(objKey, "quoteAsset", quoteAsset);
    string memory finalObj = vm.serializeUint(objKey, "feeRecipient", feeRecipient);
    _writeToDeployments("matching-wrapped-quote", finalObj);
  }

  /**
   * @dev Both calls are onlyOwner / owner-gated on vault-owned contracts, so the deployer cannot
   *      make them. Written as calldata for the vault to execute IN ORDER.
   */
  function _writeVaultActions(
    address matching,
    address subAccounts,
    address trade,
    address quoteAsset,
    uint feeRecipient
  ) internal {
    IAllowances.AssetAllowance[] memory allowances = new IAllowances.AssetAllowance[](1);
    allowances[0] = IAllowances.AssetAllowance({asset: IAsset(quoteAsset), positive: type(uint).max, negative: 0});

    address[] memory to = new address[](2);
    bytes[] memory data = new bytes[](2);
    string[] memory descriptions = new string[](2);

    to[0] = matching;
    data[0] = abi.encodeCall(Matching.setAllowedModule, (trade, true));
    descriptions[0] = "matching.setAllowedModule(wrappedQuoteTrade, true)";

    to[1] = subAccounts;
    data[1] = abi.encodeCall(IAllowances.setAssetAllowances, (feeRecipient, trade, allowances));
    descriptions[1] =
      "subAccounts.setAssetAllowances(feeRecipient, wrappedQuoteTrade, [+max quoteAsset]) - MUST be sent by the fee subaccount owner";

    string memory json = "[";
    console2.log("");
    for (uint i = 0; i < to.length; ++i) {
      console2.log("  [%s] %s", i, descriptions[i]);
      console2.log("      to     %s", vm.toString(to[i]));
      console2.log("      digest %s", vm.toString(keccak256(abi.encodePacked(to[i], data[i]))));
      json = string.concat(
        json,
        i == 0 ? "" : ",",
        "{\"description\":\"",
        descriptions[i],
        "\",\"to\":\"",
        vm.toString(to[i]),
        "\",\"data\":\"",
        vm.toString(data[i]),
        "\"}"
      );
    }
    _writeToDeployments(ARTIFACT_NAME, string.concat(json, "]"));
  }
}
