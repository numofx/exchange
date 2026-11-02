// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {OptionAsset} from "../src/assets/OptionAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {LyraVolFeed} from "../src/feeds/LyraVolFeed.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {LyraForwardFeed} from "../src/feeds/LyraForwardFeed.sol";
import {FutureFixingSettlementFeed} from "../src/feeds/FutureFixingSettlementFeed.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleOptions {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
  function isPerpAsset(address asset) external view returns (bool);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

/**
 * @title DeployCngnOptionsV2
 *
 * @dev cNGN-USDC options on the live MarginEngine v2 (deployments/8453/MARGIN_ENGINE_V2.json), on market 1 (NGN), at the
 *      expiry of v2's cNGN future (30NOV26). Deploys an OptionAsset, a LyraVolFeed and a FutureFixingSettlementFeed,
 *      nominates the first two to the vault (the settlement feed is ownerless), and writes the vault's batches.
 *      test/fork/CngnOptionsV2Fork.t.sol runs this script's own deploy and batches against the live engine.
 *
 * @dev UNITS. American terms throughout, as v2: strikes, premiums and settlement in USDC per cNGN, one option unit (1e18)
 *      one cNGN. Strikes are stored to 1e-8 USDC (OptionEncoding). The forward is the cNGN future's LyraForwardFeed and
 *      settlement is that future's own settlement price, so an option can never settle away from the future.
 *
 * @dev VAULT_ACTIONS: accept the option and the vol feed; whitelist the option on market 1; set market 1's option margin
 *      and oracle contingency params; set market 1's oracles. Opens nothing (the option's cap stays 0).
 *      ENABLE_VAULT_ACTIONS: the option's cap. No TradeModule action: an asset that is neither perp nor dated future
 *      already fills as price x amount in cash, which is an option premium.
 *
 * @dev TWO ACTIONS REWRITE LIVE SETTINGS, and are built from what market 1 reads at deploy:
 *        setOraclesForMarket(1, spot, forward, vol) sets all three: `spot` must be the live cNGN index, or every cNGN
 *          spot and future account stops margining;
 *        setOracleContingencyParams(1, ...) sets all four: perp and base thresholds and OCFactor are copied from the
 *          engine, only the option threshold is new. OCFactor is shared with perp and base on this market.
 *      checkParams refuses a deploy against anything else; propose_cngn_options_v2_batch.py re-reads both before each
 *      action and refuses if market 1 has moved since.
 *
 * @dev MARGIN PARAMETERS ARE CANDIDATES, NOT DECISIONS (2026-11-01). The defaults are what the fork test proves: a naked
 *      ATM put written at IM stays solvent through a 25% devaluation step with vol doubled (+$57 on $722), and fails at
 *      10-12% spot add-ons. Sign off, or override by env, before broadcasting.
 *
 * Usage (a fresh keystore account, used for this deploy only, or a used one named in USED_DEPLOYER):
 *   VOL_SIGNER=<vol key address> forge script scripts/deploy-cngn-options-v2.s.sol --rpc-url $BASE_RPC_URL \
 *     --account <fresh keystore> --broadcast
 *
 * Optional env: VOL_HEARTBEAT, OPTION_OI_CAP, OPTION_THRESHOLD, MAX_SPOT_REQ, MIN_SPOT_REQ, MM_CALL_SPOT_REQ,
 * MM_PUT_SPOT_REQ, MM_PUT_MTM_REQ, UNPAIRED_IM_SCALE, UNPAIRED_MM_SCALE, MM_OFFSET_SCALE, USED_DEPLOYER.
 */
contract DeployCngnOptionsV2 is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_OPTIONS_V2";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_OPTIONS_V2_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "CNGN_OPTIONS_V2_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev The NGN market: v2's cNGN spot and cNGN-30NOV26.
  uint internal constant MARKET_ID = 1;

  /// @dev The vol feed refuses data older than this; option accounts stop margining (and being liquidated) past it.
  uint64 internal constant DEFAULT_VOL_HEARTBEAT = 30 minutes;
  /// @dev cNGN of options over both sides (the cap sums |balance|): 1M cNGN a side, ~$728 at 0.000728. Decided 2026-11-01
  ///      (the user's "about 2.2M", cut to 2.0M because 2.2M did not fit): a 15% step on that side, taken linearly (an
  ///      option's delta is at most 1), costs the SecurityModule ~$109 of the ~$119 it has left after cNGN-30NOV26 and
  ///      EURC-30NOV26 at their caps. The enable gate re-reads it, and refuses once the index is above ~0.000791.
  uint internal constant DEFAULT_OPTION_OI_CAP = 2_000_000e18;
  /// @dev Confidence under this costs IM (never MM): the vol publisher's "degrade" mode. CANDIDATE. The live value is
  ///      0.55 (2026-11-01).
  uint internal constant DEFAULT_OPTION_THRESHOLD = 0.8e18;

  // CANDIDATES (see the contract notes): IM 25-30% of spot on a naked short, MM 15%.
  uint internal constant DEFAULT_MAX_SPOT_REQ = 0.3e18;
  uint internal constant DEFAULT_MIN_SPOT_REQ = 0.25e18;
  uint internal constant DEFAULT_MM_CALL_SPOT_REQ = 0.15e18;
  uint internal constant DEFAULT_MM_PUT_SPOT_REQ = 0.15e18;
  uint internal constant DEFAULT_MM_PUT_MTM_REQ = 0.5e18;
  uint internal constant DEFAULT_UNPAIRED_IM_SCALE = 1.2e18;
  uint internal constant DEFAULT_UNPAIRED_MM_SCALE = 1.1e18;
  uint internal constant DEFAULT_MM_OFFSET_SCALE = 1.05e18;

  /// @dev Floors against a unit slip (0.25 for 25%, not 25e16 / 1e18) and against the 10-12% add-ons the fork test
  ///      shows go bankrupt on a 25% step.
  uint internal constant MIN_IM_SPOT_REQ = 0.2e18;
  uint internal constant MIN_MM_SPOT_REQ = 0.1e18;
  /// @dev USD per cNGN the index may read: about 1/2000 to 1/700 NGN per USD.
  uint internal constant MIN_INDEX = 0.0002e18;
  uint internal constant MAX_INDEX = 0.0015e18;

  struct Params {
    address subAccounts;
    address vault;
    address engine;
    address viewer;
    address cash;
    address tradeModule;
    /// @dev market 1's spot feed, the cNGN index, read live and checked against MARGIN_ENGINE_V2.json
    address indexFeed;
    /// @dev v2's cNGN future and its forward feed: the options' forward and settlement
    address future;
    address forwardFeed;
    uint64 expiry;
    address volSigner;
    uint64 volHeartbeat;
    uint optionOICap;
    IMarginEngine.OptionMarginParams margin;
    IMarginEngine.OracleContingencyParams oc;
  }

  struct Deployment {
    OptionAsset option;
    LyraVolFeed volFeed;
    FutureFixingSettlementFeed settlement;
  }

  function run() external {
    Params memory params = loadParams();
    checkDeployer(params, msg.sender, vm.getNonce(msg.sender), vm.envOr("USED_DEPLOYER", address(0)));

    vm.startBroadcast();
    Deployment memory d = deploy(params);
    vm.stopBroadcast();

    assertDeployment(d, params);
    _writeArtifacts(d, params);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function loadParams() public view returns (Params memory params) {
    params = loadChainParams();
    params.volSigner = vm.envAddress("VOL_SIGNER");
    params.volHeartbeat = uint64(vm.envOr("VOL_HEARTBEAT", uint(params.volHeartbeat)));
    params.optionOICap = vm.envOr("OPTION_OI_CAP", params.optionOICap);
    params.oc.optionThreshold = vm.envOr("OPTION_THRESHOLD", params.oc.optionThreshold);
    params.margin.maxSpotReq = vm.envOr("MAX_SPOT_REQ", params.margin.maxSpotReq);
    params.margin.minSpotReq = vm.envOr("MIN_SPOT_REQ", params.margin.minSpotReq);
    params.margin.mmCallSpotReq = vm.envOr("MM_CALL_SPOT_REQ", params.margin.mmCallSpotReq);
    params.margin.mmPutSpotReq = vm.envOr("MM_PUT_SPOT_REQ", params.margin.mmPutSpotReq);
    params.margin.MMPutMtMReq = vm.envOr("MM_PUT_MTM_REQ", params.margin.MMPutMtMReq);
    params.margin.unpairedIMScale = vm.envOr("UNPAIRED_IM_SCALE", params.margin.unpairedIMScale);
    params.margin.unpairedMMScale = vm.envOr("UNPAIRED_MM_SCALE", params.margin.unpairedMMScale);
    params.margin.mmOffsetScale = vm.envOr("MM_OFFSET_SCALE", params.margin.mmOffsetScale);
    checkParams(params);
  }

  /// @dev Everything read from the chain and the artifacts, with the defaults; no environment, no checks. The fork test
  ///      builds on this. Market 1's live spot feed and contingency params are what the batch writes back.
  function loadChainParams() public view returns (Params memory params) {
    string memory v2 = _readDeploymentFile("MARGIN_ENGINE_V2");
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.engine = vm.parseJsonAddress(v2, ".manager");
    params.viewer = vm.parseJsonAddress(v2, ".viewer");
    params.cash = vm.parseJsonAddress(v2, ".cash");
    params.tradeModule = vm.parseJsonAddress(v2, ".tradeModule");
    params.future = vm.parseJsonAddress(v2, ".future");
    params.expiry = uint64(vm.parseJsonUint(v2, ".expiry"));

    MarginEngine engine = MarginEngine(params.engine);
    (ISpotFeed spot,,) = engine.getMarketFeeds(MARKET_ID);
    params.indexFeed = address(spot);
    params.forwardFeed = address(FutureAsset(params.future).forwardFeed());

    params.volHeartbeat = DEFAULT_VOL_HEARTBEAT;
    params.optionOICap = DEFAULT_OPTION_OI_CAP;
    params.margin = IMarginEngine.OptionMarginParams({
      maxSpotReq: DEFAULT_MAX_SPOT_REQ,
      minSpotReq: DEFAULT_MIN_SPOT_REQ,
      mmCallSpotReq: DEFAULT_MM_CALL_SPOT_REQ,
      mmPutSpotReq: DEFAULT_MM_PUT_SPOT_REQ,
      MMPutMtMReq: DEFAULT_MM_PUT_MTM_REQ,
      unpairedIMScale: DEFAULT_UNPAIRED_IM_SCALE,
      unpairedMMScale: DEFAULT_UNPAIRED_MM_SCALE,
      mmOffsetScale: DEFAULT_MM_OFFSET_SCALE
    });
    (uint perpT,, uint baseT, uint factor) = engine.oracleContingencyParams(MARKET_ID);
    params.oc = IMarginEngine.OracleContingencyParams({
      perpThreshold: perpT, optionThreshold: DEFAULT_OPTION_THRESHOLD, baseThreshold: baseT, OCFactor: factor
    });
  }

  function checkDeployer(Params memory params, address deployer, uint nonce, address usedDeployer) public view {
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");
    if (nonce > 1 && deployer != usedDeployer) {
      revert("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)");
    }
    if (deployer == params.vault) revert("deployer is the vault");
    if (deployer == params.volSigner) revert("deployer signs the vol");
    if (LyraSpotFeed(params.indexFeed).isSigner(deployer)) revert("deployer signs the index");
    if (LyraForwardFeed(params.forwardFeed).isSigner(deployer)) revert("deployer signs the forward");
  }

  /// @dev Each check is a way the deployment lands and then cannot be attached, margin, trade or settle, or a way the
  ///      batch would change what live markets read.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    MarginEngine engine = MarginEngine(params.engine);
    string memory v2 = _readDeploymentFile("MARGIN_ENGINE_V2");
    if (engine.owner() != params.vault) revert("v2 engine is not owned by the vault");
    if (engine.lastMarketId() != 2) revert("v2 must list exactly NGN and EUR");
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the artifact's");
    if (address(engine.viewer()) != params.viewer) revert("engine viewer is not the artifact's");

    // market 1 as it is: the batch writes its spot feed and contingency params back
    (ISpotFeed spot,,) = engine.getMarketFeeds(MARKET_ID);
    if (params.indexFeed != address(spot)) {
      revert("INDEX is not market 1's live spot feed: the batch would replace it");
    }
    if (params.indexFeed != vm.parseJsonAddress(v2, ".indexFeed")) {
      revert("market 1's spot feed is not the cNGN index");
    }
    (uint perpT,, uint baseT, uint factor) = engine.oracleContingencyParams(MARKET_ID);
    if (params.oc.perpThreshold != perpT || params.oc.baseThreshold != baseT || params.oc.OCFactor != factor) {
      revert("contingency params: perp, base and OCFactor must be market 1's live values");
    }
    if (params.oc.optionThreshold == 0 || params.oc.optionThreshold >= 1e18) revert("OPTION_THRESHOLD out of (0, 1)");
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Option)) != address(0)) {
      revert("market 1 already lists an option");
    }

    // the future the options settle against
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future)) != params.future) {
      revert("market 1's future is not v2's cNGN future");
    }
    IFutureAsset.FutureContract memory c = IFutureAsset(params.future).futureContracts(params.expiry);
    if (!c.listed || c.expiry != params.expiry) revert("the future does not list EXPIRY");
    if (c.settled) revert("the future at EXPIRY has settled");
    if (params.expiry <= block.timestamp + 1 days) revert("expiry too soon");
    if (address(FutureAsset(params.future).forwardFeed()) != params.forwardFeed) {
      revert("FORWARD is not the future's forward feed");
    }
    if (address(LyraForwardFeed(params.forwardFeed).spotFeed()) != params.indexFeed) {
      revert("the forward feed is not on the index");
    }
    (uint index,) = ISpotFeed(params.indexFeed).getSpot();
    if (index < MIN_INDEX || index > MAX_INDEX) revert("index is not a USD per cNGN price");

    // the venue: no TradeModule action, so check it fills an unregistered asset against v2 cash
    if (ITradeModuleOptions(params.tradeModule).quoteAsset() != params.cash) {
      revert("trade module quote is not the cash");
    }
    if (ITradeModuleOptions(params.tradeModule).owner() != params.vault) revert("trade module is not the vault's");
    if (engine.trustedRiskAssessor(params.tradeModule)) {
      revert("the TradeModule is a trusted assessor: venue writers would be held to MM, not IM");
    }

    // margin: the engine's own bounds, then ours
    IMarginEngine.OptionMarginParams memory m = params.margin;
    if (
      m.maxSpotReq > 1.2e18 || m.minSpotReq > 1.2e18 || m.mmCallSpotReq > 1e18 || m.mmPutSpotReq > 1e18
        || m.MMPutMtMReq > 1e18 || m.unpairedMMScale < 1e18 || m.unpairedMMScale > 3e18 || m.unpairedIMScale < 1e18
        || m.unpairedIMScale > 3e18 || m.mmOffsetScale < 1e18 || m.mmOffsetScale > 3e18
    ) revert("option margin params outside the engine's bounds");
    if (m.minSpotReq < MIN_IM_SPOT_REQ || m.maxSpotReq < m.minSpotReq) {
      revert("IM spot add-ons: need 20% <= MIN_SPOT_REQ <= MAX_SPOT_REQ (18dp: 0.25e18 for 25%)");
    }
    if (m.mmCallSpotReq < MIN_MM_SPOT_REQ || m.mmPutSpotReq < MIN_MM_SPOT_REQ) {
      revert("MM spot add-ons under 10%: give them 18dp (0.15e18 for 15%)");
    }
    if (m.mmCallSpotReq > m.minSpotReq || m.mmPutSpotReq > m.minSpotReq) revert("MM add-on over IM's");
    if (params.optionOICap != 0 && params.optionOICap < 1e18) revert("OPTION_OI_CAP is in cNGN, 18dp");

    // the vol signer
    if (params.volSigner == address(0)) revert("VOL_SIGNER is zero");
    if (params.volSigner == params.vault) revert("VOL_SIGNER must not be the vault");
    if (LyraSpotFeed(params.indexFeed).isSigner(params.volSigner)) revert("VOL_SIGNER must not also sign the index");
    if (LyraForwardFeed(params.forwardFeed).isSigner(params.volSigner)) {
      revert("VOL_SIGNER must not also sign the forward");
    }
    if (params.volHeartbeat == 0 || params.volHeartbeat > 2 hours) revert("VOL_HEARTBEAT out of (0, 2h]");
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployment memory d) {
    MarginEngine engine = MarginEngine(params.engine);
    d.settlement = new FutureFixingSettlementFeed(IFutureAsset(params.future));
    d.option = new OptionAsset(SubAccounts(params.subAccounts), address(d.settlement));
    d.option.setWhitelistManager(address(engine), true);
    d.option.setTotalPositionCap(engine, 0);
    d.volFeed = new LyraVolFeed();
    d.volFeed.setHeartbeat(params.volHeartbeat);
    d.volFeed.addSigner(params.volSigner, true);
    d.volFeed.setRequiredSigners(1);

    d.option.transferOwnership(params.vault);
    d.volFeed.transferOwnership(params.vault);
  }

  function ownedContracts(Deployment memory d) public pure returns (address[] memory owned) {
    owned = new address[](2);
    owned[0] = address(d.option);
    owned[1] = address(d.volFeed);
  }

  // ---------------------------------------------------------------------------------------------
  // postconditions
  // ---------------------------------------------------------------------------------------------

  function assertDeployment(Deployment memory d, Params memory params) public view {
    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      if (IOwnable2Step(owned[i]).pendingOwner() != params.vault) revert("contract not nominated to vault");
    }
    MarginEngine engine = MarginEngine(params.engine);
    if (address(d.option.settlementFeed()) != address(d.settlement)) revert("option does not settle on the adapter");
    if (address(d.settlement.future()) != params.future) revert("adapter is not on the cNGN future");
    if (!d.option.whitelistedManager(address(engine))) revert("option does not whitelist the engine");
    if (d.option.totalPositionCap(engine) != 0) revert("option must deploy closed (cap 0)");
    if (!d.volFeed.isSigner(params.volSigner)) revert("vol feed missing its signer");
    if (d.volFeed.isSigner(msg.sender)) revert("deployer signs the vol feed");
    if (d.volFeed.requiredSigners() != 1) revert("vol quorum");
    if (d.volFeed.heartbeat() != params.volHeartbeat) revert("vol heartbeat");
    (bool settled,) = d.settlement.getSettlementPrice(params.expiry);
    if (settled) revert("the adapter reads EXPIRY as settled");

    // Nothing the vault owns is changed by the deployer.
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Option)) != address(0)) {
      revert("market 1 lists an option before the vault batch");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "cngn-options-v2";
    vm.serializeAddress(obj, "option", address(d.option));
    vm.serializeAddress(obj, "volFeed", address(d.volFeed));
    vm.serializeAddress(obj, "settlementFeed", address(d.settlement));
    vm.serializeAddress(obj, "volSigner", params.volSigner);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "manager", params.engine);
    vm.serializeAddress(obj, "viewer", params.viewer);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "future", params.future);
    vm.serializeAddress(obj, "forwardFeed", params.forwardFeed);
    vm.serializeUint(obj, "marketId", MARKET_ID);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeString(obj, "units", "USDC per cNGN; one option unit (1e18) is one cNGN; strikes to 1e-8 USDC");
    vm.serializeUint(obj, "volHeartbeat", params.volHeartbeat);
    vm.serializeUint(obj, "optionOICap", params.optionOICap);
    vm.serializeUint(obj, "maxSpotReq", params.margin.maxSpotReq);
    vm.serializeUint(obj, "minSpotReq", params.margin.minSpotReq);
    vm.serializeUint(obj, "mmCallSpotReq", params.margin.mmCallSpotReq);
    vm.serializeUint(obj, "mmPutSpotReq", params.margin.mmPutSpotReq);
    vm.serializeUint(obj, "MMPutMtMReq", params.margin.MMPutMtMReq);
    vm.serializeUint(obj, "unpairedIMScale", params.margin.unpairedIMScale);
    vm.serializeUint(obj, "unpairedMMScale", params.margin.unpairedMMScale);
    vm.serializeUint(obj, "mmOffsetScale", params.margin.mmOffsetScale);
    vm.serializeUint(obj, "perpThreshold", params.oc.perpThreshold);
    vm.serializeUint(obj, "optionThreshold", params.oc.optionThreshold);
    vm.serializeUint(obj, "baseThreshold", params.oc.baseThreshold);
    string memory json = vm.serializeUint(obj, "OCFactor", params.oc.OCFactor);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  /// @dev Accept the two; list the option on market 1; its margin and contingency params; market 1's oracles, with the
  ///      live spot written back. Opens nothing: the option's cap stays 0.
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = string.concat(
      "[",
      _action("acceptOwnership() [cNGN option]", owned[0], accept),
      ",",
      _action("acceptOwnership() [cNGN vol feed]", owned[1], accept),
      ",",
      _whitelistAction(d, params),
      ",",
      _marginAction(params),
      ",",
      _contingencyAction(params),
      ",",
      _oraclesAction(d, params),
      "]"
    );
  }

  function _whitelistAction(Deployment memory d, Params memory params) internal pure returns (string memory) {
    return _action(
      "engineV2.whitelistAsset(cngnOption, 1, Option) [options on the NGN market; cap 0]",
      params.engine,
      abi.encodeWithSignature(
        "whitelistAsset(address,uint256,uint8)", address(d.option), MARKET_ID, uint8(IMarginEngine.AssetType.Option)
      )
    );
  }

  function _marginAction(Params memory params) internal pure returns (string memory) {
    return _action(
      "engineV2.setOptionMarginParams(1, ...) [NGN option margin: CANDIDATE values, see the artifact]",
      params.engine,
      abi.encodeWithSignature(
        "setOptionMarginParams(uint256,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
        MARKET_ID,
        params.margin
      )
    );
  }

  function _contingencyAction(Params memory params) internal pure returns (string memory) {
    return _action(
      string.concat(
        "engineV2.setOracleContingencyParams(1, perp/base/factor as live, option ",
        vm.toString(params.oc.optionThreshold),
        ") [writes all four]"
      ),
      params.engine,
      abi.encodeWithSignature(
        "setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))", MARKET_ID, params.oc
      )
    );
  }

  function _oraclesAction(Deployment memory d, Params memory params) internal pure returns (string memory) {
    return _action(
      string.concat(
        "engineV2.setOraclesForMarket(1, ",
        vm.toString(params.indexFeed),
        " [LIVE cNGN index, unchanged], cNGN future forward, cNGN vol) [writes all three]"
      ),
      params.engine,
      abi.encodeWithSignature(
        "setOraclesForMarket(uint256,address,address,address)",
        MARKET_ID,
        params.indexFeed,
        params.forwardFeed,
        address(d.volFeed)
      )
    );
  }

  function vaultActionCount() public pure returns (uint) {
    return 6;
  }

  /// @dev Opens the option. Run last, on its own, once the vol publisher, keeper sweep and venue are live.
  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    json = string.concat(
      "[",
      _action(
        string.concat(
          "cngnOption.setTotalPositionCap(engineV2, ", vm.toString(params.optionOICap), ") [opens cNGN options]"
        ),
        address(d.option),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", params.engine, params.optionOICap)
      ),
      "]"
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 1;
  }

  /// @dev Digest is keccak(to ‖ keccak(data)), as deploy-margin-engine-v2.s.sol's.
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
}
