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

import {Ownable2Step} from "openzeppelin/access/Ownable2Step.sol";

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
 *         setAssetAllowances, so subaccount 1 can never grant one. This script therefore requires
 *         the fee recipient to be owned by the vault itself, and emits the grant as action 3 —
 *         which is then a call the same signer that runs actions 1 and 2 can make. It refuses a
 *         contract-owned id and, separately, an id owned by any other EOA: subaccount ids are
 *         sequential and permissionless, so the id you resolved off chain can be taken by someone
 *         else's createAccount before your own transaction mines, and `quoteAsset`/`feeRecipient`
 *         are immutable, so wiring the wrong one in burns the deployment.
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
 *   (no feed override, and no SKIP_ORACLE_ACTION: the static feed comes from
 *    CNGN_SPOT_STATIC_FEEDS and the oracle action is emitted only when chain says it is needed)
 */
contract DeployWrappedQuoteTradeModule is Utils {
  string internal constant ARTIFACT_NAME = "WRAPPED_QUOTE_TRADE_MODULE";
  string internal constant VAULT_ACTIONS_NAME = "WRAPPED_QUOTE_TRADE_MODULE_VAULT_ACTIONS";

  /// @dev The vault recorded in risk-core/DEPLOYED_ADDRESSES.md, Base mainnet. This is an ANCHOR,
  ///      not a lookup, exactly as scripts/cngn-spot-batch.sol:51 uses it: the owner is read from
  ///      chain and compared against this, never adopted as the new truth. Deriving the vault from
  ///      whoever happens to own Matching would mean an ownership change is silently accepted.
  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  address internal matchingAddr;
  address internal subAccountsAddr;
  address internal srmAddr;
  address internal quoteAsset;
  address internal staticStableFeed;
  address internal vault;
  address internal deployer;
  uint internal quoteMarketId;
  uint internal feeRecipient;

  function run() external {
    _loadAddresses();
    _assertPreconditions();

    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    deployer = vm.addr(deployerPrivateKey);
    vm.startBroadcast(deployerPrivateKey);

    TradeModule module = new TradeModule(IMatching(matchingAddr), IAsset(quoteAsset), feeRecipient);

    // BaseModule is Ownable2Step and its constructor is Ownable(msg.sender), so the module is
    // born owned by the deployer EOA. transferOwnership only sets pendingOwner; the vault must
    // acceptOwnership, which is emitted as action 0 of the batch.
    //
    // This is not optional and must not be. onlyOwner on this module includes
    // setDatedFutureAsset, and TradeModule._addAssetTransfers sets amtQuote = 0 for a dated
    // future. _fillLimitOrder validates fill.price against the signed limit and never looks at
    // amtQuote, so an owner who flags the base asset can take the base leg of any resting order
    // for zero payment, through the ordinary venue, past the signed price guard.
    module.transferOwnership(vault);

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

    // No override. STABLE_STATIC_FEED used to accept an arbitrary address with no code check, no
    // getSpot() probe and no comparison against the recorded deployment -- while the same function
    // carefully validates matchingAddr and quoteAsset. setOraclesForMarket(quoteMarketId, garbage)
    // bricks the margin path for every account holding the quote asset, which after cutover is
    // every account. The artifact is the only source.
    staticStableFeed =
      vm.parseJsonAddress(_readRiskCoreDeploymentFile("CNGN_SPOT_STATIC_FEEDS"), ".stableStaticSpotFeed");
    if (staticStableFeed.code.length == 0) revert("static stable feed has no code");
    (uint feedPrice,) = ISpotFeed(staticStableFeed).getSpot();
    if (feedPrice == 0) revert("static stable feed returns a zero price");

    // No default. The live module's feeRecipient (subaccount 1) is SRM-owned and cannot grant the
    // allowance a wrapped quote needs, so silently inheriting it would ship the latent revert.
    // It must name an account the VAULT already owns; see _assertFeeRecipient for why an id you
    // only expect to own is not good enough.
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

    // THE VAULT. Read from chain and pinned to the recorded address rather than adopted, so a
    // change of ownership stops the deployment instead of being written into the vault batch. It
    // is also the address every fee-recipient check below is made against.
    vault = Matching(matchingAddr).owner();
    if (vault == address(0)) revert("matching owner is zero");
    if (vault != EXPECTED_VAULT) revert("matching owner is not the recorded vault - ownership changed");
    if (srm.owner() != vault) revert("matching and the srm have different owners");

    _assertFeeRecipient(subAccounts, feeRecipient, vault, srmAddr);

    console2.log("matching:      ", matchingAddr);
    console2.log("quote asset:   ", quoteAsset);
    console2.log("quote marketId:", quoteMarketId);
    console2.log("vault:         ", vault);
    console2.log("fee recipient: ", feeRecipient);
  }

  /**
   * @dev THE FEE PRECONDITION. `TradeModule.quoteAsset` and `feeRecipient` are both immutable
   *      (TradeModule.sol:32,35), so a fee recipient that cannot grant the module a positive
   *      allowance on the quote asset burns the deployment: the module has to be redeployed, and
   *      the whole vault batch reissued.
   *
   * @dev Two distinct ways to get the wrong account, kept as two distinct messages because they
   *      have different fixes:
   *
   *      1. CONTRACT-OWNED. Subaccount 1 -- the live module's feeRecipient -- is owned and managed
   *         by the SRM, which exposes no call reaching setAssetAllowances. This is the one someone
   *         actually hits, by passing the id the live module already uses.
   *
   *      2. OWNED BY THE WRONG EOA. `subAccounts.createAccount` is permissionless and ids are
   *         sequential and global (SubAccounts.sol: ++lastAccountId), so between reading
   *         `lastAccountId` off chain and mining the transaction that creates the intended fee
   *         account, someone else's createAccount can take the id. A raced id passes
   *         `code.length == 0`, and passes the manager check too if that account happens to sit
   *         under the SRM -- so the old code-length test alone would have waved it through, and
   *         action 3 of the vault batch would then be a call only a stranger can make. Requiring
   *         the owner to BE the vault is what makes the emitted batch signable by the vault that
   *         signs actions 1 and 2.
   *
   * @dev Parameterised rather than reading the contract's own fields, so
   *      test/scripts/WrappedQuoteDeployPreconditions.t.sol can drive it against a real SubAccounts
   *      without a fork.
   */
  function _assertFeeRecipient(
    ISubAccounts subAccounts,
    uint feeAccount,
    address expectedOwner,
    address expectedManager
  ) internal view {
    if (feeAccount == 0) revert("FEE_RECIPIENT_SUBACCOUNT must be set");

    address feeOwner = subAccounts.ownerOf(feeAccount);
    console2.log("fee recipient subaccount:", feeAccount);
    console2.log("its owner:", feeOwner);

    if (feeOwner.code.length != 0) {
      revert("fee recipient is contract-owned and can never grant an allowance - use a vault-owned subaccount");
    }
    if (feeOwner != expectedOwner) {
      console2.log("expected owner (vault):", expectedOwner);
      revert("fee recipient is not owned by the vault - wrong id, or the id was raced by another createAccount");
    }
    if (address(subAccounts.manager(feeAccount)) != expectedManager) {
      revert("fee recipient is not managed by the SRM");
    }

    // Fees are zero at cutover, and this still matters. TradeModule appends the fee transfer
    // unconditionally (TradeModule.sol:147-154) and SubAccounts._transferAsset reverts
    // AC_CannotTransferAssetToOneself when fromAcc == toAcc, so a fee recipient that is also a
    // trading subaccount bricks every fill it takes part in -- at any fee, including 0. Cheap to
    // assert here and impossible to fix later: feeRecipient is set in the constructor.
    if (subAccounts.getAccountBalances(feeAccount).length != 0) {
      revert("fee recipient already holds assets - use a dedicated account, not a trading one");
    }
  }

  function _assertPostconditions(TradeModule module) internal view {
    if (address(module.quoteAsset()) != quoteAsset) revert("quoteAsset mismatch");
    if (module.feeRecipient() != feeRecipient) revert("feeRecipient mismatch");
    if (address(module.matching()) != matchingAddr) revert("matching mismatch");
    if (Matching(matchingAddr).allowedModules(address(module))) {
      revert("module is already allowlisted - it must be inert until the vault batch runs");
    }

    _assertOwnershipOffered(module, vault, deployer);
  }

  /// @dev Ownership. The deployer still holds owner() at this point -- Ownable2Step hands over only
  ///      on acceptOwnership -- but pendingOwner must already be the vault, or the batch's action 0
  ///      cannot succeed and the module would go live under the deployer key. Parameterised so a
  ///      test can drive this exact code rather than a restatement of it.
  function _assertOwnershipOffered(TradeModule module, address expectedVault, address expectedDeployer)
    internal
    view
  {
    if (module.pendingOwner() != expectedVault) {
      revert("pendingOwner is not the vault - ownership was not offered");
    }
    if (module.owner() != expectedDeployer) {
      revert("owner is not the deployer - unexpected ownership state");
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
    // Derived from chain, not from SKIP_ORACLE_ACTION. The market-1 repoint already landed
    // (blocks 51097293/51097344), so emitting it again produced an onlyOwner no-op carrying the
    // description "removes the 3600s staleness halt" -- a statement untrue of the chain the signer
    // signs against. Handing an MPC signer an action whose description misstates its effect trains
    // the signer to skim, which is the opposite of what an irreversible batch needs.
    (ISpotFeed currentSpot,,) = StandardManager(srmAddr).getMarketFeeds(quoteMarketId);
    bool skipOracle = address(currentSpot) == staticStableFeed;
    uint count = skipOracle ? 3 : 4;

    address[] memory to = new address[](count);
    bytes[] memory data = new bytes[](count);
    string[] memory who = new string[](count);
    string[] memory descriptions = new string[](count);

    uint i;

    // 0. CUSTODY, AND IT MUST BE FIRST. Until the vault accepts, owner() is the deployer EOA,
    //    which can call setDatedFutureAsset and make every subsequent fill pay zero quote (see
    //    the note in run()). Allowlisting a module the deployer still owns would open that
    //    window on a live venue, so custody is settled before the enabling switch, not after.
    to[i] = address(module);
    data[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
    who[i] = "module pendingOwner (vault)";
    descriptions[i] =
      "tradeWrappedQuote.acceptOwnership() [CUSTODY - must land before the enabling switch below]";
    i++;

    // 1. FEES, BEFORE THE SWITCH. The runbook ordering wins over the old emitted order, which put
    //    this last. type(uint).max rather than a budget: allowances are decremented on every spend
    //    (Allowances.sol:142-149), so a finite grant is a scheduled outage.
    //
    //    Harmless at today's zero fees, but the safe order costs nothing and the batch should not
    //    contradict the runbook the same operator is following.
    {
      IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
      grant[0] = IAllowances.AssetAllowance({asset: IAsset(quoteAsset), positive: type(uint).max, negative: 0});
      to[i] = subAccountsAddr;
      data[i] = abi.encodeCall(ISubAccounts.setAssetAllowances, (feeRecipient, address(module), grant));
      who[i] = "fee recipient subaccount owner (vault)";
      descriptions[i] =
        "subAccounts.setAssetAllowances(feeRecipient, tradeWrappedQuote, +max quote) [before the switch: without it every non-zero-fee fill reverts]";
      i++;
    }

    // 2. THE ENABLING SWITCH. Nothing can route to the module before this.
    to[i] = matchingAddr;
    data[i] = abi.encodeCall(Matching.setAllowedModule, (address(module), true));
    who[i] = "matching owner (vault)";
    descriptions[i] = "matching.setAllowedModule(tradeWrappedQuote, true) [THE ENABLING SWITCH]";
    i++;

    // 3. Liveness, and only when chain says it is still needed. Without it a keeper gap on a live
    //    stable feed halts every fill, because holding the quote asset puts its market in every
    //    portfolio.
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
