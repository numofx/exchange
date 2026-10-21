// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {MarginEngineV1} from "../src/legacy/v1/MarginEngineV1.sol";
import {MarginEnginePortfolioViewer} from "../src/risk-managers/MarginEnginePortfolioViewer.sol";
import {DutchAuction} from "../src/liquidation/DutchAuction.sol";
import {LyraForwardFeed} from "../src/feeds/LyraForwardFeed.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {ICashAsset} from "../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleQuote {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
}

/**
 * @title DeployMarginEngineV2
 *
 * @dev MarginEngine v2 beside the live v1 engine (deployments/8453/MARGIN_ENGINE.json), hosting everything v1 hosts
 *      except the delisted perp: every base-asset market v1 lists (cNGN-USDC, and EURC-USDC once listed there), and on
 *      market 1 the first American-terms future, cNGN-<expiry>: USDC per cNGN, one contract CONTRACT_SIZE cNGN, VM in
 *      USDC cash. v1 is read, never called: every setting v2 shares with it is copied from it and asserted equal.
 *      Reused: SubAccounts, the USDC cash, the escrows, the index and spot feeds, the DutchAuction (and so the
 *      SecurityModule), the TradeModule.
 *
 * @dev DEPLOYED CLOSED. The future's cap under v2 is 0 and nothing reused is wired. VAULT_ACTIONS accepts the four
 *      contracts and wires v2 into the cash, every escrow (at v1's cap) and the auction; ENABLE_VAULT_ACTIONS opens the
 *      future and registers it on the TradeModule. Taking v1 close-only is propose_margin_engine_v2_batch.py's
 *      v1-close-only, at live open interest and never below it.
 *
 * @dev UNITS. Everything is USDC per cNGN: the index, the forward feed and the future, which reads both as is. NGN carries
 *      a positive rate against USD, so cNGN trades at a discount forward: fair forward = index / (1 + carry x tau), and
 *      the forward feed's signed difference is negative.
 *
 * Usage (a fresh keystore account, used for this deploy only):
 *   INITIAL_MARK=<USDC per cNGN, 18dp> CARRY=<annual carry, 18dp> FORWARD_SIGNER=<forward key> \
 *     forge script scripts/deploy-margin-engine-v2.s.sol --rpc-url $BASE_RPC_URL --account numo-deployer --broadcast
 *
 * Optional env: EXPIRY, LAST_TRADE_TIME, CONTRACT_SIZE, FUTURE_OI_CAP, INITIAL_MARK_TOLERANCE.
 */
contract DeployMarginEngineV2 is Utils {
  string internal constant ARTIFACT_NAME = "MARGIN_ENGINE_V2";
  string internal constant VAULT_ACTIONS_NAME = "MARGIN_ENGINE_V2_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev BaseManager's internal `whitelistedCallee` mapping (`forge inspect MarginEngineV1 storage-layout`): lets the
  ///      script confirm the callee it copies is v1's.
  uint internal constant WHITELISTED_CALLEE_SLOT = 12;

  /// @dev 2026-12-31 14:00 UTC: 15:00 in Lagos, inside NGN market hours, as v1's 30NOV26.
  uint64 internal constant DEFAULT_EXPIRY = 1798725600;
  /// @dev cNGN per contract: ~743 USDC at 0.000743, close to v1's 1,000 USDC, so caps and SecurityModule sizing stay
  ///      about the same in dollars.
  uint internal constant DEFAULT_CONTRACT_SIZE = 1_000_000e18;
  /// @dev Contracts over both sides: v1's 30, ~$22k at launch prices. Resize with the SecurityModule doc before opening.
  uint internal constant DEFAULT_FUTURE_OI_CAP = 30e18;

  uint internal constant FUTURE_MM_REQ = 0.15e18;
  uint internal constant FUTURE_IM_REQ = 0.25e18;

  uint internal constant MAX_MARK_DEVIATION = 0.05e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;
  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.1e18;
  uint internal constant MIN_MARK_INDEX_DEVIATION = 0.01e18;
  uint internal constant BAND_NARROWING_PERIOD = 14 days;
  uint internal constant MIN_MARK_INTERVAL = 1 hours;
  uint64 internal constant FORWARD_HEARTBEAT = 2 hours;
  uint internal constant FIXING_WINDOW = 1 hours;
  uint internal constant MAX_SAMPLE_GAP = 15 minutes;
  uint internal constant FALLBACK_DELAY = 24 hours;

  uint internal constant DEFAULT_INITIAL_MARK_TOLERANCE = 0.02e18;
  uint internal constant MAX_CARRY = 1e18;

  /// @dev v1's market names, by id: the chain keeps them only in MarketCreated. Market 1 from deploy-margin-engine.s.sol,
  ///      market 2 from eurc-spot-batch.sol.
  function marketName(uint id) public pure returns (string memory) {
    if (id == 1) return "NGN";
    if (id == 2) return "EUR";
    revert("v1 lists a market this script does not know: add its name");
  }

  /// @dev one base-asset market of v1's, as v2 lists it (memory only: Params keeps them as parallel arrays, which a
  ///      test can hold in storage)
  struct BaseMarket {
    string name;
    address escrow;
    address spotFeed;
    uint escrowCap;
  }

  struct Params {
    address subAccounts;
    address vault;
    address v1;
    address cash;
    address auction;
    address tradeModule;
    address guardian;
    address indexFeed;
    /// @dev one entry per v1 market, by id - 1: its base escrow, spot feed and v1's cap on the escrow
    address[] escrows;
    address[] spotFeeds;
    uint[] escrowCaps;
    uint64 expiry;
    uint64 lastTradeTime;
    uint contractSize;
    uint initialMark;
    uint carry;
    uint initialMarkTolerance;
    uint futureOICap;
    address forwardSigner;
  }

  struct Deployment {
    MarginEngine engine;
    MarginEnginePortfolioViewer viewer;
    FutureAsset future;
    LyraForwardFeed forwardFeed;
    uint96 subId;
    uint poolAccount;
  }

  function _market(Params memory params, uint i) internal pure returns (BaseMarket memory) {
    return BaseMarket({
      name: marketName(i + 1), escrow: params.escrows[i], spotFeed: params.spotFeeds[i], escrowCap: params.escrowCaps[i]
    });
  }

  function run() external {
    Params memory params = loadParams();
    if (msg.sender == FORGE_DEFAULT_SENDER) {
      revert("run with --account <keystore> (or --private-key): no sender given");
    }
    // Forge deploys the linked FutureVMLib from the deployer before run(): a fresh key arrives with nonce 1.
    if (vm.getNonce(msg.sender) > 1) revert("deployer key must be single use: it has sent transactions before");

    vm.startBroadcast();
    Deployment memory d = deploy(params);
    vm.stopBroadcast();

    assertDeployment(d, params);
    _writeArtifacts(d, params);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  /// @dev The operator's inputs from the environment over the chain's, then checked.
  function loadParams() public view returns (Params memory params) {
    params = loadChainParams();
    params.expiry = uint64(vm.envOr("EXPIRY", uint(params.expiry)));
    params.lastTradeTime = uint64(vm.envOr("LAST_TRADE_TIME", uint(params.expiry - FIXING_WINDOW)));
    params.contractSize = vm.envOr("CONTRACT_SIZE", params.contractSize);
    params.initialMark = vm.envUint("INITIAL_MARK");
    params.carry = vm.envUint("CARRY");
    params.initialMarkTolerance = vm.envOr("INITIAL_MARK_TOLERANCE", params.initialMarkTolerance);
    params.futureOICap = vm.envOr("FUTURE_OI_CAP", params.futureOICap);
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");

    checkParams(params);
  }

  /**
   * @dev Everything read from the chain and the v1 artifact, with the defaults; no environment, no checks. The fork test
   *      builds on this and supplies the operator's inputs itself: forge runs suites in parallel in one process, and a
   *      suite writing INITIAL_MARK races deploy-margin-engine.s.sol's suites, which read the same name in v1's units.
   */
  function loadChainParams() public view returns (Params memory params) {
    string memory v1 = _readDeploymentFile("MARGIN_ENGINE");
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.v1 = vm.parseJsonAddress(v1, ".manager");
    params.tradeModule = vm.parseJsonAddress(v1, ".perpTradeModule");

    MarginEngineV1 engine = MarginEngineV1(params.v1);
    params.cash = address(engine.cashAsset());
    params.auction = address(engine.liquidation());
    params.guardian = engine.guardian();
    (ISpotFeed index,,) = engine.getMarketFeeds(1);
    params.indexFeed = address(index);

    uint last = engine.lastMarketId();
    params.escrows = new address[](last);
    params.spotFeeds = new address[](last);
    params.escrowCaps = new uint[](last);
    for (uint id = 1; id <= last; ++id) {
      address escrow = address(engine.assetMap(id, IMarginEngine.AssetType.Base));
      (ISpotFeed spot,,) = engine.getMarketFeeds(id);
      params.escrows[id - 1] = escrow;
      params.spotFeeds[id - 1] = address(spot);
      params.escrowCaps[id - 1] =
        escrow == address(0) ? 0 : WrappedERC20Asset(escrow).totalPositionCap(IManager(params.v1));
    }

    params.expiry = DEFAULT_EXPIRY;
    params.lastTradeTime = DEFAULT_EXPIRY - uint64(FIXING_WINDOW);
    params.contractSize = DEFAULT_CONTRACT_SIZE;
    params.initialMarkTolerance = DEFAULT_INITIAL_MARK_TOLERANCE;
    params.futureOICap = DEFAULT_FUTURE_OI_CAP;
  }

  /// @dev Each check is a way the deployment lands and then cannot be governed, trade, or settle.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    MarginEngineV1 v1 = MarginEngineV1(params.v1);
    if (v1.owner() != params.vault) revert("v1 engine is not owned by the vault");
    if (CashAsset(params.cash).owner() != params.vault) revert("cash is not owned by the vault");
    if (DutchAuction(params.auction).owner() != params.vault) revert("auction is not owned by the vault");
    if (params.escrows.length == 0) revert("v1 lists no market");
    for (uint i = 0; i < params.escrows.length; ++i) {
      BaseMarket memory m = _market(params, i);
      if (m.escrow == address(0)) revert("a v1 market has no base asset");
      if (WrappedERC20Asset(m.escrow).owner() != params.vault) revert("an escrow is not owned by the vault");
      if (m.spotFeed == address(0)) revert("a v1 market has no spot feed");
      if (m.escrowCap == 0) revert("an escrow is closed under v1: nothing to copy");
    }
    if (params.spotFeeds[0] != params.indexFeed) revert("market 1's spot feed is not the index");
    bytes32 slot = keccak256(abi.encode(params.indexFeed, WHITELISTED_CALLEE_SLOT));
    if (uint(vm.load(params.v1, slot)) != 1) revert("the index is not a whitelisted callee on v1");
    if (params.guardian == address(0) || params.guardian == params.vault) revert("v1 guardian unset or the vault");
    if (ITradeModuleQuote(params.tradeModule).quoteAsset() != params.cash) {
      revert("trade module quote is not the cash");
    }
    if (ITradeModuleQuote(params.tradeModule).owner() != params.vault) {
      revert("trade module is not owned by the vault");
    }

    if (params.expiry <= block.timestamp + FIXING_WINDOW) revert("expiry too soon");
    if (params.lastTradeTime >= params.expiry || params.lastTradeTime > params.expiry - FIXING_WINDOW) {
      revert("last trade must be no later than the fixing window's start");
    }
    if (params.contractSize == 0) revert("CONTRACT_SIZE is zero");
    if (params.futureOICap == 0) revert("FUTURE_OI_CAP is zero");

    if (params.forwardSigner == address(0)) revert("FORWARD_SIGNER is zero");
    if (params.forwardSigner == params.vault) revert("FORWARD_SIGNER must not be the vault");
    if (LyraSpotFeed(params.indexFeed).isSigner(params.forwardSigner)) {
      revert("FORWARD_SIGNER must not also sign the index");
    }
    if (params.initialMark == 0) revert("INITIAL_MARK is zero");
    if (params.carry > MAX_CARRY) revert("CARRY over 100% a year: give it 18dp (0.2e18 for 20%)");
    if (params.initialMarkTolerance == 0 || params.initialMarkTolerance > MAX_MARK_INDEX_DEVIATION) {
      revert("INITIAL_MARK_TOLERANCE out of range");
    }
    if (_outside(params.initialMark, indexPrice(params), MAX_MARK_INDEX_DEVIATION)) {
      revert("INITIAL_MARK is outside the index band");
    }
    if (_outside(params.initialMark, fairForward(params), params.initialMarkTolerance)) {
      revert("INITIAL_MARK is outside the band around index / (1 + carry * tau)");
    }
  }

  /// @dev USDC per cNGN, the feed's own units and the future's: read as is.
  function indexPrice(Params memory params) public view returns (uint index) {
    (index,) = ISpotFeed(params.indexFeed).getSpot();
  }

  /// @dev index / (1 + carry * tau), tau = years from now to expiry: cNGN at its forward discount.
  function fairForward(Params memory params) public view returns (uint) {
    uint index = indexPrice(params);
    uint tau = uint(params.expiry - block.timestamp);
    return index * 1e18 / (1e18 + params.carry * tau / 365 days);
  }

  function _outside(uint price, uint reference_, uint band) internal pure returns (bool) {
    uint diff = price > reference_ ? price - reference_ : reference_ - price;
    return diff * 1e18 > reference_ * band;
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployment memory d) {
    SubAccounts subAccounts = SubAccounts(params.subAccounts);

    d.viewer = new MarginEnginePortfolioViewer(subAccounts, ICashAsset(params.cash));
    d.engine = new MarginEngine(subAccounts, ICashAsset(params.cash), IDutchAuction(params.auction), d.viewer);
    d.viewer.setMarginEngine(d.engine);
    d.poolAccount = d.engine.accId();

    _copyV1Settings(d, params);
    _deployFuture(d, params);

    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      IOwnable2Step(owned[i]).transferOwnership(params.vault);
    }
  }

  /// @dev Everything v2 shares with v1, copied from it: each base market at the same id, and the account-wide settings.
  ///      assertParity checks the result.
  function _copyV1Settings(Deployment memory d, Params memory params) internal {
    MarginEngineV1 v1 = MarginEngineV1(params.v1);
    MarginEngine engine = d.engine;
    if (v1.feeRecipientAcc() != 0 || v1.minOIFee() != 0) revert("v1 charges OI fees: copy its fee settings too");

    engine.setMaxAccountSize(v1.maxAccountSize());
    engine.setBorrowingEnabled(v1.borrowingEnabled());
    engine.setStableFeed(v1.stableFeed());
    {
      (uint threshold, uint factor) = v1.depegParams();
      engine.setDepegParameters(IMarginEngine.DepegParams({threshold: threshold, depegFactor: factor}));
    }
    for (uint i = 0; i < params.escrows.length; ++i) {
      BaseMarket memory m = _market(params, i);
      uint id = engine.createMarket(m.name);
      if (id != i + 1) revert("market ids diverged from v1's");
      engine.whitelistAsset(IAsset(m.escrow), id, IMarginEngine.AssetType.Base);
      engine.setOraclesForMarket(id, ISpotFeed(m.spotFeed), IForwardFeed(address(0)), IVolFeed(address(0)));
      (uint factor, uint imScale) = v1.baseMarginParams(id);
      engine.setBaseAssetMarginFactor(id, factor, imScale);
      (uint perpT, uint optionT, uint baseT, uint ocFactor) = v1.oracleContingencyParams(id);
      engine.setOracleContingencyParams(
        id,
        IMarginEngine.OracleContingencyParams({
          perpThreshold: perpT, optionThreshold: optionT, baseThreshold: baseT, OCFactor: ocFactor
        })
      );
    }
    // The index is the only callee: the perp's mark and impact feeds stay with v1, which alone lists the perp.
    engine.setWhitelistedCallee(params.indexFeed, true);
  }

  /// @dev The future: closed, marked from its own forward feed, fixed from the index, listed on market 1.
  function _deployFuture(Deployment memory d, Params memory params) internal {
    d.future = new FutureAsset(SubAccounts(params.subAccounts), params.contractSize);
    d.future.setWhitelistManager(address(d.engine), true);
    d.future.setTotalPositionCap(d.engine, 0);
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
    // No OI fee: the TradeModule's taker fee is the venue's fee.
    d.viewer.setOIFeeRateBPS(address(d.future), 0);

    d.engine.whitelistAsset(IAsset(address(d.future)), 1, IMarginEngine.AssetType.Future);
    d.engine.setFutureMarginRequirements(1, FUTURE_MM_REQ, FUTURE_IM_REQ);
  }

  function ownedContracts(Deployment memory d) public pure returns (address[] memory owned) {
    owned = new address[](4);
    owned[0] = address(d.engine);
    owned[1] = address(d.viewer);
    owned[2] = address(d.future);
    owned[3] = address(d.forwardFeed);
  }

  // ---------------------------------------------------------------------------------------------
  // postconditions
  // ---------------------------------------------------------------------------------------------

  function assertDeployment(Deployment memory d, Params memory params) public view {
    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      if (IOwnable2Step(owned[i]).pendingOwner() != params.vault) revert("contract not nominated to vault");
    }
    assertParity(d, params);

    MarginEngine engine = d.engine;
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not v1's");
    if (address(engine.liquidation()) != params.auction) revert("engine liquidation is not v1's auction");
    if (address(d.viewer.marginEngine()) != address(engine)) revert("viewer does not read the engine");
    if (address(engine.assetMap(1, IMarginEngine.AssetType.Future)) != address(d.future)) revert("future not listed");
    if (address(engine.assetMap(1, IMarginEngine.AssetType.Perpetual)) != address(0)) revert("v2 lists no perp");
    (uint mm, uint im) = engine.futureMarginRequirements(1);
    if (mm != FUTURE_MM_REQ || im != FUTURE_IM_REQ) revert("future margin not set");

    SubAccounts subAccounts = SubAccounts(params.subAccounts);
    if (subAccounts.ownerOf(d.poolAccount) != address(engine)) revert("pool not owned by the engine");
    if (address(subAccounts.manager(d.poolAccount)) != address(engine)) revert("pool not under the engine");

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

    // Nothing reused is changed by the deployer: wiring is the vault's.
    if (CashAsset(params.cash).whitelistedManager(address(engine))) revert("cash wired before the vault batch");
    for (uint i = 0; i < params.escrows.length; ++i) {
      if (WrappedERC20Asset(params.escrows[i]).whitelistedManager(address(engine))) {
        revert("escrow wired early");
      }
    }
    if (engine.guardian() != address(0)) revert("guardian is the vault batch's to set");
  }

  /// @dev Each market on v2 margins its base exactly as the same market on v1 does.
  function assertParity(Deployment memory d, Params memory params) public view {
    MarginEngineV1 v1 = MarginEngineV1(params.v1);
    MarginEngine engine = d.engine;
    if (engine.lastMarketId() != v1.lastMarketId()) revert("parity: markets");
    if (engine.maxAccountSize() != v1.maxAccountSize()) revert("parity: maxAccountSize");
    if (engine.borrowingEnabled() != v1.borrowingEnabled()) revert("parity: borrowingEnabled");
    if (address(engine.stableFeed()) != address(v1.stableFeed())) revert("parity: stableFeed");
    {
      (uint a1, uint a2) = engine.depegParams();
      (uint b1, uint b2) = v1.depegParams();
      if (a1 != b1 || a2 != b2) revert("parity: depeg");
    }
    for (uint id = 1; id <= engine.lastMarketId(); ++id) {
      {
        (uint a1, uint a2) = engine.baseMarginParams(id);
        (uint b1, uint b2) = v1.baseMarginParams(id);
        if (a1 != b1 || a2 != b2) revert("parity: base margin");
      }
      {
        (uint a1, uint a2, uint a3, uint a4) = engine.oracleContingencyParams(id);
        (uint b1, uint b2, uint b3, uint b4) = v1.oracleContingencyParams(id);
        if (a1 != b1 || a2 != b2 || a3 != b3 || a4 != b4) revert("parity: oracle contingency");
      }
      IAsset base = engine.assetMap(id, IMarginEngine.AssetType.Base);
      if (address(base) != address(v1.assetMap(id, IMarginEngine.AssetType.Base))) revert("parity: base");
      (ISpotFeed a,,) = engine.getMarketFeeds(id);
      (ISpotFeed b,,) = v1.getMarketFeeds(id);
      if (address(a) != address(b)) revert("parity: spot feed");
    }
    if (engine.feeRecipientAcc() != v1.feeRecipientAcc() || engine.minOIFee() != v1.minOIFee()) {
      revert("parity: OI fees");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "margin-engine-v2";
    vm.serializeAddress(obj, "manager", address(d.engine));
    vm.serializeAddress(obj, "viewer", address(d.viewer));
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(obj, "forwardSigner", params.forwardSigner);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "v1", params.v1);
    vm.serializeString(obj, "units", "USDC per cNGN; contractSize in cNGN; VM in USDC cash");
    vm.serializeUint(obj, "futureMMReq", FUTURE_MM_REQ);
    vm.serializeUint(obj, "futureIMReq", FUTURE_IM_REQ);
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
    vm.serializeUint(obj, "marketId", 1);
    vm.serializeUint(obj, "poolAccount", d.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
    vm.serializeUint(obj, "carry", params.carry);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "auction", params.auction);
    vm.serializeAddress(obj, "guardian", params.guardian);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    address[] memory escrows = new address[](params.escrows.length);
    uint[] memory caps = new uint[](params.escrows.length);
    for (uint i = 0; i < params.escrows.length; ++i) {
      escrows[i] = params.escrows[i];
      caps[i] = params.escrowCaps[i];
    }
    vm.serializeAddress(obj, "escrows", escrows);
    vm.serializeUint(obj, "escrowCaps", caps);
    string memory json = vm.serializeUint(obj, "futureOICap", params.futureOICap);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  /// @dev Accept the four, wire v2 into the cash, every escrow at v1's cap, and the auction; grant v1's guardian.
  ///      Opens nothing: the future's cap stays 0.
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [margin engine v2]", owned[i], accept));
    }
    address engine = address(d.engine);
    bytes memory whitelist = abi.encodeWithSignature("setWhitelistManager(address,bool)", engine, true);
    json = string.concat(
      json, ",", _action("cash.setWhitelistManager(engineV2, true) [margin and VM in USDC]", params.cash, whitelist)
    );
    for (uint i = 0; i < params.escrows.length; ++i) {
      BaseMarket memory m = _market(params, i);
      json = string.concat(
        json,
        ",",
        _action(string.concat("escrow.setWhitelistManager(engineV2, true) [", m.name, " spot]"), m.escrow, whitelist),
        ",",
        _action(
          string.concat(
            "escrow.setTotalPositionCap(engineV2, ", vm.toString(m.escrowCap), ") [", m.name, ", v1's cap]"
          ),
          m.escrow,
          abi.encodeWithSignature("setTotalPositionCap(address,uint256)", engine, m.escrowCap)
        )
      );
    }
    json = string.concat(
      json,
      ",",
      _action("auction.setWhitelistManager(engineV2, true) [liquidation, SecurityModule]", params.auction, whitelist),
      ",",
      _action(
        string.concat("engineV2.setGuardian(", vm.toString(params.guardian), ") [v1's guardian: pause/unpause]"),
        engine,
        abi.encodeWithSignature("setGuardian(address)", params.guardian)
      ),
      "]"
    );
  }

  function vaultActionCount(Deployment memory d, Params memory params) public pure returns (uint) {
    return ownedContracts(d).length + 1 + 2 * params.escrows.length + 2;
  }

  /// @dev Opens the future, then registers it on the TradeModule. Run last, on its own.
  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address engine = address(d.engine);
    json = string.concat(
      "[",
      _action(
        string.concat(
          "future.setTotalPositionCap(engineV2, ", vm.toString(params.futureOICap), ") [opens cNGN future]"
        ),
        address(d.future),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", engine, params.futureOICap)
      ),
      ",",
      _action(
        "tradeModule.setDatedFutureAsset(future, true) [fills carry their price to the future, no quote leg]",
        params.tradeModule,
        abi.encodeWithSignature("setDatedFutureAsset(address,bool)", address(d.future), true)
      ),
      "]"
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 2;
  }

  /// @dev Digest is keccak(to ‖ keccak(data)), as deploy-margin-engine.s.sol's.
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
