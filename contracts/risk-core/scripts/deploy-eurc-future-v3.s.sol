// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {StreamsIndexAdapter, IStreamsVerifierProxy} from "../src/feeds/StreamsIndexAdapter.sol";
import {EurcIndexFeed} from "../src/feeds/EurcIndexFeed.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {LyraForwardFeed} from "../src/feeds/LyraForwardFeed.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../src/interfaces/IFutureAssetV3.sol";
import {IPositionTracking} from "../src/interfaces/IPositionTracking.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {IManager} from "../src/interfaces/IManager.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleFuturesV3 {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

interface ITypeAndVersion {
  function typeAndVersion() external view returns (string memory);
}

/**
 * @title DeployEurcFutureV3
 *
 * @dev The EURC-30NOV26 pilot, Stage 1 (docs/eurc-usdc-futures-spec.md, A1.2): the new FutureAsset (A8), its
 *      StreamsIndexAdapter and EurcIndexFeed (A2.2, A2.3) and a forward feed for marks, on MarginEngine v2's market 2
 *      (EUR), traded through Matching. American terms: USDC per EURC, one contract CONTRACT_SIZE EURC, VM in USDC.
 *
 * @dev MARKET 2's ONE FUTURE SLOT. MarginEngine keeps one future per market and `whitelistAsset` replaces the holder,
 *      so the setup batch de-lists the v2 EURC-30NOV26 (retired 2026-11-15: cap 0, off the TradeModule). checkSlotFree
 *      refuses unless the holder is that series, closed and empty: no open interest, cap 0, off the TradeModule, and no
 *      account with VM pending on its series. The vault proposer re-reads the same immediately before the batch.
 *
 * @dev DEPLOYED CLOSED. Cap 0; the engine lists the future only after VAULT_ACTIONS, the TradeModule only after
 *      ENABLE_VAULT_ACTIONS. StreamsIndexAdapter and EurcIndexFeed have no owner. The future and the forward feed are
 *      nominated to the vault.
 *
 * @dev THE INDEX IS EMPTY AT DEPLOY. EurcIndexFeed reverts until a report is posted, so the initial mark is checked
 *      against the market's push feed (Chainlink EURC/USD, USD per EURC; USDC is within a fraction of a percent of
 *      $1 off a depeg). The enable gate requires a fresh index and a mark inside its band.
 *
 * @dev EXPIRY 2026-11-30 15:00 UTC (1796050800): cNGN-30NOV26 holds 14:00 and the retired series 16:00. A shared subId
 *      couples close-outs (closeOutExpired), and a recovery fixing can delay settlement by hours (A1.1).
 *
 * @dev FIXING PARAMETERS are the spec's proposals, awaiting decision (B14): feed timelock 24 h, window 30 min, max
 *      sample gap 2 min, recovery delay 1 h, index max age 60 s. Each is an env override. The OI cap has no default:
 *      exactly one of FUTURE_OI_CAP (from the A6.0a measurement) or FUTURE_OI_UNCAPPED=true. Uncapped is the owner's
 *      decision of 2026-11-15 (spec A6.0a): the cap is type(uint256).max, so open interest is bounded by nothing on
 *      chain; the SecurityModule and keeper are watched against actual open interest instead.
 *
 * Usage (a fresh keystore account, or a used one named in USED_DEPLOYER):
 *   FORWARD_SIGNER=<forward key> FUTURE_OI_UNCAPPED=true CANARY_EXPIRY=<unix, spec A1.4> forge script scripts/deploy-eurc-future-v3.s.sol \
 *     --rpc-url $BASE_RPC_URL --account <keystore> --broadcast
 */
contract DeployEurcFutureV3 is Utils {
  /// @dev The cap that never binds: no limit on open interest (spec A6.0a, decided 2026-11-15).
  uint public constant UNCAPPED = type(uint).max;
  string internal constant ARTIFACT_NAME = "EURC_FUTURE_V3";
  string internal constant VAULT_ACTIONS_NAME = "EURC_FUTURE_V3_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "EURC_FUTURE_V3_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
  uint internal constant MARKET_ID = 2;

  /// @dev Base: Data Streams verifier proxy and LINK (spec A2.1, checked on chain 2026-11-14)
  address internal constant VERIFIER_PROXY = 0xDE1A28D87Afd0f546505B28AB50410A5c3a7387a;
  address internal constant LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
  string internal constant VERIFIER_TYPE_AND_VERSION = "VerifierProxy 2.0.0";
  bytes32 internal constant EURC_USD_FEED = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 internal constant USDC_USD_FEED = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;

  /// @dev The retired v2 series that holds market 2's slot (DEPLOYED_ADDRESSES.md) and its one series
  address internal constant RETIRED_FUTURE = 0x6Ff7084D6F1760a57b9475a41F54b12279cD7744;
  uint internal constant RETIRED_SERIES = 1796054400;

  uint64 internal constant DEFAULT_EXPIRY = 1796050800;
  uint internal constant DEFAULT_CONTRACT_SIZE = 1_000e18;
  /// @dev Sized for a depeg, not EUR/USD (spec A7, decided 2026-11-15): IM 15%, MM 10%
  uint internal constant DEFAULT_FUTURE_IM_REQ = 0.15e18;
  uint internal constant DEFAULT_FUTURE_MM_REQ = 0.1e18;
  int internal constant DEFAULT_CARRY = -0.015e18;

  uint internal constant MAX_MARK_DEVIATION = 0.02e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;
  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.03e18;
  uint internal constant MIN_MARK_INDEX_DEVIATION = 0.005e18;
  uint internal constant BAND_NARROWING_PERIOD = 14 days;
  uint internal constant MIN_MARK_INTERVAL = 1 hours;
  uint64 internal constant FORWARD_HEARTBEAT = 2 hours;

  uint internal constant DEFAULT_FEED_TIMELOCK = 24 hours;
  uint internal constant DEFAULT_FIXING_WINDOW = 30 minutes;
  uint internal constant DEFAULT_MAX_SAMPLE_GAP = 2 minutes;
  uint internal constant DEFAULT_RECOVERY_DELAY = 1 hours;
  uint internal constant DEFAULT_INDEX_MAX_AGE = 60;

  /// @dev The mainnet canary (spec A1.4): a short series the deployer lists before the production one, on the same
  ///      contract, so the Stage 1 drill (a broken fixing that settles through recovery) runs against the real Data
  ///      Streams verifier in under an hour. The contract's shortest window; the production sample gap.
  uint internal constant CANARY_FIXING_WINDOW = 15 minutes;
  uint internal constant CANARY_RECOVERY_DELAY = 5 minutes;
  /// @dev Time for the vault's setup and enable batches before the canary's last trade, and an upper bound.
  uint internal constant CANARY_MIN_LEAD = 2 hours;
  uint internal constant CANARY_MAX_LEAD = 7 days;

  uint internal constant DEFAULT_INITIAL_MARK_TOLERANCE = 0.01e18;
  uint internal constant MAX_CARRY = 0.2e18;
  uint internal constant MIN_INDEX = 0.8e18;
  uint internal constant MAX_INDEX = 1.6e18;

  struct Params {
    address subAccounts;
    address vault;
    address engine;
    address cash;
    address tradeModule;
    /// @dev market 2's spot feed (Chainlink EURC/USD push): the initial mark's reference, never the index
    address referenceFeed;
    address cngnIndexFeed;
    uint poolAccount;
    uint64 expiry;
    uint64 lastTradeTime;
    uint contractSize;
    uint initialMark;
    int carry;
    uint initialMarkTolerance;
    uint imReq;
    uint mmReq;
    uint futureOICap;
    uint feedTimelock;
    uint fixingWindow;
    uint maxSampleGap;
    uint recoveryDelay;
    uint indexMaxAge;
    address forwardSigner;
    /// @dev The Data Streams verifier proxy: VERIFIER_PROXY on Base, required so by checkParams. Only the Sepolia
    ///      rehearsal (rehearse-eurc-v3-sepolia.s.sol) sets another, its stand-in.
    address verifierProxy;
    /// @dev The canary series' expiry (spec A1.4), or 0 for none. Listed before the production series.
    uint64 canaryExpiry;
    uint canaryInitialMark;
  }

  struct Deployment {
    StreamsIndexAdapter adapter;
    EurcIndexFeed indexFeed;
    FutureAsset future;
    LyraForwardFeed forwardFeed;
    uint96 subId;
    /// @dev 0 when deployed without a canary
    uint96 canarySubId;
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
    params.expiry = uint64(vm.envOr("EXPIRY", uint(params.expiry)));
    params.fixingWindow = vm.envOr("FIXING_WINDOW", params.fixingWindow);
    params.lastTradeTime = uint64(vm.envOr("LAST_TRADE_TIME", uint(params.expiry - params.fixingWindow)));
    params.contractSize = vm.envOr("CONTRACT_SIZE", params.contractSize);
    params.carry = vm.envOr("CARRY", params.carry);
    params.initialMarkTolerance = vm.envOr("INITIAL_MARK_TOLERANCE", params.initialMarkTolerance);
    params.imReq = vm.envOr("FUTURE_IM_REQ", params.imReq);
    params.mmReq = vm.envOr("FUTURE_MM_REQ", params.mmReq);
    params.futureOICap = resolveOICap(vm.envOr("FUTURE_OI_UNCAPPED", false), vm.envOr("FUTURE_OI_CAP", uint(0)));
    params.feedTimelock = vm.envOr("FEED_TIMELOCK", params.feedTimelock);
    params.maxSampleGap = vm.envOr("MAX_SAMPLE_GAP", params.maxSampleGap);
    params.recoveryDelay = vm.envOr("RECOVERY_DELAY", params.recoveryDelay);
    params.indexMaxAge = vm.envOr("INDEX_MAX_AGE", params.indexMaxAge);
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");
    params.initialMark = vm.envOr("INITIAL_MARK", fairForward(params));
    params.canaryExpiry = uint64(resolveCanary(vm.envOr("NO_CANARY", false), vm.envOr("CANARY_EXPIRY", uint(0))));
    if (params.canaryExpiry != 0) params.canaryInitialMark = canaryFairForward(params);

    checkParams(params);
  }

  /// @dev Chain reads and defaults; no environment, no checks. The fork test builds on this.
  /// @dev Exactly one of a cap or "uncapped": never a silent default either way.
  function resolveOICap(bool uncapped, uint cap) public pure returns (uint) {
    if (uncapped == (cap != 0)) revert("set exactly one of FUTURE_OI_CAP or FUTURE_OI_UNCAPPED=true");
    return uncapped ? UNCAPPED : cap;
  }

  /// @dev Exactly one of a canary expiry or NO_CANARY=true: the canary is the Stage 1 gate (spec A1.4), never dropped
  ///      by leaving a variable unset.
  function resolveCanary(bool none, uint expiry) public pure returns (uint) {
    if (none == (expiry != 0)) revert("set exactly one of CANARY_EXPIRY or NO_CANARY=true");
    return expiry;
  }

  function canaryFairForward(Params memory params) public view returns (uint) {
    Params memory c = params;
    uint64 expiry = c.expiry;
    c.expiry = params.canaryExpiry;
    uint mark = fairForward(c);
    c.expiry = expiry;
    return mark;
  }

  function loadChainParams() public view returns (Params memory params) {
    string memory v2 = _readDeploymentFile("MARGIN_ENGINE_V2");
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.engine = vm.parseJsonAddress(v2, ".manager");
    params.cash = vm.parseJsonAddress(v2, ".cash");
    params.tradeModule = vm.parseJsonAddress(v2, ".tradeModule");
    params.cngnIndexFeed = vm.parseJsonAddress(v2, ".indexFeed");

    MarginEngine engine = MarginEngine(params.engine);
    (ISpotFeed spot,,) = engine.getMarketFeeds(MARKET_ID);
    params.referenceFeed = address(spot);
    params.poolAccount = engine.accId();

    params.expiry = DEFAULT_EXPIRY;
    params.fixingWindow = DEFAULT_FIXING_WINDOW;
    params.lastTradeTime = DEFAULT_EXPIRY - uint64(DEFAULT_FIXING_WINDOW);
    params.contractSize = DEFAULT_CONTRACT_SIZE;
    params.carry = DEFAULT_CARRY;
    params.initialMarkTolerance = DEFAULT_INITIAL_MARK_TOLERANCE;
    params.verifierProxy = VERIFIER_PROXY;
    params.imReq = DEFAULT_FUTURE_IM_REQ;
    params.mmReq = DEFAULT_FUTURE_MM_REQ;
    params.feedTimelock = DEFAULT_FEED_TIMELOCK;
    params.maxSampleGap = DEFAULT_MAX_SAMPLE_GAP;
    params.recoveryDelay = DEFAULT_RECOVERY_DELAY;
    params.indexMaxAge = DEFAULT_INDEX_MAX_AGE;
  }

  function checkDeployer(Params memory params, address deployer, uint nonce, address usedDeployer) public view {
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");
    if (nonce > 1 && deployer != usedDeployer) {
      revert("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)");
    }
    if (deployer == params.vault) revert("deployer is the vault");
    if (LyraSpotFeed(params.cngnIndexFeed).isSigner(deployer)) revert("deployer signs the index");
    if (deployer == params.forwardSigner) revert("deployer signs the forward");
  }

  /// @dev Each check is a way the deployment lands and then cannot be attached, trade, or settle.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    if (params.verifierProxy != VERIFIER_PROXY) revert("verifierProxy must be the Base VerifierProxy");
    MarginEngine engine = MarginEngine(params.engine);
    if (engine.owner() != params.vault) revert("v2 engine is not owned by the vault");
    if (engine.lastMarketId() != MARKET_ID) revert("v2 must list exactly NGN and EUR");
    if (params.referenceFeed != vm.parseJsonAddress(_readDeploymentFile("EURC_SPOT"), ".spotFeed")) {
      revert("market 2's spot feed is not the EURC feed");
    }
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Perpetual)) != address(0)) {
      revert("market 2 lists a perp");
    }
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the artifact's");
    if (ITradeModuleFuturesV3(params.tradeModule).quoteAsset() != params.cash) {
      revert("trade module quote is not cash");
    }
    if (ITradeModuleFuturesV3(params.tradeModule).owner() != params.vault) revert("trade module not owned by vault");
    if (address(SubAccounts(params.subAccounts).manager(params.poolAccount)) != address(engine)) {
      revert("pool not under the engine");
    }
    checkSlotFree(params);
    checkVerifier();

    // the contract's own bounds (FutureAsset.setIndexParams), checked here so a bad env fails before broadcasting
    if (params.fixingWindow < 15 minutes || params.fixingWindow > 1 days) revert("FIXING_WINDOW out of range");
    if (params.maxSampleGap < 1 minutes || params.maxSampleGap * 4 > params.fixingWindow) {
      revert("MAX_SAMPLE_GAP: 1 minute to a quarter of the window");
    }
    if (params.recoveryDelay > 6 hours) revert("RECOVERY_DELAY over the contract's 6-hour bound");
    if (params.indexMaxAge == 0 || params.indexMaxAge > params.maxSampleGap) {
      revert("INDEX_MAX_AGE must be positive and no longer than MAX_SAMPLE_GAP");
    }
    if (params.feedTimelock < 1 hours) revert("FEED_TIMELOCK under an hour");

    if (params.expiry <= block.timestamp + params.fixingWindow) revert("expiry too soon");
    if (params.lastTradeTime >= params.expiry || params.lastTradeTime > params.expiry - params.fixingWindow) {
      revert("last trade must be no later than the fixing window's start");
    }
    _checkNoSharedSeries(engine, params.expiry);
    if (params.canaryExpiry != 0) checkCanary(params, engine);
    if (params.contractSize == 0) revert("CONTRACT_SIZE is zero");
    if (params.futureOICap != UNCAPPED && (params.futureOICap == 0 || params.futureOICap % 2e18 != 0)) {
      revert("FUTURE_OI_CAP must be a positive, even number of whole contracts (it counts both sides)");
    }
    if (params.mmReq == 0 || params.mmReq > params.imReq || params.imReq >= 1e18) {
      revert("futures margin: need 0 < MM <= IM < 100%");
    }
    if (params.mmReq < 0.01e18) revert("FUTURE_MM_REQ under 1%: give it 18dp (0.04e18 for 4%)");

    if (params.forwardSigner == address(0)) revert("FORWARD_SIGNER is zero");
    if (params.forwardSigner == params.vault) revert("FORWARD_SIGNER must not be the vault");
    if (LyraSpotFeed(params.cngnIndexFeed).isSigner(params.forwardSigner)) {
      revert("FORWARD_SIGNER must not also sign the cNGN index");
    }
    uint ref = referencePrice(params);
    if (ref < MIN_INDEX || ref > MAX_INDEX) revert("reference is not a USD per EURC price");
    if (params.carry > int(MAX_CARRY) || params.carry < -int(MAX_CARRY)) revert("CARRY over 20% a year either way");
    if (params.initialMark == 0) revert("INITIAL_MARK is zero");
    if (params.initialMarkTolerance == 0 || params.initialMarkTolerance > MAX_MARK_INDEX_DEVIATION) {
      revert("INITIAL_MARK_TOLERANCE out of range");
    }
    if (_outside(params.initialMark, fairForward(params), params.initialMarkTolerance)) {
      revert("INITIAL_MARK is outside the band around reference / (1 + carry * tau)");
    }
  }

  /**
   * @dev Market 2's future slot may be replaced only when its holder is empty: `whitelistAsset` de-lists it, and an
   *      account still holding it, or owed VM on it, would be cut off from the engine. Empty or the retired series
   *      closed with nothing in it; anything else refuses.
   */
  function checkSlotFree(Params memory params) public view {
    MarginEngine engine = MarginEngine(params.engine);
    address holder = address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future));
    if (holder == address(0)) return;
    if (holder != RETIRED_FUTURE) revert("market 2's future is not the retired EURC-30NOV26: stop and investigate");
    IManager m = IManager(params.engine);
    if (IPositionTracking(holder).totalPosition(m) != 0) revert("retired series still has open interest");
    if (IPositionTracking(holder).totalPositionCap(m) != 0) revert("retired series' cap is not 0");
    if (ITradeModuleFuturesV3(params.tradeModule).isDatedFutureAsset(holder)) {
      revert("retired series is still on the TradeModule");
    }
    uint last = SubAccounts(params.subAccounts).lastAccountId();
    for (uint acc = 1; acc <= last; ++acc) {
      if (IFutureAsset(holder).getPendingVM(acc, RETIRED_SERIES) != 0) revert("an account has VM pending on it");
    }
  }

  /// @dev The verifier the adapter will call is the one recorded in A2.1.
  function checkVerifier() public view {
    if (VERIFIER_PROXY.code.length == 0) revert("verifier proxy has no code - wrong chain?");
    if (
      keccak256(bytes(ITypeAndVersion(VERIFIER_PROXY).typeAndVersion())) != keccak256(bytes(VERIFIER_TYPE_AND_VERSION))
    ) {
      revert("verifier proxy is not VerifierProxy 2.0.0");
    }
  }

  function checkCanary(Params memory params, MarginEngine engine) public view {
    if (params.canaryExpiry < block.timestamp + CANARY_MIN_LEAD) {
      revert("CANARY_EXPIRY too soon: the vault's setup and enable must land before its last trade");
    }
    if (params.canaryExpiry > block.timestamp + CANARY_MAX_LEAD) revert("CANARY_EXPIRY over a week out");
    if (params.canaryExpiry + CANARY_RECOVERY_DELAY + CANARY_FIXING_WINDOW >= params.expiry - params.fixingWindow) {
      revert("the canary must settle, recovery included, before the production series' fixing");
    }
    if (params.maxSampleGap * 4 > CANARY_FIXING_WINDOW) revert("MAX_SAMPLE_GAP too long for the canary's window");
    if (params.canaryInitialMark == 0) revert("canary initial mark is zero");
    _checkNoSharedSeries(engine, params.canaryExpiry);
  }

  function _checkNoSharedSeries(MarginEngine engine, uint64 expiry) internal view {
    for (uint id = 1; id <= engine.lastMarketId(); ++id) {
      IFutureAsset other = IFutureAsset(address(engine.assetMap(id, IMarginEngine.AssetType.Future)));
      if (address(other) == address(0)) continue;
      if (other.futureContracts(uint96(expiry)).listed) {
        revert("EXPIRY is a series another market lists: closeOutExpired would couple them");
      }
    }
  }

  function referencePrice(Params memory params) public view returns (uint price) {
    (price,) = ISpotFeed(params.referenceFeed).getSpot();
  }

  function fairForward(Params memory params) public view returns (uint) {
    uint ref = referencePrice(params);
    int tau = int(uint(params.expiry - block.timestamp));
    int denominator = 1e18 + params.carry * tau / 365 days;
    if (denominator <= 0) revert("carry x tau at or under -100%");
    return ref * 1e18 / uint(denominator);
  }

  function _outside(uint price, uint reference_, uint band) internal pure returns (bool) {
    uint diff = price > reference_ ? price - reference_ : reference_ - price;
    return diff * 1e18 > reference_ * band;
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployment memory d) {
    MarginEngine engine = MarginEngine(params.engine);
    d.adapter = new StreamsIndexAdapter(IStreamsVerifierProxy(params.verifierProxy), LINK, EURC_USD_FEED, USDC_USD_FEED);
    d.indexFeed = new EurcIndexFeed(d.adapter, params.indexMaxAge);

    d.future = new FutureAsset(SubAccounts(params.subAccounts), params.contractSize, d.indexFeed, params.feedTimelock);
    d.future.setWhitelistManager(address(engine), true);
    d.future.setTotalPositionCap(engine, 0);
    d.future.setMarkBounds(MAX_MARK_DEVIATION, MAX_MARK_DELAY);
    // Marks read the index plus a signed forward difference: stale index, no mark, as for fills.
    d.forwardFeed = new LyraForwardFeed(d.indexFeed);
    d.forwardFeed.setHeartbeat(FORWARD_HEARTBEAT);
    d.forwardFeed.addSigner(params.forwardSigner, true);
    d.forwardFeed.setRequiredSigners(1);
    d.future.setForwardFeed(IForwardFeed(address(d.forwardFeed)), MIN_MARK_INTERVAL);
    // Each series copies the fixing params set when it is listed. The canary first, on its short ones; then the
    // production params, which stay the contract's defaults for any series listed later.
    if (params.canaryExpiry != 0) {
      _setFixing(d.future, CANARY_FIXING_WINDOW, params.maxSampleGap, CANARY_RECOVERY_DELAY);
      d.canarySubId = d.future
        .setContract(params.canaryExpiry, params.canaryExpiry - uint64(CANARY_FIXING_WINDOW), params.canaryInitialMark);
    }
    _setFixing(d.future, params.fixingWindow, params.maxSampleGap, params.recoveryDelay);
    d.subId = d.future.setContract(params.expiry, params.lastTradeTime, params.initialMark);

    d.future.transferOwnership(params.vault);
    d.forwardFeed.transferOwnership(params.vault);
  }

  function _setFixing(FutureAsset future, uint window, uint gap, uint recovery) internal {
    future.setIndexParams(
      MAX_MARK_INDEX_DEVIATION, MIN_MARK_INDEX_DEVIATION, BAND_NARROWING_PERIOD, window, gap, recovery
    );
  }

  function ownedContracts(Deployment memory d) public pure returns (address[] memory owned) {
    owned = new address[](2);
    owned[0] = address(d.future);
    owned[1] = address(d.forwardFeed);
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
    if (address(d.adapter.verifierProxy()) != params.verifierProxy) revert("adapter verifier");
    if (block.chainid == 8453 && params.verifierProxy != VERIFIER_PROXY) revert("adapter verifier on Base");
    if (d.adapter.baseFeedId() != EURC_USD_FEED || d.adapter.quoteFeedId() != USDC_USD_FEED) revert("adapter feeds");
    if (d.adapter.feeToken() != LINK) revert("adapter fee token");
    if (address(d.indexFeed.adapter()) != address(d.adapter)) revert("index feed adapter");
    if (d.indexFeed.indexMaxAge() != params.indexMaxAge) revert("index max age");
    if (d.future.contractSize() != params.contractSize) revert("contract size");
    if (!d.future.whitelistedManager(address(engine))) revert("future does not whitelist the engine");
    if (d.future.totalPositionCap(engine) != 0) revert("future must deploy closed (cap 0)");
    if (address(d.future.indexFeed()) != address(d.indexFeed)) revert("future index not the EURC index");
    if (d.future.feedTimelock() != params.feedTimelock) revert("feed timelock");
    if (d.future.fixingWindow() != params.fixingWindow || d.future.maxSampleGap() != params.maxSampleGap) {
      revert("fixing params");
    }
    if (d.future.recoveryDelay() != params.recoveryDelay) revert("recovery delay");
    IFutureAssetV3.FixingParams memory sf = d.future.seriesFixing(d.subId);
    if (sf.fixingWindow != params.fixingWindow || sf.maxSampleGap != params.maxSampleGap) {
      revert("series fixing params");
    }
    if (sf.recoveryDelay != params.recoveryDelay) revert("series recovery delay");
    if (address(d.future.forwardFeed()) != address(d.forwardFeed)) revert("future does not read the forward feed");
    if (address(d.forwardFeed.spotFeed()) != address(d.indexFeed)) revert("forward feed is not on the index");
    if (!d.forwardFeed.isSigner(params.forwardSigner)) revert("forward feed missing its signer");
    if (d.forwardFeed.isSigner(msg.sender)) revert("deployer signs the forward feed");
    IFutureAsset.FutureContract memory c = d.future.futureContracts(d.subId);
    if (!c.listed || c.expiry != params.expiry || c.markPrice != params.initialMark) revert("contract not listed");
    if (d.subId != params.expiry) revert("subId is not the expiry");
    if (params.canaryExpiry == 0) {
      if (d.canarySubId != 0) revert("a canary nobody asked for");
    } else {
      if (d.canarySubId != params.canaryExpiry) revert("canary subId is not its expiry");
      IFutureAsset.FutureContract memory k = d.future.futureContracts(d.canarySubId);
      if (!k.listed || k.lastTradeTime != params.canaryExpiry - CANARY_FIXING_WINDOW) revert("canary not listed");
      IFutureAssetV3.FixingParams memory kf = d.future.seriesFixing(d.canarySubId);
      if (kf.fixingWindow != CANARY_FIXING_WINDOW || kf.recoveryDelay != CANARY_RECOVERY_DELAY) {
        revert("canary fixing params");
      }
      if (kf.maxSampleGap != params.maxSampleGap) revert("canary sample gap must be production's");
    }

    // Nothing the vault owns is changed by the deployer.
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future)) == address(d.future)) {
      revert("market 2 lists the future before the vault batch");
    }
    if (ITradeModuleFuturesV3(params.tradeModule).isDatedFutureAsset(address(d.future))) {
      revert("future on the TradeModule before enable");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "eurc-future-v3";
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "adapter", address(d.adapter));
    vm.serializeAddress(obj, "indexFeed", address(d.indexFeed));
    vm.serializeAddress(obj, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(obj, "forwardSigner", params.forwardSigner);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "manager", params.engine);
    vm.serializeString(obj, "symbol", string.concat("EURC-", _expiryCode(params.expiry)));
    vm.serializeString(obj, "units", "USDC per EURC; contractSize in EURC; VM in USDC cash");
    vm.serializeAddress(obj, "verifierProxy", params.verifierProxy);
    vm.serializeBytes32(obj, "baseFeedId", EURC_USD_FEED);
    vm.serializeBytes32(obj, "quoteFeedId", USDC_USD_FEED);
    vm.serializeAddress(obj, "replaces", RETIRED_FUTURE);
    vm.serializeUint(obj, "futureMMReq", params.mmReq);
    vm.serializeUint(obj, "futureIMReq", params.imReq);
    vm.serializeUint(obj, "maxMarkDeviation", MAX_MARK_DEVIATION);
    vm.serializeUint(obj, "maxMarkDelay", MAX_MARK_DELAY);
    vm.serializeUint(obj, "maxMarkIndexDeviation", MAX_MARK_INDEX_DEVIATION);
    vm.serializeUint(obj, "minMarkIndexDeviation", MIN_MARK_INDEX_DEVIATION);
    vm.serializeUint(obj, "bandNarrowingPeriod", BAND_NARROWING_PERIOD);
    vm.serializeUint(obj, "feedTimelock", params.feedTimelock);
    vm.serializeUint(obj, "fixingWindow", params.fixingWindow);
    vm.serializeUint(obj, "maxSampleGap", params.maxSampleGap);
    vm.serializeUint(obj, "recoveryDelay", params.recoveryDelay);
    vm.serializeUint(obj, "indexMaxAge", params.indexMaxAge);
    vm.serializeUint(obj, "minMarkInterval", MIN_MARK_INTERVAL);
    vm.serializeUint(obj, "forwardHeartbeat", FORWARD_HEARTBEAT);
    vm.serializeUint(obj, "marketId", MARKET_ID);
    vm.serializeUint(obj, "poolAccount", params.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "canarySubId", d.canarySubId);
    vm.serializeUint(obj, "canaryFixingWindow", params.canaryExpiry == 0 ? 0 : CANARY_FIXING_WINDOW);
    vm.serializeUint(obj, "canaryRecoveryDelay", params.canaryExpiry == 0 ? 0 : CANARY_RECOVERY_DELAY);
    vm.serializeUint(obj, "canaryInitialMark", params.canaryInitialMark);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
    vm.serializeInt(obj, "carry", params.carry);
    vm.serializeUint(obj, "referenceAtDeploy", referencePrice(params));
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "referenceFeed", params.referenceFeed);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    string memory json = vm.serializeUint(obj, "futureOICap", params.futureOICap);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  function _expiryCode(uint64 expiry) internal pure returns (string memory) {
    (uint year, uint month, uint day) = _date(expiry / 1 days);
    string[12] memory months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
    return string.concat(day < 10 ? "0" : "", vm.toString(day), months[month - 1], vm.toString(year % 100));
  }

  function _date(uint z) internal pure returns (uint year, uint month, uint day) {
    z += 719468;
    uint era = z / 146097;
    uint doe = z - era * 146097;
    uint yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    uint doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    uint mp = (5 * doy + 2) / 153;
    day = doy - (153 * mp + 2) / 5 + 1;
    month = mp < 10 ? mp + 3 : mp - 9;
    year = yoe + era * 400 + (month <= 2 ? 1 : 0);
  }

  /**
   * @dev Accept the two; list the future on market 2, REPLACING the retired series (checkSlotFree, re-read by the
   *      proposer); set market 2's futures margin. Opens nothing: cap 0, not on the TradeModule.
   *      No managerData whitelist: Stage 1's index is kept fresh by a keeper posting reports. Attaching reports to
   *      orders would need the adapter whitelisted on every manager a fill touches, the fee account #22's SRM included
   *      (spec A2.2; EurcFutureV3Fork pins the failure).
   */
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [EURC future v3]", owned[i], accept));
    }
    json = string.concat(
      json,
      ",",
      _action(
        "engineV2.whitelistAsset(eurcFutureV3, 2, Future) [replaces the retired v2 EURC-30NOV26; cap 0]",
        params.engine,
        abi.encodeWithSignature(
          "whitelistAsset(address,uint256,uint8)", address(d.future), MARKET_ID, uint8(IMarginEngine.AssetType.Future)
        )
      ),
      ",",
      _action(
        string.concat(
          "engineV2.setFutureMarginRequirements(2, ",
          vm.toString(params.mmReq),
          ", ",
          vm.toString(params.imReq),
          ") [EUR futures MM / IM]"
        ),
        params.engine,
        abi.encodeWithSignature(
          "setFutureMarginRequirements(uint256,uint256,uint256)", MARKET_ID, params.mmReq, params.imReq
        )
      ),
      "]"
    );
  }

  function vaultActionCount() public pure returns (uint) {
    return 4;
  }

  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    json = string.concat(
      "[",
      // TradeModule first: until it is registered, a fill carries no price and skips the band check. With the cap
      // still 0 nothing can fill in between; the other order opened a block in which an unpriced fill could land.
      _action(
        "tradeModule.setDatedFutureAsset(eurcFutureV3, true) [fills carry their price to the future]",
        params.tradeModule,
        abi.encodeWithSignature("setDatedFutureAsset(address,bool)", address(d.future), true)
      ),
      ",",
      _action(
        string.concat(
          "eurcFutureV3.setTotalPositionCap(engineV2, ", vm.toString(params.futureOICap), ") [opens EURC future v3]"
        ),
        address(d.future),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", params.engine, params.futureOICap)
      ),
      "]"
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 2;
  }

  /// @dev Digest is keccak(to ‖ keccak(data)), as the v2 scripts'.
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
