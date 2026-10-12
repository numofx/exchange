// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {PerpAsset} from "../src/assets/PerpAsset.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {MarginEnginePortfolioViewer} from "../src/risk-managers/MarginEnginePortfolioViewer.sol";
import {DutchAuction} from "../src/liquidation/DutchAuction.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {LyraForwardFeed} from "../src/feeds/LyraForwardFeed.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {ICashAsset} from "../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleQuote {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
}

/**
 * @title DeployMarginEngine
 *
 * @dev MarginEngine (a fork of StandardManager) beside the live perp SRM, with market 1 margining spot cNGN, the
 *      cNGN-PERP and a USDC/cNGN dated future cash settled in cNGN, in one account. The live SRM is read, never called:
 *      every market-1 setting the engine shares with it is copied from it and asserted equal, so the engine margins spot
 *      and the perp exactly as the SRM does. Reused, not duplicated: SubAccounts, the perp's USDC cash, the cNGN escrow,
 *      the perp, its index, mark and impact feeds, the DutchAuction and so the SecurityModule.
 *
 * @dev DEPLOYED CLOSED. The perp's and the future's caps under the engine are 0. The VAULT_ACTIONS batch accepts the four
 *      contracts and wires the engine into the cash, escrow, perp and auction; ENABLE_VAULT_ACTIONS opens the engine's
 *      perp and futures caps and registers the future on the TradeModule. Making the live SRM close-only is not in
 *      either: it is set to the live open interest at the time, once markets-service rejects orders that would
 *      increase it (a cap below open interest under the SRM's viewer freezes holders; see MarginEnginePortfolioViewer).
 *
 * @dev MARKS. A new LyraForwardFeed on the index: forward = index + a signed per-expiry difference, published by
 *      FORWARD_SIGNER, a key of its own. The script refuses one key for the forward and the index.
 *
 * @dev UNITS. Futures prices are cNGN per USDC; the index and forward feeds are USDC per cNGN.
 *
 * Usage (the deployer is forge's sender: a fresh keystore account, used for this deploy only, never a key on the
 * command line; the script refuses one that has sent a transaction before):
 *   INITIAL_MARK=<cNGN per USDC, 18dp> CARRY=<annual carry, 18dp> FORWARD_SIGNER=<forward key> \
 *     forge script scripts/deploy-margin-engine.s.sol --rpc-url $BASE_RPC_URL --account numo-deployer --broadcast
 *
 * Optional env: EXPIRY, LAST_TRADE_TIME, CONTRACT_SIZE, FUTURE_OI_CAP, ENGINE_CNGN_CAP, PERP_OI_CAP,
 *   INITIAL_MARK_TOLERANCE.
 */
contract DeployMarginEngine is Utils {
  string internal constant ARTIFACT_NAME = "MARGIN_ENGINE";
  string internal constant VAULT_ACTIONS_NAME = "MARGIN_ENGINE_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "MARGIN_ENGINE_ENABLE_VAULT_ACTIONS";
  string internal constant MARKET_NAME = "NGN";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  /// @dev The perp TradeModule (contracts/execution/deployments/8453/CNGN_PERP_TRADE_MODULE.json). Pinned, then checked
  ///      against the chain: its quote must be the perp cash.
  address internal constant PERP_TRADE_MODULE = 0xDea968188598BA0E3F58A56C0fdfF338C74F699f;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev BaseManager's `whitelistedCallee` mapping is internal; its slot (`forge inspect StandardManager storage-layout`)
  ///      lets the script confirm the callees it copies are the SRM's. CngnPerpStack feeds only.
  uint internal constant WHITELISTED_CALLEE_SLOT = 12;

  /// @dev 2026-11-30 14:00 UTC: 15:00 in Lagos, inside NGN market hours, so the fixing window sees live venues.
  uint64 internal constant DEFAULT_EXPIRY = 1796047200;
  /// @dev USDC per contract.
  uint internal constant DEFAULT_CONTRACT_SIZE = 1_000e18;
  /// @dev Futures OI cap for the ENABLE batch, in contracts over both sides: 15 a side, $15k. Sized to the
  ///      SecurityModule as it stands ($3,250): a 25% step on a full side at IM 25% is $2,812, ~$2,947 with the perp.
  uint internal constant DEFAULT_FUTURE_OI_CAP = 30e18;
  /// @dev The cNGN escrow's cap under the engine: spot and perp collateral, which the SRM caps at 50M today, plus the
  ///      futures' 50M (the ~6.1M pool reserve and a full futures book margined in cNGN, ~26.6M, with a reserve of
  ///      headroom on top). The pager's future-escrow-cap check pages when headroom falls under one reserve.
  uint internal constant DEFAULT_ENGINE_CNGN_CAP = 100_000_000e18;

  uint internal constant FUTURE_MM_REQ = 0.15e18;
  uint internal constant FUTURE_IM_REQ = 0.25e18;

  uint internal constant MAX_MARK_DEVIATION = 0.05e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;
  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.1e18;
  uint internal constant MIN_MARK_INDEX_DEVIATION = 0.01e18;
  uint internal constant BAND_NARROWING_PERIOD = 14 days;
  uint internal constant MIN_MARK_INTERVAL = 1 hours;
  /// @dev The forward goes stale after this, and pullMark with it: twice the pull interval, one missed publish tolerated
  uint64 internal constant FORWARD_HEARTBEAT = 2 hours;
  uint internal constant FIXING_WINDOW = 1 hours;
  uint internal constant MAX_SAMPLE_GAP = 15 minutes;
  uint internal constant FALLBACK_DELAY = 24 hours;

  uint internal constant DEFAULT_INITIAL_MARK_TOLERANCE = 0.02e18;
  uint internal constant MAX_CARRY = 1e18;

  struct Params {
    address subAccounts;
    address vault;
    address cash;
    address cngnEscrow;
    address perp;
    address indexFeed;
    address auction;
    address srm;
    address perpTradeModule;
    address guardian;
    address[] callees;
    uint64 expiry;
    uint64 lastTradeTime;
    uint contractSize;
    uint initialMark;
    uint carry;
    uint initialMarkTolerance;
    uint futureOICap;
    uint perpOICap;
    uint engineCngnCap;
    address forwardSigner;
  }

  struct Deployment {
    MarginEngine engine;
    MarginEnginePortfolioViewer viewer;
    FutureAsset future;
    LyraForwardFeed forwardFeed;
    uint marketId;
    uint96 subId;
    uint poolAccount;
  }

  function run() external {
    Params memory params = loadParams();
    if (msg.sender == FORGE_DEFAULT_SENDER) {
      revert("run with --account <keystore> (or --private-key): no sender given");
    }
    // The deployer owns everything until the vault accepts, and could change any setting in that window. A fresh key,
    // used for this deploy only and recorded in the artifact: the setup batch's parity check
    // (propose_margin_engine_batch.py) re-reads every setting once the vault owns it, checks the key has sent nothing
    // since the deploy, and the key is then retired. Forge deploys the linked FutureVMLib from the deployer before
    // run(), so a fresh key arrives here with nonce 1 (0 if that exact library build already exists on chain).
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

  function loadParams() public view returns (Params memory params) {
    string memory stack = _readDeploymentFile("CNGN_PERP_STACK");
    string memory collateral = _readDeploymentFile("CNGN_PERP_COLLATERAL");

    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.cash = vm.parseJsonAddress(stack, ".cash");
    params.perp = vm.parseJsonAddress(stack, ".perp");
    params.auction = vm.parseJsonAddress(stack, ".auction");
    params.indexFeed = vm.parseJsonAddress(stack, ".indexFeed");
    params.srm = vm.parseJsonAddress(stack, ".srm");
    params.cngnEscrow = vm.parseJsonAddress(collateral, ".escrow");
    params.perpTradeModule = PERP_TRADE_MODULE;
    params.guardian = StandardManager(params.srm).guardian();
    params.callees = new address[](4);
    params.callees[0] = params.indexFeed;
    params.callees[1] = vm.parseJsonAddress(stack, ".markFeed");
    params.callees[2] = vm.parseJsonAddress(stack, ".impactAskFeed");
    params.callees[3] = vm.parseJsonAddress(stack, ".impactBidFeed");

    params.expiry = uint64(vm.envOr("EXPIRY", uint(DEFAULT_EXPIRY)));
    params.lastTradeTime = uint64(vm.envOr("LAST_TRADE_TIME", uint(params.expiry - FIXING_WINDOW)));
    params.contractSize = vm.envOr("CONTRACT_SIZE", DEFAULT_CONTRACT_SIZE);
    params.initialMark = vm.envUint("INITIAL_MARK");
    params.carry = vm.envUint("CARRY");
    params.initialMarkTolerance = vm.envOr("INITIAL_MARK_TOLERANCE", DEFAULT_INITIAL_MARK_TOLERANCE);
    params.futureOICap = vm.envOr("FUTURE_OI_CAP", DEFAULT_FUTURE_OI_CAP);
    // the engine takes over the perp at the cap it has under the SRM, unless told otherwise
    params.perpOICap = vm.envOr("PERP_OI_CAP", PerpAsset(params.perp).totalPositionCap(StandardManager(params.srm)));
    params.engineCngnCap = vm.envOr("ENGINE_CNGN_CAP", DEFAULT_ENGINE_CNGN_CAP);
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");

    checkParams(params);
  }

  /// @dev Each check is a way the deployment lands and then cannot be governed, trade, or settle.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    // Every reused contract the batches wire must already belong to the vault.
    if (CashAsset(params.cash).owner() != params.vault) revert("perp cash is not owned by the vault");
    if (WrappedERC20Asset(params.cngnEscrow).owner() != params.vault) revert("cNGN escrow is not owned by the vault");
    if (PerpAsset(params.perp).owner() != params.vault) revert("perp is not owned by the vault");
    if (DutchAuction(params.auction).owner() != params.vault) revert("auction is not owned by the vault");
    // The pieces must be the live SRM's market 1: its cash, its perp, its base, its index.
    StandardManager srm = StandardManager(params.srm);
    if (address(srm.cashAsset()) != params.cash) revert("cash is not the srm's");
    if (address(srm.assetMap(1, IStandardManager.AssetType.Perpetual)) != params.perp) {
      revert("perp is not market 1's");
    }
    if (address(srm.assetMap(1, IStandardManager.AssetType.Base)) != params.cngnEscrow) {
      revert("escrow is not market 1's");
    }
    (ISpotFeed spot,,) = srm.getMarketFeeds(1);
    if (address(spot) != params.indexFeed) revert("index feed is not market 1's");
    if (address(srm.liquidation()) != params.auction) revert("auction is not the srm's");
    for (uint i = 0; i < params.callees.length; i++) {
      bytes32 slot = keccak256(abi.encode(params.callees[i], WHITELISTED_CALLEE_SLOT));
      if (uint(vm.load(params.srm, slot)) != 1) revert("a copied callee is not whitelisted on the srm");
    }
    if (params.guardian == address(0) || params.guardian == params.vault) revert("srm guardian unset or the vault");
    if (ITradeModuleQuote(params.perpTradeModule).quoteAsset() != params.cash) {
      revert("trade module quote is not the cash");
    }
    if (ITradeModuleQuote(params.perpTradeModule).owner() != params.vault) {
      revert("trade module is not owned by the vault");
    }

    if (params.expiry <= block.timestamp + FIXING_WINDOW) revert("expiry too soon");
    if (params.lastTradeTime >= params.expiry || params.lastTradeTime > params.expiry - FIXING_WINDOW) {
      revert("last trade must be no later than the fixing window's start");
    }
    if (params.contractSize == 0) revert("CONTRACT_SIZE is zero");
    if (params.futureOICap == 0) revert("FUTURE_OI_CAP is zero");
    if (params.perpOICap == 0) revert("PERP_OI_CAP is zero");
    if (params.engineCngnCap == 0) revert("ENGINE_CNGN_CAP is zero");

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
    uint index = indexPrice(params);
    if (_outside(params.initialMark, index, MAX_MARK_INDEX_DEVIATION)) {
      revert("INITIAL_MARK is outside the index band");
    }
    if (_outside(params.initialMark, fairForward(params), params.initialMarkTolerance)) {
      revert("INITIAL_MARK is outside the band around index * (1 + carry * tau)");
    }
  }

  /// @dev cNGN per USDC, from the feed's USDC per cNGN.
  function indexPrice(Params memory params) public view returns (uint) {
    (uint spotPrice,) = ISpotFeed(params.indexFeed).getSpot();
    return 1e36 / spotPrice;
  }

  /// @dev index * (1 + carry * tau), tau = years from now to expiry.
  function fairForward(Params memory params) public view returns (uint) {
    uint index = indexPrice(params);
    uint tau = uint(params.expiry - block.timestamp);
    return index + index * params.carry / 1e18 * tau / 365 days;
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
    d.marketId = d.engine.createMarket(MARKET_NAME);

    _copySrmSettings(d, params);
    _deployFuture(d, params);

    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      IOwnable2Step(owned[i]).transferOwnership(params.vault);
    }
  }

  /// @dev Everything the engine shares with the SRM, copied from it: market 1's perp, base and feeds, and the account-
  ///      wide settings. assertParity checks the result.
  function _copySrmSettings(Deployment memory d, Params memory params) internal {
    StandardManager srm = StandardManager(params.srm);
    MarginEngine engine = d.engine;
    if (srm.feeRecipientAcc() != 0 || srm.minOIFee() != 0) revert("srm charges OI fees: copy its fee settings too");

    engine.setMaxAccountSize(srm.maxAccountSize());
    engine.setBorrowingEnabled(srm.borrowingEnabled());
    engine.setStableFeed(srm.stableFeed());
    {
      (uint threshold, uint factor) = srm.depegParams();
      engine.setDepegParameters(IMarginEngine.DepegParams({threshold: threshold, depegFactor: factor}));
    }
    engine.whitelistAsset(IAsset(params.perp), d.marketId, IMarginEngine.AssetType.Perpetual);
    engine.whitelistAsset(IAsset(params.cngnEscrow), d.marketId, IMarginEngine.AssetType.Base);
    engine.setOraclesForMarket(d.marketId, ISpotFeed(params.indexFeed), IForwardFeed(address(0)), IVolFeed(address(0)));
    {
      (uint mm, uint im) = srm.perpMarginRequirements(1);
      engine.setPerpMarginRequirements(d.marketId, mm, im);
    }
    {
      (uint factor, uint imScale) = srm.baseMarginParams(1);
      engine.setBaseAssetMarginFactor(d.marketId, factor, imScale);
    }
    {
      (uint perpT, uint optionT, uint baseT, uint ocFactor) = srm.oracleContingencyParams(1);
      engine.setOracleContingencyParams(
        d.marketId,
        IMarginEngine.OracleContingencyParams({
          perpThreshold: perpT, optionThreshold: optionT, baseThreshold: baseT, OCFactor: ocFactor
        })
      );
    }
    for (uint i = 0; i < params.callees.length; i++) {
      engine.setWhitelistedCallee(params.callees[i], true);
    }
    // No OI fee on the perp, as on the SRM.
    d.viewer.setOIFeeRateBPS(params.perp, 0);
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

    d.engine.whitelistAsset(IAsset(address(d.future)), d.marketId, IMarginEngine.AssetType.Future);
    d.engine.setFutureMarginRequirements(d.marketId, FUTURE_MM_REQ, FUTURE_IM_REQ);
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
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the perp cash");
    if (address(engine.liquidation()) != params.auction) revert("engine liquidation is not the perp auction");
    if (address(d.viewer.marginEngine()) != address(engine)) revert("viewer does not read the engine");
    if (address(engine.assetMap(d.marketId, IMarginEngine.AssetType.Future)) != address(d.future)) {
      revert("future not listed");
    }
    (uint mm, uint im) = engine.futureMarginRequirements(d.marketId);
    if (mm != FUTURE_MM_REQ || im != FUTURE_IM_REQ) revert("future margin not set");

    // The pool is the engine's own account, so only the engine moves it.
    SubAccounts subAccounts = SubAccounts(params.subAccounts);
    if (subAccounts.ownerOf(d.poolAccount) != address(engine)) revert("pool not owned by the engine");
    if (address(subAccounts.manager(d.poolAccount)) != address(engine)) revert("pool not under the engine");

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
    if (WrappedERC20Asset(params.cngnEscrow).whitelistedManager(address(engine))) revert("escrow wired early");
    if (PerpAsset(params.perp).whitelistedManager(address(engine))) revert("perp wired before the vault batch");
    if (engine.guardian() != address(0)) revert("guardian is the vault batch's to set");
  }

  /// @dev Market 1 on the engine margins spot and the perp exactly as market 1 on the SRM does.
  function assertParity(Deployment memory d, Params memory params) public view {
    StandardManager srm = StandardManager(params.srm);
    MarginEngine engine = d.engine;
    uint m = d.marketId;
    if (engine.maxAccountSize() != srm.maxAccountSize()) revert("parity: maxAccountSize");
    if (engine.borrowingEnabled() != srm.borrowingEnabled()) revert("parity: borrowingEnabled");
    if (address(engine.stableFeed()) != address(srm.stableFeed())) revert("parity: stableFeed");
    {
      (uint a1, uint a2) = engine.depegParams();
      (uint b1, uint b2) = srm.depegParams();
      if (a1 != b1 || a2 != b2) revert("parity: depeg");
    }
    {
      (uint a1, uint a2) = engine.perpMarginRequirements(m);
      (uint b1, uint b2) = srm.perpMarginRequirements(1);
      if (a1 != b1 || a2 != b2) revert("parity: perp margin");
    }
    {
      (uint a1, uint a2) = engine.baseMarginParams(m);
      (uint b1, uint b2) = srm.baseMarginParams(1);
      if (a1 != b1 || a2 != b2) revert("parity: base margin");
    }
    {
      (uint a1, uint a2, uint a3, uint a4) = engine.oracleContingencyParams(m);
      (uint b1, uint b2, uint b3, uint b4) = srm.oracleContingencyParams(1);
      if (a1 != b1 || a2 != b2 || a3 != b3 || a4 != b4) revert("parity: oracle contingency");
    }
    if (address(engine.assetMap(m, IMarginEngine.AssetType.Perpetual)) != params.perp) revert("parity: perp");
    if (address(engine.assetMap(m, IMarginEngine.AssetType.Base)) != params.cngnEscrow) revert("parity: base");
    (ISpotFeed a,,) = engine.getMarketFeeds(m);
    (ISpotFeed b,,) = srm.getMarketFeeds(1);
    if (address(a) != address(b)) revert("parity: index feed");
    if (engine.feeRecipientAcc() != srm.feeRecipientAcc() || engine.minOIFee() != srm.minOIFee()) {
      revert("parity: OI fees");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "margin-engine";
    vm.serializeAddress(obj, "manager", address(d.engine));
    vm.serializeAddress(obj, "viewer", address(d.viewer));
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(obj, "forwardSigner", params.forwardSigner);
    vm.serializeAddress(obj, "deployer", msg.sender);
    // the deployer's nonce once the deploy is done: anything it sends afterwards, the parity check sees
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "callees", params.callees);
    // what the deploy set, so the setup batch can re-check it once the vault owns everything
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
    vm.serializeUint(obj, "marketId", d.marketId);
    vm.serializeUint(obj, "poolAccount", d.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
    vm.serializeUint(obj, "carry", params.carry);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "cngnEscrow", params.cngnEscrow);
    vm.serializeAddress(obj, "perp", params.perp);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "auction", params.auction);
    vm.serializeAddress(obj, "srm", params.srm);
    vm.serializeAddress(obj, "guardian", params.guardian);
    vm.serializeAddress(obj, "perpTradeModule", params.perpTradeModule);
    vm.serializeUint(obj, "futureOICap", params.futureOICap);
    vm.serializeUint(obj, "perpOICap", params.perpOICap);
    string memory json = vm.serializeUint(obj, "engineCngnCap", params.engineCngnCap);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  /// @dev Accept the four, wire the engine into the perp stack's cash, escrow, perp and auction, grant the guardian.
  ///      Opens nothing: the engine's caps stay 0.
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [margin engine]", owned[i], accept));
    }
    address engine = address(d.engine);
    bytes memory whitelist = abi.encodeWithSignature("setWhitelistManager(address,bool)", engine, true);
    json = string.concat(
      json,
      ",",
      _action(
        "cash.setWhitelistManager(engine, true) [margin, PnL and VM shortfalls in the perp cash]",
        params.cash,
        whitelist
      ),
      ",",
      _action(
        "escrow.setWhitelistManager(engine, true) [spot cNGN, collateral, futures VM]", params.cngnEscrow, whitelist
      ),
      ",",
      _action(
        string.concat(
          "escrow.setTotalPositionCap(engine, ", vm.toString(params.engineCngnCap), ") [cNGN under the engine]"
        ),
        params.cngnEscrow,
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", engine, params.engineCngnCap)
      ),
      ",",
      _action(
        "perp.setWhitelistManager(engine, true) [the perp under the engine, cap still 0]", params.perp, whitelist
      ),
      ",",
      _action(
          "auction.setWhitelistManager(engine, true) [liquidation and the SecurityModule]", params.auction, whitelist
        ),
      ",",
      _action(
        string.concat("engine.setGuardian(", vm.toString(params.guardian), ") [the SRM's guardian: pause/unpause]"),
        engine,
        abi.encodeWithSignature("setGuardian(address)", params.guardian)
      ),
      "]"
    );
  }

  function vaultActionCount(Deployment memory d) public pure returns (uint) {
    return ownedContracts(d).length + 6;
  }

  /// @dev Opens the engine: the perp, then the future, then the future on the TradeModule. Run last, on its own.
  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address engine = address(d.engine);
    json = string.concat(
      "[",
      _action(
        string.concat("perp.setTotalPositionCap(engine, ", vm.toString(params.perpOICap), ") [opens the perp]"),
        params.perp,
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", engine, params.perpOICap)
      ),
      ",",
      _action(
        string.concat("future.setTotalPositionCap(engine, ", vm.toString(params.futureOICap), ") [opens the future]"),
        address(d.future),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", engine, params.futureOICap)
      ),
      ",",
      _action(
        "tradeModule.setDatedFutureAsset(future, true) [fills carry their price to the future, no quote leg]",
        params.perpTradeModule,
        abi.encodeWithSignature("setDatedFutureAsset(address,bool)", address(d.future), true)
      ),
      "]"
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 3;
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
}
