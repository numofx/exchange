// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IForwardFeed} from "v2-core/src/interfaces/IForwardFeed.sol";
import {ISpotFeed} from "v2-core/src/interfaces/ISpotFeed.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IVolFeed} from "v2-core/src/interfaces/IVolFeed.sol";
import {IWrappedERC20Asset} from "v2-core/src/interfaces/IWrappedERC20Asset.sol";
import {StandardManager} from "v2-core/src/risk-managers/StandardManager.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";

import {Matching} from "../src/Matching.sol";
import {TradeModule} from "../src/modules/TradeModule.sol";
import {IMatching} from "../src/interfaces/IMatching.sol";
import {Utils} from "./utils.sol";

/**
 * @title DeployWrappedQuoteTradeModule
 *
 * @dev Deploys a second TradeModule for the USDCcNGN-SPOT book whose `quoteAsset` is the existing
 *      WrappedERC20Asset over USDC (WRAPPED_USDC_DELIVERABLE) instead of the CashAsset, so that
 *      both legs of a fill are wrapped-token transfers and the settlement ledger is out of the
 *      trade path. The cNGN leg already works this way; this makes the USDC leg match.
 *
 * @dev WHY THIS IS SAFE TO DEPLOY. TradeModule holds the quote asset as a plain `IAsset`
 *      (TradeModule.sol:32) and only ever moves it through ISubAccounts.AssetTransfer at subId 0
 *      (TradeModule.sol:145-152, 224-232, 244-251). There is no ICashAsset cast, no interest
 *      accrual hook and no settlement call anywhere in the module or in Matching. The sibling
 *      RfqModule DOES take an ICashAsset in its constructor and is deliberately not touched here.
 *
 * @dev WHY IT IS NOT SUFFICIENT TO DEPLOY. Two things break if only the module is swapped, and
 *      both are emitted below as vault actions rather than left to be discovered in production:
 *
 *      1. FEES. WrappedERC20Asset.handleAdjustment returns needAllowance = true on the CREDIT side
 *         as well as the debit side (WrappedERC20Asset.sol:124-125), where CashAsset returns it
 *         only on the debit side. The module owns the two trading subaccounts while it executes,
 *         but never the fee recipient, so a non-zero fee has to spend an allowance the fee account
 *         granted in advance. The live module's feeRecipient is subaccount 1, whose ownerOf() and
 *         manager() are both the SRM contract — which exposes no call that reaches
 *         setAssetAllowances, so subaccount 1 can never grant one. This script therefore REFUSES a
 *         contract-owned fee recipient and emits the grant as action 3.
 *
 *         Maker and taker fees are "0" today (services/markets/internal/matching/executor.go:23,32).
 *         That makes the defect latent, not absent: it surfaces on the first non-zero fee.
 *
 *      2. ORACLE LIVENESS. Every fill puts wrapped USDC in both accounts, so SRM market 1 is now
 *         read on every margin check (StandardManager.sol:443, 770-772). spotFeeds[1] is still the
 *         live LyraSpotFeed with a 3600s heartbeat that the book was deliberately moved off when
 *         the static feeds were deployed (scripts/deploy-cngn-spot-static-feeds.s.sol:24-29, in
 *         risk-core). Leaving it there re-introduces a keeper gap as a book-wide halt. Action 2
 *         repoints market 1 at the static stable feed that already exists on chain.
 *
 * @dev What this script does NOT do: it does not disable the existing cash-quoted module. Both
 *      would then be allowlisted at once, which the markets service cannot express — it pins one
 *      module per market and rejects orders naming any other (internal/api/orders.go). Sequence the
 *      cutover as: drain the book, point QUOTE/TRADE config at the new module, redeploy markets,
 *      then setAllowedModule(old, false).
 *
 * Usage (deploy + emit the vault batch):
 *   PRIVATE_KEY=<deployer> FEE_RECIPIENT_SUBACCOUNT=<id> \
 *     forge script scripts/deploy-wrapped-quote-trade-module.s.sol \
 *       --rpc-url $BASE_RPC_URL --broadcast
 *
 * Optional env:
 *   MATCHING_OWNER          hand the module to the vault (Ownable2Step: sets pendingOwner only)
 *   QUOTE_ASSET             override the wrapped quote asset (default: WRAPPED_USDC_DELIVERABLE)
 *   STABLE_STATIC_FEED      override the static feed for action 2 (default: from CNGN_SPOT_STATIC_FEEDS)
 *   SKIP_ORACLE_ACTION=true omit action 2 (only if market 1 already points at a static feed)
 */
contract DeployWrappedQuoteTradeModule is Utils {
  string internal constant ARTIFACT_NAME = "WRAPPED_QUOTE_TRADE_MODULE";
  string internal constant VAULT_ACTIONS_NAME = "WRAPPED_QUOTE_TRADE_MODULE_VAULT_ACTIONS";

  address internal matchingAddr;
  address internal subAccountsAddr;
  address internal srmAddr;
  address internal quoteAsset;
  address internal staticStableFeed;
  uint internal quoteMarketId;
  uint internal feeRecipient;

  function run() external {
    _loadAddresses();
    _assertPreconditions();

    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    TradeModule module = new TradeModule(IMatching(matchingAddr), IAsset(quoteAsset), feeRecipient);

    address newOwner = vm.envOr("MATCHING_OWNER", address(0));
    if (newOwner != address(0)) module.transferOwnership(newOwner);

    vm.stopBroadcast();

    _assertPostconditions(module);
    _writeArtifacts(module);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function _loadAddresses() internal {
    string memory matchingJson = _readMatchingDeploymentFile("matching");
    matchingAddr = vm.parseJsonAddress(matchingJson, ".matching");

    string memory coreJson = _readRiskCoreDeploymentFile("core");
    subAccountsAddr = vm.parseJsonAddress(coreJson, ".subAccounts");
    srmAddr = vm.parseJsonAddress(coreJson, ".srm");

    quoteAsset = vm.envOr("QUOTE_ASSET", address(0));
    if (quoteAsset == address(0)) {
      quoteAsset = vm.parseJsonAddress(_readRiskCoreDeploymentFile("WRAPPED_USDC_DELIVERABLE"), ".base");
    }

    staticStableFeed = vm.envOr("STABLE_STATIC_FEED", address(0));
    if (staticStableFeed == address(0) && !vm.envOr("SKIP_ORACLE_ACTION", false)) {
      staticStableFeed =
        vm.parseJsonAddress(_readRiskCoreDeploymentFile("CNGN_SPOT_STATIC_FEEDS"), ".stableStaticSpotFeed");
    }

    // No default. The live module's feeRecipient (subaccount 1) is SRM-owned and cannot grant the
    // allowance a wrapped quote needs, so silently inheriting it would ship the latent revert.
    feeRecipient = vm.envUint("FEE_RECIPIENT_SUBACCOUNT");
  }

  // ---------------------------------------------------------------------------------------------
  // preconditions — every one of these is a way the module deploys fine and then cannot trade
  // ---------------------------------------------------------------------------------------------

  function _assertPreconditions() internal {
    if (matchingAddr.code.length == 0) revert("matching has no code - wrong chain?");
    if (quoteAsset.code.length == 0) revert("quote asset has no code");

    ISubAccounts subAccounts = ISubAccounts(subAccountsAddr);
    StandardManager srm = StandardManager(srmAddr);

    // the quote asset must accept the SRM as a manager, or every adjustment reverts in
    // ManagerWhitelist._checkManager
    if (!WrappedERC20Asset(quoteAsset).whitelistedManager(srmAddr)) {
      revert("quote asset does not whitelist the SRM");
    }

    // and the SRM must recognise the asset, or handleAdjustment reverts SRM_UnsupportedAsset
    IStandardManager.AssetDetail memory detail = srm.assetDetails(IAsset(quoteAsset));
    if (!detail.isWhitelisted) revert("quote asset is not whitelisted on the SRM");
    if (detail.assetType != IStandardManager.AssetType.Base) revert("quote asset is not registered as Base");
    quoteMarketId = detail.marketId;

    // the market must have a spot feed at all: _getMarketMargin reads it on every fill
    (ISpotFeed spotFeed,,) = srm.getMarketFeeds(quoteMarketId);
    if (address(spotFeed) == address(0)) revert("quote market has no spot feed");

    // THE FEE PRECONDITION. A contract-owned fee recipient can never grant the positive allowance
    // that a wrapped quote asset requires on the credit side, so a non-zero fee would be
    // permanently unfillable. Catch it here rather than on the first fee-bearing trade.
    if (feeRecipient == 0) revert("FEE_RECIPIENT_SUBACCOUNT must be set");
    address feeOwner = subAccounts.ownerOf(feeRecipient);
    if (feeOwner.code.length != 0) {
      console2.log("fee recipient subaccount:", feeRecipient);
      console2.log("its owner:", feeOwner);
      revert("fee recipient is contract-owned and can never grant an allowance - use an EOA-owned subaccount");
    }
    if (address(subAccounts.manager(feeRecipient)) != srmAddr) {
      revert("fee recipient is not managed by the SRM");
    }

    console2.log("matching:      ", matchingAddr);
    console2.log("quote asset:   ", quoteAsset);
    console2.log("quote marketId:", quoteMarketId);
    console2.log("fee recipient: ", feeRecipient);
    console2.log("fee owner:     ", feeOwner);
  }

  function _assertPostconditions(TradeModule module) internal view {
    if (address(module.quoteAsset()) != quoteAsset) revert("quoteAsset mismatch");
    if (module.feeRecipient() != feeRecipient) revert("feeRecipient mismatch");
    if (address(module.matching()) != matchingAddr) revert("matching mismatch");
    if (Matching(matchingAddr).allowedModules(address(module))) {
      revert("module is already allowlisted - it must be inert until the vault batch runs");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // vault actions — every call below is onlyOwner on a vault-owned contract, or must be made by
  // the fee account's owner, so none of them can be broadcast by the deployer key
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(TradeModule module) internal {
    string memory objKey = "wrapped-quote-trade-module";
    vm.serializeAddress(objKey, "tradeWrappedQuote", address(module));
    vm.serializeAddress(objKey, "quoteAsset", quoteAsset);
    vm.serializeAddress(objKey, "matching", matchingAddr);
    vm.serializeUint(objKey, "quoteMarketId", quoteMarketId);
    string memory finalObj = vm.serializeUint(objKey, "feeRecipient", feeRecipient);
    _writeToDeployments(ARTIFACT_NAME, finalObj);

    _writeToDeployments(VAULT_ACTIONS_NAME, _serialiseVaultActions(module));

    console2.log("");
    console2.log("TRADE_MODULE_ADDRESS=%s", address(module));
    console2.log("QUOTE_ASSET_ADDRESS=%s", quoteAsset);
    console2.log("");
    console2.log("The module is inert until action 1 executes. Run the batch IN ORDER, as the");
    console2.log("stated caller, and only after the book has been drained of old-module orders.");
  }

  function _serialiseVaultActions(TradeModule module) internal view returns (string memory) {
    bool skipOracle = vm.envOr("SKIP_ORACLE_ACTION", false);
    uint count = skipOracle ? 2 : 3;

    address[] memory to = new address[](count);
    bytes[] memory data = new bytes[](count);
    string[] memory who = new string[](count);
    string[] memory descriptions = new string[](count);

    uint i;

    // 1. THE ENABLING SWITCH. Nothing can route to the module before this.
    to[i] = matchingAddr;
    data[i] = abi.encodeCall(Matching.setAllowedModule, (address(module), true));
    who[i] = "matching owner (vault)";
    descriptions[i] = "matching.setAllowedModule(tradeWrappedQuote, true) [THE ENABLING SWITCH]";
    i++;

    // 2. Liveness. Without this a 3600s keeper gap on the live stable feed halts every fill,
    //    because holding wrapped USDC now puts market 1 in every portfolio.
    if (!skipOracle) {
      to[i] = srmAddr;
      data[i] = abi.encodeCall(
        StandardManager.setOraclesForMarket,
        (quoteMarketId, ISpotFeed(staticStableFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
      );
      who[i] = "srm owner (vault)";
      descriptions[i] =
        "srm.setOraclesForMarket(quoteMarketId, staticStableFeed) [removes the 3600s staleness halt from the quote leg]";
      i++;
    }

    // 3. Fees. type(uint).max rather than a budget: allowances are decremented on every spend
    //    (Allowances.sol:142-149), so a finite grant is a scheduled outage.
    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(quoteAsset), positive: type(uint).max, negative: 0});

    to[i] = subAccountsAddr;
    data[i] = abi.encodeCall(ISubAccounts.setAssetAllowances, (feeRecipient, address(module), grant));
    who[i] = "fee recipient subaccount owner";
    descriptions[i] =
      "subAccounts.setAssetAllowances(feeRecipient, tradeWrappedQuote, +max quote) [without this every non-zero-fee fill reverts]";

    string memory json = "[";
    for (uint j = 0; j < count; ++j) {
      console2.log("  [%s] %s", j, descriptions[j]);
      console2.log("      to     %s", vm.toString(to[j]));
      console2.log("      as     %s", who[j]);
      console2.log("      digest %s", vm.toString(keccak256(abi.encodePacked(to[j], data[j]))));
      json = string.concat(json, j == 0 ? "" : ",", _vaultAction(descriptions[j], who[j], to[j], data[j]));
    }
    return string.concat(json, "]");
  }

  function _vaultAction(string memory description, string memory caller, address to, bytes memory data)
    internal
    pure
    returns (string memory)
  {
    return string.concat(
      '{"description":"',
      description,
      '","caller":"',
      caller,
      '","to":"',
      vm.toString(to),
      '","value":"0","data":"',
      vm.toString(data),
      '","digest":"',
      vm.toString(keccak256(abi.encodePacked(to, data))),
      '"}'
    );
  }

  /// @dev risk-core deployments. Utils._readV2CoreDeploymentFile still points at the pre-monorepo
  ///      `../../exchange-core` path, which does not exist in this repo; ../risk-core is the same
  ///      subtree the ./v2-core symlink resolves to, and is on the fs_permissions read list.
  function _readRiskCoreDeploymentFile(string memory fileName) internal view returns (string memory) {
    return vm.readFile(
      string.concat(vm.projectRoot(), "/../risk-core/deployments/", vm.toString(block.chainid), "/", fileName, ".json")
    );
  }
}
