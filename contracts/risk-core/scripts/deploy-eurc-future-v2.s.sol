// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {LyraForwardFeed} from "../src/feeds/LyraForwardFeed.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleFutures {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

/**
 * @title DeployEurcFutureV2
 *
 * @dev EURC-<expiry> on the live MarginEngine v2 (deployments/8453/MARGIN_ENGINE_V2.json), on market 2 (EUR): a FutureAsset
 *      and its own LyraForwardFeed over the EURC spot feed, both nominated to the vault. American terms, as v2's cNGN
 *      series: USDC per EURC, one contract CONTRACT_SIZE EURC, VM in USDC cash, a long gains as EUR strengthens. v1's
 *      futures are inverse with VM in base, so this series is v2's only.
 *
 * @dev No engine change and no new pool. The engine is the vault's since setup, so attaching the future is the vault's:
 *      VAULT_ACTIONS accepts the two contracts, whitelists the future on market 2 (`whitelistAsset`) and sets market 2's
 *      futures margin (`setFutureMarginRequirements`), both owner-only setters on the deployed engine. VM moves through
 *      the engine's one pool account (`accId`, #37), which FutureVMLib uses for every future on every market: the pool
 *      only fronts cash between holders of a series, so it needs no second account. ENABLE_VAULT_ACTIONS opens the cap
 *      and registers the future on the TradeModule, as the cNGN series' enable.
 *
 * @dev DEPLOYED CLOSED. The future's cap under v2 is 0 and the engine does not list it until VAULT_ACTIONS; the
 *      TradeModule does not know it until ENABLE_VAULT_ACTIONS. scripts/ops/propose_eurc_future_v2_batch.py gates both.
 *
 * @dev UNITS. Everything is USDC per EURC: the index (Chainlink EURC/USD, the EUR market's spot feed), the forward feed
 *      and the future, which reads both as is. CARRY is the EUR rate less the USD rate, signed: USD rates above EUR rates
 *      make it negative, and EUR trades at a forward premium, index / (1 + carry x tau) above the index. The forward
 *      feed's signed difference is then positive.
 *
 * @dev EXPIRY must not be a series another market's future lists. A series is identified by its subId, the expiry,
 *      and closeOutExpired(account, subId) closes it on every market that lists it, reverting while any of them is
 *      unsettled (FutureVMLib.closeOutAll). Two futures at one expiry would hold every close-out of each until both
 *      have fixed: an EURC fixing that falls back to the owner (24h) would keep cNGN-30NOV26 holders margined on a
 *      settled position for that day. The default is 16:00 UTC, the WM/Reuters London fix, two hours after cNGN's.
 *
 * Usage (a fresh keystore account, used for this deploy only, or a used one named in USED_DEPLOYER; see checkDeployer):
 *   FORWARD_SIGNER=<forward key> forge script scripts/deploy-eurc-future-v2.s.sol --rpc-url $BASE_RPC_URL \
 *     --account <fresh keystore> --broadcast
 *
 * Optional env: EXPIRY, LAST_TRADE_TIME, CONTRACT_SIZE, CARRY (signed, 18dp), INITIAL_MARK (default: the fair forward
 * at deploy), INITIAL_MARK_TOLERANCE, FUTURE_IM_REQ, FUTURE_MM_REQ, FUTURE_OI_CAP, USED_DEPLOYER.
 */
contract DeployEurcFutureV2 is Utils {
  string internal constant ARTIFACT_NAME = "EURC_FUTURE_V2";
  string internal constant VAULT_ACTIONS_NAME = "EURC_FUTURE_V2_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "EURC_FUTURE_V2_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev The EUR market, as eurc-spot-batch.sol created it on v1 and deploy-margin-engine-v2.s.sol copied it to v2.
  uint internal constant MARKET_ID = 2;

  /// @dev 2026-11-30 16:00 UTC: the WM/Reuters London fix, and not cNGN-30NOV26's 14:00 (see EXPIRY above).
  uint64 internal constant DEFAULT_EXPIRY = 1796054400;
  /// @dev EURC per contract: ~1,114 USDC at 1.1138, near v2 cNGN's ~743 and v1's 1,000, so a cap reads in similar
  ///      dollars.
  uint internal constant DEFAULT_CONTRACT_SIZE = 1_000e18;
  /// @dev Contracts over both sides: the SecurityModule's cover of a whole SM_MOVE (15%) step on one side, after
  ///      cNGN-30NOV26's 30 at its mark, at 2026-10-27 readings ($3,250; 0.000713; 1.1138): the $1,645 left covers a
  ///      $10,968 side, 9.8 contracts, so 9 a side (docs/margin-engine-v2.md, EURC-30NOV26). The enable gate re-reads it.
  uint internal constant DEFAULT_FUTURE_OI_CAP = 18e18;

  /// @dev An account opened at IM falls to MM on a 1.9% EUR rally (short) or 2.1% fall (long), and is bankrupt at 6%,
  ///      past any daily EUR/USD move on record (docs/margin-engine-v2.md, EURC-30NOV26).
  uint internal constant DEFAULT_FUTURE_IM_REQ = 0.06e18;
  uint internal constant DEFAULT_FUTURE_MM_REQ = 0.04e18;
  /// @dev EUR rate less USD rate, a year: an assumption (ECB deposit ~2% against fed funds ~3.5%), not a reading.
  int internal constant DEFAULT_CARRY = -0.015e18;

  /// @dev A mark may move 2% (an hour apart at the least), and sit within 3% of the index, narrowing to 0.5% over the
  ///      last 14 days. cNGN's 5% and 10% -> 1% are sized to NGN; EUR/USD moves a fifth as much, and the band is also the
  ///      fill band, which bounds what two accounts can move between them at an off-market price.
  uint internal constant MAX_MARK_DEVIATION = 0.02e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;
  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.03e18;
  uint internal constant MIN_MARK_INDEX_DEVIATION = 0.005e18;
  uint internal constant BAND_NARROWING_PERIOD = 14 days;
  uint internal constant MIN_MARK_INTERVAL = 1 hours;
  uint64 internal constant FORWARD_HEARTBEAT = 2 hours;
  uint internal constant FIXING_WINDOW = 1 hours;
  uint internal constant MAX_SAMPLE_GAP = 15 minutes;
  uint internal constant FALLBACK_DELAY = 24 hours;

  uint internal constant DEFAULT_INITIAL_MARK_TOLERANCE = 0.005e18;
  uint internal constant MAX_CARRY = 0.2e18;
  /// @dev USD per EURC the index may read: the EURC listing's feed gate (propose_eurc_spot_batch.py)
  uint internal constant MIN_INDEX = 0.8e18;
  uint internal constant MAX_INDEX = 1.6e18;

  struct Params {
    address subAccounts;
    address vault;
    address engine;
    address viewer;
    address cash;
    address tradeModule;
    /// @dev market 2's base and spot feed on v2, checked against EURC_SPOT.json
    address escrow;
    address indexFeed;
    /// @dev the cNGN index (a LyraSpotFeed): its signers may not deploy or sign the forward
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
    address forwardSigner;
  }

  struct Deployment {
    FutureAsset future;
    LyraForwardFeed forwardFeed;
    uint96 subId;
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

  /// @dev The operator's inputs from the environment over the defaults, then checked. The initial mark defaults to the
  ///      fair forward at the block the script runs in.
  function loadParams() public view returns (Params memory params) {
    params = loadChainParams();
    params.expiry = uint64(vm.envOr("EXPIRY", uint(params.expiry)));
    params.lastTradeTime = uint64(vm.envOr("LAST_TRADE_TIME", uint(params.expiry - FIXING_WINDOW)));
    params.contractSize = vm.envOr("CONTRACT_SIZE", params.contractSize);
    params.carry = vm.envOr("CARRY", params.carry);
    params.initialMarkTolerance = vm.envOr("INITIAL_MARK_TOLERANCE", params.initialMarkTolerance);
    params.imReq = vm.envOr("FUTURE_IM_REQ", params.imReq);
    params.mmReq = vm.envOr("FUTURE_MM_REQ", params.mmReq);
    params.futureOICap = vm.envOr("FUTURE_OI_CAP", params.futureOICap);
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");
    params.initialMark = vm.envOr("INITIAL_MARK", fairForward(params));

    checkParams(params);
  }

  /// @dev Everything read from the chain and the artifacts, with the defaults; no environment, no checks. The fork test
  ///      builds on this (forge runs suites in parallel in one process, so a suite may not share env names).
  function loadChainParams() public view returns (Params memory params) {
    string memory v2 = _readDeploymentFile("MARGIN_ENGINE_V2");
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.engine = vm.parseJsonAddress(v2, ".manager");
    params.viewer = vm.parseJsonAddress(v2, ".viewer");
    params.cash = vm.parseJsonAddress(v2, ".cash");
    params.tradeModule = vm.parseJsonAddress(v2, ".tradeModule");
    params.cngnIndexFeed = vm.parseJsonAddress(v2, ".indexFeed");

    MarginEngine engine = MarginEngine(params.engine);
    params.escrow = address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Base));
    (ISpotFeed spot,,) = engine.getMarketFeeds(MARKET_ID);
    params.indexFeed = address(spot);
    params.poolAccount = engine.accId();

    params.expiry = DEFAULT_EXPIRY;
    params.lastTradeTime = DEFAULT_EXPIRY - uint64(FIXING_WINDOW);
    params.contractSize = DEFAULT_CONTRACT_SIZE;
    params.carry = DEFAULT_CARRY;
    params.initialMarkTolerance = DEFAULT_INITIAL_MARK_TOLERANCE;
    params.imReq = DEFAULT_FUTURE_IM_REQ;
    params.mmReq = DEFAULT_FUTURE_MM_REQ;
    params.futureOICap = DEFAULT_FUTURE_OI_CAP;
  }

  /**
   * @dev The deployer owns the two contracts until the vault accepts them in setup. A fresh key arrives with nonce 0 or
   *      1; a key that has sent before is accepted only when named in USED_DEPLOYER. Setup's gate refuses either way if
   *      the deployer sends anything between the deploy and the accept.
   */
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
    MarginEngine engine = MarginEngine(params.engine);
    if (engine.owner() != params.vault) revert("v2 engine is not owned by the vault");
    if (engine.lastMarketId() != MARKET_ID) revert("v2 must list exactly NGN and EUR");
    string memory eurc = _readDeploymentFile("EURC_SPOT");
    if (params.escrow != vm.parseJsonAddress(eurc, ".escrow")) revert("market 2's base is not the EURC escrow");
    if (params.indexFeed != vm.parseJsonAddress(eurc, ".spotFeed")) {
      revert("market 2's spot feed is not the EURC feed");
    }
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future)) != address(0)) {
      revert("market 2 already lists a future");
    }
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Perpetual)) != address(0)) {
      revert("market 2 lists a perp");
    }
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the artifact's");
    if (address(engine.viewer()) != params.viewer) revert("engine viewer is not the artifact's");
    if (ITradeModuleFutures(params.tradeModule).quoteAsset() != params.cash) {
      revert("trade module quote is not the cash");
    }
    if (ITradeModuleFutures(params.tradeModule).owner() != params.vault) {
      revert("trade module is not owned by the vault");
    }
    if (address(SubAccounts(params.subAccounts).manager(params.poolAccount)) != address(engine)) {
      revert("pool not under the engine");
    }

    if (params.expiry <= block.timestamp + FIXING_WINDOW) revert("expiry too soon");
    if (params.lastTradeTime >= params.expiry || params.lastTradeTime > params.expiry - FIXING_WINDOW) {
      revert("last trade must be no later than the fixing window's start");
    }
    _checkNoSharedSeries(engine, params.expiry);
    if (params.contractSize == 0) revert("CONTRACT_SIZE is zero");
    if (params.futureOICap == 0 || params.futureOICap % 2e18 != 0) {
      revert("FUTURE_OI_CAP must be a positive, even number of whole contracts (it counts both sides)");
    }
    if (params.mmReq == 0 || params.mmReq > params.imReq || params.imReq >= 1e18) {
      revert("futures margin: need 0 < MM <= IM < 100%");
    }
    // a floor against a unit slip (0.04 for 4%, not 4e16 / 1e18): an MM under 1% liquidates on noise
    if (params.mmReq < 0.01e18) revert("FUTURE_MM_REQ under 1%: give it 18dp (0.04e18 for 4%)");

    if (params.forwardSigner == address(0)) revert("FORWARD_SIGNER is zero");
    if (params.forwardSigner == params.vault) revert("FORWARD_SIGNER must not be the vault");
    if (LyraSpotFeed(params.cngnIndexFeed).isSigner(params.forwardSigner)) {
      revert("FORWARD_SIGNER must not also sign the index");
    }
    uint index = indexPrice(params);
    if (index < MIN_INDEX || index > MAX_INDEX) revert("index is not a USD per EURC price");
    if (params.carry > int(MAX_CARRY) || params.carry < -int(MAX_CARRY)) {
      revert("CARRY over 20% a year either way: give it signed 18dp (-0.015e18 for -1.5%)");
    }
    if (params.initialMark == 0) revert("INITIAL_MARK is zero");
    if (params.initialMarkTolerance == 0 || params.initialMarkTolerance > MAX_MARK_INDEX_DEVIATION) {
      revert("INITIAL_MARK_TOLERANCE out of range");
    }
    if (_outside(params.initialMark, index, MAX_MARK_INDEX_DEVIATION)) {
      revert("INITIAL_MARK is outside the index band");
    }
    if (_outside(params.initialMark, fairForward(params), params.initialMarkTolerance)) {
      revert("INITIAL_MARK is outside the band around index / (1 + carry * tau)");
    }
  }

  /// @dev Refuses an expiry that any market's future lists: one subId on two futures couples their close-outs.
  function _checkNoSharedSeries(MarginEngine engine, uint64 expiry) internal view {
    for (uint id = 1; id <= engine.lastMarketId(); ++id) {
      IFutureAsset other = IFutureAsset(address(engine.assetMap(id, IMarginEngine.AssetType.Future)));
      if (address(other) == address(0)) continue;
      if (other.futureContracts(uint96(expiry)).listed) {
        revert("EXPIRY is a series another market lists: closeOutExpired would couple them");
      }
    }
  }

  /// @dev USDC per EURC, the feed's own units and the future's: read as is. Reverts when Chainlink is 3h stale.
  function indexPrice(Params memory params) public view returns (uint index) {
    (index,) = ISpotFeed(params.indexFeed).getSpot();
  }

  /// @dev index / (1 + carry * tau), tau = years from now to expiry. With carry negative EUR sits at a forward premium.
  function fairForward(Params memory params) public view returns (uint) {
    uint index = indexPrice(params);
    int tau = int(uint(params.expiry - block.timestamp));
    int denominator = 1e18 + params.carry * tau / 365 days;
    if (denominator <= 0) revert("carry x tau at or under -100%");
    return index * 1e18 / uint(denominator);
  }

  function _outside(uint price, uint reference_, uint band) internal pure returns (bool) {
    uint diff = price > reference_ ? price - reference_ : reference_ - price;
    return diff * 1e18 > reference_ * band;
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  /// @dev The future: closed (cap 0), marked from its own forward feed, fixed from the EURC index. Not yet on the engine.
  function deploy(Params memory params) public returns (Deployment memory d) {
    MarginEngine engine = MarginEngine(params.engine);
    d.future = new FutureAsset(SubAccounts(params.subAccounts), params.contractSize);
    d.future.setWhitelistManager(address(engine), true);
    d.future.setTotalPositionCap(engine, 0);
    d.future.setMarkBounds(MAX_MARK_DEVIATION, MAX_MARK_DELAY);
    d.future
      .setIndexParams(
        ISpotFeed(params.indexFeed),
        MAX_MARK_INDEX_DEVIATION,
        MIN_MARK_INDEX_DEVIATION,
        BAND_NARROWING_PERIOD,
        FIXING_WINDOW,
        MAX_SAMPLE_GAP,
        FALLBACK_DELAY
      );
    d.forwardFeed = new LyraForwardFeed(ISpotFeed(params.indexFeed));
    d.forwardFeed.setHeartbeat(FORWARD_HEARTBEAT);
    d.forwardFeed.addSigner(params.forwardSigner, true);
    d.forwardFeed.setRequiredSigners(1);
    d.future.setForwardFeed(IForwardFeed(address(d.forwardFeed)), MIN_MARK_INTERVAL);
    d.subId = d.future.setContract(params.expiry, params.lastTradeTime, params.initialMark);

    d.future.transferOwnership(params.vault);
    d.forwardFeed.transferOwnership(params.vault);
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
    if (d.future.contractSize() != params.contractSize) revert("contract size");
    if (!d.future.whitelistedManager(address(engine))) revert("future does not whitelist the engine");
    if (d.future.totalPositionCap(engine) != 0) revert("future must deploy closed (cap 0)");
    if (address(d.future.indexFeed()) != params.indexFeed) revert("future index not set");
    if (address(d.future.forwardFeed()) != address(d.forwardFeed)) revert("future does not read the forward feed");
    if (d.future.minMarkInterval() == 0) revert("pulls are not rate limited");
    if (address(d.forwardFeed.spotFeed()) != params.indexFeed) revert("forward feed is not on the index");
    if (!d.forwardFeed.isSigner(params.forwardSigner)) revert("forward feed missing its signer");
    if (d.forwardFeed.isSigner(msg.sender)) revert("deployer signs the forward feed");
    IFutureAsset.FutureContract memory c = d.future.futureContracts(d.subId);
    if (!c.listed || c.expiry != params.expiry || c.markPrice != params.initialMark) revert("contract not listed");

    // Nothing the vault owns is changed by the deployer: attaching the future is the vault's.
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future)) != address(0)) {
      revert("market 2 lists a future before the vault batch");
    }
    if (ITradeModuleFutures(params.tradeModule).isDatedFutureAsset(address(d.future))) {
      revert("future on the TradeModule before enable");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "eurc-future-v2";
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(obj, "forwardSigner", params.forwardSigner);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "manager", params.engine);
    vm.serializeAddress(obj, "viewer", params.viewer);
    vm.serializeString(obj, "symbol", string.concat("EURC-", _expiryCode(params.expiry)));
    vm.serializeString(obj, "units", "USDC per EURC; contractSize in EURC; VM in USDC cash");
    vm.serializeUint(obj, "futureMMReq", params.mmReq);
    vm.serializeUint(obj, "futureIMReq", params.imReq);
    vm.serializeUint(obj, "maxMarkDeviation", MAX_MARK_DEVIATION);
    vm.serializeUint(obj, "maxMarkDelay", MAX_MARK_DELAY);
    vm.serializeUint(obj, "maxMarkIndexDeviation", MAX_MARK_INDEX_DEVIATION);
    vm.serializeUint(obj, "minMarkIndexDeviation", MIN_MARK_INDEX_DEVIATION);
    vm.serializeUint(obj, "bandNarrowingPeriod", BAND_NARROWING_PERIOD);
    vm.serializeUint(obj, "fixingWindow", FIXING_WINDOW);
    vm.serializeUint(obj, "maxSampleGap", MAX_SAMPLE_GAP);
    vm.serializeUint(obj, "fallbackDelay", FALLBACK_DELAY);
    vm.serializeUint(obj, "minMarkInterval", MIN_MARK_INTERVAL);
    vm.serializeUint(obj, "forwardHeartbeat", FORWARD_HEARTBEAT);
    vm.serializeUint(obj, "marketId", MARKET_ID);
    vm.serializeUint(obj, "poolAccount", params.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
    vm.serializeInt(obj, "carry", params.carry);
    vm.serializeUint(obj, "indexAtDeploy", indexPrice(params));
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "escrow", params.escrow);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    string memory json = vm.serializeUint(obj, "futureOICap", params.futureOICap);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  /// @dev "30NOV26" for 2026-11-30, the venue's series code.
  function _expiryCode(uint64 expiry) internal pure returns (string memory) {
    (uint year, uint month, uint day) = _date(expiry / 1 days);
    string[12] memory months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
    return string.concat(day < 10 ? "0" : "", vm.toString(day), months[month - 1], vm.toString(year % 100));
  }

  /// @dev days since 1970-01-01 to (year, month, day): Howard Hinnant's civil_from_days
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

  /// @dev Accept the two, list the future on market 2 and set market 2's futures margin. Opens nothing: the cap stays 0
  ///      and the TradeModule does not know the future.
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [EURC future v2]", owned[i], accept));
    }
    json = string.concat(
      json,
      ",",
      _action(
        "engineV2.whitelistAsset(eurcFuture, 2, Future) [EURC future on the EUR market; cap 0]",
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

  /// @dev Opens the future, then registers it on the TradeModule. Run last, on its own.
  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    json = string.concat(
      "[",
      _action(
        string.concat(
          "eurcFuture.setTotalPositionCap(engineV2, ", vm.toString(params.futureOICap), ") [opens EURC future]"
        ),
        address(d.future),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", params.engine, params.futureOICap)
      ),
      ",",
      _action(
        "tradeModule.setDatedFutureAsset(eurcFuture, true) [fills carry their price to the future, no quote leg]",
        params.tradeModule,
        abi.encodeWithSignature("setDatedFutureAsset(address,bool)", address(d.future), true)
      ),
      "]"
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 2;
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
