// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../src/SubAccounts.sol";
import {SecurityModule} from "../src/SecurityModule.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {PerpAsset} from "../src/assets/PerpAsset.sol";
import {InterestRateModel} from "../src/assets/InterestRateModel.sol";
import {DutchAuction} from "../src/liquidation/DutchAuction.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {SRMPortfolioViewer} from "../src/risk-managers/SRMPortfolioViewer.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {LyraSpotDiffFeed} from "../src/feeds/LyraSpotDiffFeed.sol";
import {LyraStaticSpotFeed} from "../src/feeds/static/LyraStaticSpotFeed.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {IManager} from "../src/interfaces/IManager.sol";

import {Utils, IOwnable2Step} from "./utils.sol";
import "./config-mainnet.sol";

/**
 * @title DeployCngnPerpStack
 *
 * @dev A USDC-settled NGN perpetual on its own Lyra-style stack, beside the legacy one rather than
 *      inside it. The legacy SRM's cashAsset is the CashAsset 0x6B232A…, which holds ~2 USDC
 *      against far larger claims; every perp PnL, funding and OI-fee transfer on an SRM moves in
 *      its cashAsset (BaseManager._applyCashDelta), so a perp there would pay winners in cash that
 *      cannot be redeemed. This stack gets a NEW CashAsset over real Base USDC, and with it its own
 *      SRM, viewer, SecurityModule and DutchAuction. The legacy SRM is never called.
 *
 *      It reuses the live SubAccounts (from core.json): Matching is bound to it, and a separate
 *      ledger would need a separate venue.
 *
 *      test/fork/CngnPerpStackFork.t.sol is the phase-0 evidence that the insolvency path works on
 *      a stack shaped like this one; CngnPerpStackDeployFork.t.sol runs THIS script's deployment.
 *
 * @dev DENOMINATION. The perp is priced in USD per NGN (~0.00072) and sized in NGN (1e18 = 1 NGN),
 *      so PnL lands in USD cash with no conversion. The venue displays the inverse (NGN per USD)
 *      with long/short flipped; that translation lives in markets-service, not here.
 *
 * @dev FEEDS. The index is a LyraSpotFeed signed by FEED_SIGNER — the revived cNGN signer, fed by
 *      the rate-picker index publisher. Mark and the two impact prices are LyraSpotDiffFeeds on that
 *      index, published from the venue's own book, and must be pushed to the feeds directly or through
 *      a TradeModule's managerData: SubAccounts runs the perp's adjustment, which reads them, before
 *      the SRM processes managerData on a raw transfer. They are still whitelisted SRM callees. A feed that goes stale makes getSpot revert,
 *      which halts margin checks — trading AND liquidation — until it is refreshed. That is the
 *      intended fail-closed behaviour of a publisher that refuses to publish bad data.
 *
 * @dev OWNERSHIP. Everything is configured by the deployer first, then nominated to the vault
 *      (Ownable2Step: pendingOwner only). The vault must accept each; the calls are written to
 *      CNGN_PERP_STACK_VAULT_ACTIONS.json. After acceptance, every change is a vault transaction,
 *      which is why nothing is left for later here.
 *
 * Usage:
 *   PRIVATE_KEY=<deployer> FEED_SIGNER=<revived cNGN signer> \
 *     forge script scripts/deploy-cngn-perp-stack.s.sol --rpc-url $BASE_RPC_URL --broadcast
 *
 * Optional env:
 *   PERP_OI_CAP   the cap the ENABLE action opens the market to, NGN 18dp (default 50,000,000). It
 *                 sums |position| over BOTH sides, so 50M allows 25M NGN of OI (≈ $18k at 0.00072).
 *                 The stack itself deploys with a cap of 0: closed to every path, not just Matching.
 */
contract DeployCngnPerpStack is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_PERP_STACK";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_PERP_STACK_VAULT_ACTIONS";
  string internal constant MARKET_NAME = "NGN";

  /// @dev The vault recorded in DEPLOYED_ADDRESSES.md. An anchor, not a lookup: it is compared
  ///      against the legacy SRM's owner, never derived from it.
  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  /// @dev Launch cap. Low on purpose: raise it by vault transaction once the market has history.
  ///      PositionTracking sums |position| over longs and shorts, so this is twice the OI it allows.
  uint internal constant DEFAULT_PERP_OI_CAP = 50_000_000e18;

  /// @dev The index is a 15-minute TWAP republished every few minutes; a 20-minute heartbeat
  ///      tolerates one missed publish before the market halts.
  uint64 internal constant INDEX_HEARTBEAT = 20 minutes;

  /// @dev A USDC stable feed pinned at 1. The SRM reads it for its depeg penalty only; a live one
  ///      would add a keeper whose silence halts the book, for a risk this venue does not price.
  uint internal constant STABLE_PRICE = 1e18;

  struct Params {
    address subAccounts;
    address usdc;
    address vault;
    address feedSigner;
    uint perpOICap;
  }

  struct Stack {
    InterestRateModel rateModel;
    CashAsset cash;
    SRMPortfolioViewer viewer;
    StandardManager srm;
    SecurityModule securityModule;
    DutchAuction auction;
    LyraStaticSpotFeed stableFeed;
    LyraSpotFeed indexFeed;
    LyraSpotDiffFeed markFeed;
    LyraSpotDiffFeed impactAskFeed;
    LyraSpotDiffFeed impactBidFeed;
    PerpAsset perp;
    uint marketId;
    uint feeRecipientAccount;
  }

  function run() external {
    Params memory params = _loadParams();

    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);
    Stack memory stack = deployStack(params);
    vm.stopBroadcast();

    assertStack(stack, params, vm.addr(deployerPrivateKey));
    _writeArtifacts(stack, params.perpOICap);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function _loadParams() internal view returns (Params memory params) {
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.usdc = vm.parseJsonAddress(_readDeploymentFile("shared"), ".usdc");
    params.feedSigner = vm.envAddress("FEED_SIGNER");
    params.perpOICap = vm.envOr("PERP_OI_CAP", DEFAULT_PERP_OI_CAP);

    // The vault is pinned, then confirmed against the chain: if the legacy SRM has changed hands,
    // stop, rather than nominate a new stack to an address nobody re-verified.
    address legacySrm = vm.parseJsonAddress(_readDeploymentFile("core"), ".srm");
    params.vault = EXPECTED_VAULT;
    if (StandardManager(legacySrm).owner() != params.vault) revert("legacy srm owner is not the recorded vault");

    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    if (params.usdc.code.length == 0) revert("usdc has no code");
    if (IERC20Metadata(params.usdc).decimals() != 6) revert("usdc is not 6 decimals");
    if (params.feedSigner == address(0)) revert("FEED_SIGNER is zero");
    if (params.perpOICap == 0) revert("PERP_OI_CAP is zero");
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deployStack(Params memory params) public returns (Stack memory stack) {
    _deployCore(stack, params);
    _deployFeeds(stack, params);
    _deployPerp(stack, params);
    _registerMarket(stack);

    // The TradeModule's fee account. It must sit under THIS SRM (the new cash only whitelists it)
    // and belong to the vault. Created here and its id read back from the call, not predicted:
    // ids are sequential and permissionless, so an id resolved off chain can be taken first.
    stack.feeRecipientAccount =
      SubAccounts(params.subAccounts).createAccount(params.vault, IManager(address(stack.srm)));

    _nominateVault(stack, params.vault);
  }

  function _deployCore(Stack memory stack, Params memory params) internal {
    (uint minRate, uint rateMultiplier, uint highRateMultiplier, uint optimalUtil) =
      Config.getDefaultInterestRateModel();
    SubAccounts subAccounts = SubAccounts(params.subAccounts);

    stack.rateModel = new InterestRateModel(minRate, rateMultiplier, highRateMultiplier, optimalUtil);
    stack.cash = new CashAsset(subAccounts, IERC20Metadata(params.usdc), stack.rateModel);
    stack.viewer = new SRMPortfolioViewer(subAccounts, stack.cash);
    stack.srm = new StandardManager(subAccounts, stack.cash, IDutchAuction(address(0)), stack.viewer);
    stack.securityModule = new SecurityModule(subAccounts, stack.cash, stack.srm);
    stack.auction = new DutchAuction(subAccounts, stack.securityModule, stack.cash);
    stack.srm.setLiquidation(stack.auction);

    stack.stableFeed = new LyraStaticSpotFeed();
    stack.stableFeed.setSpot(STABLE_PRICE, 1e18);

    stack.viewer.setStandardManager(stack.srm);

    stack.auction.setSMAccount(stack.securityModule.accountId());
    stack.auction.setWhitelistManager(address(stack.srm), true);
    stack.auction.setAuctionParams(Config.getDefaultAuctionParam());

    stack.cash.setLiquidationModule(stack.auction);
    stack.cash.setSmFeeRecipient(stack.securityModule.accountId());
    stack.cash.setSmFee(Config.CASH_SM_FEE);
    stack.cash.setWhitelistManager(address(stack.srm), true);

    stack.securityModule.setWhitelistModule(address(stack.auction), true);

    stack.srm.setMaxAccountSize(Config.MAX_ACCOUNT_SIZE_SRM);
    stack.srm.setBorrowingEnabled(true);
    stack.srm.setStableFeed(stack.stableFeed);
    stack.srm.setDepegParameters(Config.getSRMDepegParams());
  }

  function _deployFeeds(Stack memory stack, Params memory params) internal {
    stack.indexFeed = new LyraSpotFeed();
    stack.markFeed = new LyraSpotDiffFeed(stack.indexFeed);
    stack.impactAskFeed = new LyraSpotDiffFeed(stack.indexFeed);
    stack.impactBidFeed = new LyraSpotDiffFeed(stack.indexFeed);

    stack.indexFeed.setHeartbeat(INDEX_HEARTBEAT);
    stack.markFeed.setHeartbeat(Config.PERP_HEARTBEAT);
    stack.impactAskFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    stack.impactBidFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);

    // The mark can sit at most 6% from the index, however thin the book behind it.
    stack.markFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
    stack.impactAskFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
    stack.impactBidFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);

    stack.indexFeed.addSigner(params.feedSigner, true);
    stack.markFeed.addSigner(params.feedSigner, true);
    stack.impactAskFeed.addSigner(params.feedSigner, true);
    stack.impactBidFeed.addSigner(params.feedSigner, true);
    stack.indexFeed.setRequiredSigners(1);
    stack.markFeed.setRequiredSigners(1);
    stack.impactAskFeed.setRequiredSigners(1);
    stack.impactBidFeed.setRequiredSigners(1);
  }

  function _deployPerp(Stack memory stack, Params memory params) internal {
    (int staticInterestRate, int fundingRateCap, uint convergencePeriod) = Config.getPerpParams();

    stack.perp = new PerpAsset(SubAccounts(params.subAccounts));
    stack.perp.setSpotFeed(stack.indexFeed);
    stack.perp.setPerpFeed(stack.markFeed);
    stack.perp.setImpactFeeds(stack.impactAskFeed, stack.impactBidFeed);
    stack.perp.setStaticInterestRate(staticInterestRate);
    stack.perp.setRateBounds(fundingRateCap);
    stack.perp.setConvergencePeriod(convergencePeriod);
    stack.perp.setWhitelistManager(address(stack.srm), true);
    // Closed at deploy. The cap is the only switch that stops EVERY path to a position -- Matching
    // allowlisting gates the venue, but two accounts under this SRM can move perp between themselves
    // with SubAccounts.submitTransfers the moment the feeds are live. Opening it (to params.perpOICap)
    // is the final enable action, proposed by propose_perp_enable_batch.py once its gates pass.
    stack.perp.setTotalPositionCap(stack.srm, 0);
  }

  function _registerMarket(Stack memory stack) internal {
    stack.marketId = stack.srm.createMarket(MARKET_NAME);

    (
      IStandardManager.PerpMarginRequirements memory perpReqs,,
      IStandardManager.OracleContingencyParams memory oracleContingency,
    ) = Config.getSRMParams(MARKET_NAME);

    stack.srm.whitelistAsset(stack.perp, stack.marketId, IStandardManager.AssetType.Perpetual);
    stack.srm.setOraclesForMarket(stack.marketId, stack.indexFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    stack.srm.setPerpMarginRequirements(stack.marketId, perpReqs.mmPerpReq, perpReqs.imPerpReq);
    stack.srm.setOracleContingencyParams(stack.marketId, oracleContingency);

    // No OI fee at launch: the TradeModule's taker fee is the venue's fee. Set explicitly so the
    // artifact states it rather than inheriting a default.
    stack.viewer.setOIFeeRateBPS(address(stack.perp), 0);

    stack.srm.setWhitelistedCallee(address(stack.indexFeed), true);
    stack.srm.setWhitelistedCallee(address(stack.markFeed), true);
    stack.srm.setWhitelistedCallee(address(stack.impactAskFeed), true);
    stack.srm.setWhitelistedCallee(address(stack.impactBidFeed), true);
  }

  function _nominateVault(Stack memory stack, address vault) internal {
    address[] memory owned = ownedContracts(stack);
    for (uint i = 0; i < owned.length; i++) {
      IOwnable2Step(owned[i]).transferOwnership(vault);
    }
  }

  /// @dev Every Ownable2Step contract the stack deploys. InterestRateModel has no owner.
  function ownedContracts(Stack memory stack) public pure returns (address[] memory owned) {
    owned = new address[](11);
    owned[0] = address(stack.cash);
    owned[1] = address(stack.viewer);
    owned[2] = address(stack.srm);
    owned[3] = address(stack.securityModule);
    owned[4] = address(stack.auction);
    owned[5] = address(stack.stableFeed);
    owned[6] = address(stack.indexFeed);
    owned[7] = address(stack.markFeed);
    owned[8] = address(stack.impactAskFeed);
    owned[9] = address(stack.impactBidFeed);
    owned[10] = address(stack.perp);
  }

  // ---------------------------------------------------------------------------------------------
  // postconditions — each is a way the stack deploys and then cannot trade, or cannot be governed
  // ---------------------------------------------------------------------------------------------

  function assertStack(Stack memory stack, Params memory params, address deployer) public view {
    address[] memory owned = ownedContracts(stack);
    for (uint i = 0; i < owned.length; i++) {
      if (IOwnable2Step(owned[i]).pendingOwner() != params.vault) revert("contract not nominated to vault");
    }

    // The fee account belongs to the vault and sits under the new SRM.
    SubAccounts subAccounts = SubAccounts(params.subAccounts);
    if (subAccounts.ownerOf(stack.feeRecipientAccount) != params.vault) revert("fee account not vault-owned");
    if (address(subAccounts.manager(stack.feeRecipientAccount)) != address(stack.srm)) {
      revert("fee account not under the new srm");
    }

    // Cash is real USDC, wired to this stack's auction and security module.
    if (address(stack.cash.wrappedAsset()) != params.usdc) revert("cash does not wrap usdc");
    if (address(stack.srm.cashAsset()) != address(stack.cash)) revert("srm cash is not the new cash");
    if (address(stack.srm.liquidation()) != address(stack.auction)) revert("srm liquidation not wired");
    if (!stack.srm.borrowingEnabled()) revert("borrowing not enabled");
    if (!stack.securityModule.isWhitelisted(address(stack.auction))) revert("auction cannot draw on sm");

    // The signer is the only one on every feed, and the deployer signs nothing.
    if (!stack.indexFeed.isSigner(params.feedSigner)) revert("index feed missing signer");
    if (!stack.markFeed.isSigner(params.feedSigner)) revert("mark feed missing signer");
    if (stack.indexFeed.isSigner(deployer) || stack.markFeed.isSigner(deployer)) revert("deployer is a feed signer");

    // The market reads the index, and the perp only this manager.
    (address spot,,) = _marketFeeds(stack);
    if (spot != address(stack.indexFeed)) revert("market index feed not set");
    if (!stack.perp.whitelistedManager(address(stack.srm))) revert("perp does not whitelist the srm");
    if (stack.perp.totalPositionCap(stack.srm) != 0) revert("perp must deploy closed (cap 0)");
  }

  function _marketFeeds(Stack memory stack) internal view returns (address spot, address fwd, address vol) {
    (spot, fwd, vol) = abi.decode(
      _staticcall(address(stack.srm), abi.encodeWithSignature("getMarketFeeds(uint256)", stack.marketId)),
      (address, address, address)
    );
  }

  function _staticcall(address target, bytes memory data) internal view returns (bytes memory) {
    (bool ok, bytes memory result) = target.staticcall(data);
    if (!ok) revert("staticcall failed");
    return result;
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Stack memory stack, uint launchCap) internal {
    string memory obj = "cngn-perp-stack";
    vm.serializeAddress(obj, "rateModel", address(stack.rateModel));
    vm.serializeAddress(obj, "cash", address(stack.cash));
    vm.serializeAddress(obj, "srmViewer", address(stack.viewer));
    vm.serializeAddress(obj, "srm", address(stack.srm));
    vm.serializeAddress(obj, "securityModule", address(stack.securityModule));
    vm.serializeAddress(obj, "auction", address(stack.auction));
    vm.serializeAddress(obj, "stableFeed", address(stack.stableFeed));
    vm.serializeAddress(obj, "indexFeed", address(stack.indexFeed));
    vm.serializeAddress(obj, "markFeed", address(stack.markFeed));
    vm.serializeAddress(obj, "impactAskFeed", address(stack.impactAskFeed));
    vm.serializeAddress(obj, "impactBidFeed", address(stack.impactBidFeed));
    vm.serializeAddress(obj, "perp", address(stack.perp));
    vm.serializeUint(obj, "marketId", stack.marketId);
    vm.serializeUint(obj, "launchOICap", launchCap);
    vm.serializeUint(obj, "securityModuleAccount", stack.securityModule.accountId());
    string memory json = vm.serializeUint(obj, "feeRecipientAccount", stack.feeRecipientAccount);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(stack));
  }

  /// @dev acceptOwnership on every nominated contract, in the recorded vault-action format.
  function vaultActionsJson(Stack memory stack) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(stack);
    bytes memory data = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(
        json,
        i == 0 ? "" : ",",
        '{"description":"acceptOwnership() [cNGN perp stack]","to":"',
        vm.toString(owned[i]),
        '","value":"0","data":"',
        vm.toString(data),
        '","digest":"',
        vm.toString(keccak256(abi.encodePacked(owned[i], keccak256(data)))),
        '"}'
      );
    }
    json = string.concat(json, "]");
  }
}
