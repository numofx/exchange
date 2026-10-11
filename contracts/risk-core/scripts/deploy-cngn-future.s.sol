// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {FutureManager} from "../src/risk-managers/FutureManager.sol";
import {BasePortfolioViewer} from "../src/risk-managers/BasePortfolioViewer.sol";
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
import {IManager} from "../src/interfaces/IManager.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleQuote {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
}

/**
 * @title DeployCngnFuture
 *
 * @dev A USDC/cNGN future, cash settled in cNGN, on its own FutureManager beside the perp SRM. It reuses
 *      the perp stack's pieces rather than duplicating them:
 *      - its USDC cash (CNGN_PERP_STACK.cash): margin, fees, and VM shortfalls settle in it;
 *      - its cNGN escrow (CNGN_PERP_COLLATERAL.escrow): the asset VM settles in, and cNGN collateral;
 *      - its index feed (rate-picker cNGN spot, USDC per cNGN): values cNGN, bands each mark, fixes settlement;
 *      - its DutchAuction, and so its SecurityModule: futures bad debt draws on the same fund as the perp's.
 *      The perp SRM is never called.
 *
 * @dev DEPLOYED CLOSED. The future's position cap is 0, which stops every path to a position, not just the venue.
 *      Nothing trades until the vault runs the ENABLE batch, which this script writes but does not count as part of
 *      the deployment.
 *
 * @dev OWNERSHIP. The deployer configures everything, then nominates the vault (Ownable2Step). The VAULT_ACTIONS
 *      batch accepts each, and wires the new manager into the perp stack's cash, escrow and auction, which the vault
 *      already owns. ENABLE_VAULT_ACTIONS opens the cap and registers the future on the perp TradeModule.
 *
 * @dev MARKS. A new LyraForwardFeed on the perp's index: forward = index + a signed per-expiry difference, published
 *      by FORWARD_SIGNER, a key of its own. Anyone may pull a mark from it, at most hourly. The index band then bounds
 *      what that signer can do, so it must not also sign the index: the script refuses one key for both.
 *
 * @dev UNITS. Prices are cNGN per USDC. The index and forward feeds are USDC per cNGN; the asset inverts them.
 *
 * @dev INITIAL MARK. Required, with the carry it is checked against: it must sit within INITIAL_MARK_TOLERANCE of
 *      index * (1 + CARRY * tau), tau the years to expiry. The 10% spot band (which every later mark must meet) is
 *      checked too.
 *
 * Usage (the deployer is forge's sender: a keystore account, never a key on the command line):
 *   INITIAL_MARK=<cNGN per USDC, 18dp, from the forward> CARRY=<annual NGN-over-USD carry, 18dp, e.g. 0.2e18> \
 *   FORWARD_SIGNER=<forward publisher key> \
 *     forge script scripts/deploy-cngn-future.s.sol --rpc-url $BASE_RPC_URL --account numo-deployer --broadcast
 *
 * Optional env (defaults below): EXPIRY, LAST_TRADE_TIME, CONTRACT_SIZE, FUTURE_OI_CAP, FUTURE_CNGN_CAP,
 *   INITIAL_MARK_TOLERANCE.
 */
contract DeployCngnFuture is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_NOV30_2026_FUTURE";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_NOV30_2026_FUTURE_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "CNGN_NOV30_2026_FUTURE_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  /// @dev The perp TradeModule, from contracts/execution/deployments/8453/CNGN_PERP_TRADE_MODULE.json (outside this
  ///      project's readable paths). Pinned, then checked against the chain: its quote must be the perp cash.
  address internal constant PERP_TRADE_MODULE = 0xDea968188598BA0E3F58A56C0fdfF338C74F699f;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev 2026-11-30 14:00 UTC: 15:00 in Lagos, inside NGN market hours, so the fixing window sees live venues.
  uint64 internal constant DEFAULT_EXPIRY = 1796047200;

  /// @dev USDC per contract.
  uint internal constant DEFAULT_CONTRACT_SIZE = 1_000e18;

  /// @dev Launch OI cap for the ENABLE batch, in contracts summed over both sides: 20 contracts a side, $20k.
  uint internal constant DEFAULT_FUTURE_OI_CAP = 40e18;

  /// @dev How much cNGN the escrow takes under the new manager: traders' collateral plus the pool reserve.
  uint internal constant DEFAULT_FUTURE_CNGN_CAP = 20_000_000e18;

  uint internal constant MM_REQ = 0.15e18;
  uint internal constant IM_REQ = 0.25e18;
  uint internal constant CNGN_MARGIN_FACTOR = 0.5e18;
  uint internal constant CNGN_IM_SCALE = 1e18;

  uint internal constant MAX_MARK_DEVIATION = 0.05e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;

  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.1e18;
  uint internal constant MIN_MARK_INDEX_DEVIATION = 0.01e18;
  uint internal constant BAND_NARROWING_PERIOD = 14 days;
  uint internal constant MIN_MARK_INTERVAL = 1 hours;
  /// @dev The forward goes stale after this, and pullMark with it: twice the pull interval, so one missed publish is
  ///      tolerated.
  uint64 internal constant FORWARD_HEARTBEAT = 2 hours;
  uint internal constant FIXING_WINDOW = 1 hours;
  uint internal constant MAX_SAMPLE_GAP = 15 minutes;
  uint internal constant FALLBACK_DELAY = 24 hours;

  uint internal constant MAX_ACCOUNT_SIZE = 48;

  /// @dev How far the initial mark may sit from index * (1 + carry * tau).
  uint internal constant DEFAULT_INITIAL_MARK_TOLERANCE = 0.02e18;

  /// @dev Carry above this is refused as a likely units error (e.g. 20 for 20%).
  uint internal constant MAX_CARRY = 1e18;

  struct Params {
    address subAccounts;
    address vault;
    address cash;
    address cngnEscrow;
    address indexFeed;
    address auction;
    address perpSrm;
    address perpTradeModule;
    uint64 expiry;
    uint64 lastTradeTime;
    uint contractSize;
    uint initialMark;
    /// @dev annual NGN-over-USD carry, 18dp
    uint carry;
    uint initialMarkTolerance;
    uint futureOICap;
    uint futureCngnCap;
    address forwardSigner;
  }

  struct Deployment {
    FutureAsset future;
    BasePortfolioViewer viewer;
    FutureManager manager;
    LyraForwardFeed forwardFeed;
    uint96 subId;
    uint poolAccount;
  }

  function run() external {
    Params memory params = loadParams();
    if (msg.sender == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");

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
    params.auction = vm.parseJsonAddress(stack, ".auction");
    params.indexFeed = vm.parseJsonAddress(stack, ".indexFeed");
    params.perpSrm = vm.parseJsonAddress(stack, ".srm");
    params.cngnEscrow = vm.parseJsonAddress(collateral, ".escrow");
    params.perpTradeModule = PERP_TRADE_MODULE;

    params.expiry = uint64(vm.envOr("EXPIRY", uint(DEFAULT_EXPIRY)));
    params.lastTradeTime = uint64(vm.envOr("LAST_TRADE_TIME", uint(params.expiry - FIXING_WINDOW)));
    params.contractSize = vm.envOr("CONTRACT_SIZE", DEFAULT_CONTRACT_SIZE);
    params.initialMark = vm.envUint("INITIAL_MARK");
    params.carry = vm.envUint("CARRY");
    params.initialMarkTolerance = vm.envOr("INITIAL_MARK_TOLERANCE", DEFAULT_INITIAL_MARK_TOLERANCE);
    params.futureOICap = vm.envOr("FUTURE_OI_CAP", DEFAULT_FUTURE_OI_CAP);
    params.futureCngnCap = vm.envOr("FUTURE_CNGN_CAP", DEFAULT_FUTURE_CNGN_CAP);
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");

    checkParams(params);
  }

  /// @dev Each check is a way the deployment lands and then cannot be governed, trade, or settle.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    // Every reused contract must already belong to the vault, or the batch that wires them cannot run.
    if (CashAsset(params.cash).owner() != params.vault) revert("perp cash is not owned by the vault");
    if (WrappedERC20Asset(params.cngnEscrow).owner() != params.vault) revert("cNGN escrow is not owned by the vault");
    if (DutchAuction(params.auction).owner() != params.vault) revert("perp auction is not owned by the vault");
    // The pieces must be one stack: the perp SRM settles in this cash and takes this escrow.
    if (address(StandardManager(params.perpSrm).cashAsset()) != params.cash) revert("cash is not the perp srm's");
    if (!WrappedERC20Asset(params.cngnEscrow).whitelistedManager(params.perpSrm)) {
      revert("escrow is not the perp srm's");
    }
    // Fees on futures fills are charged in the module's quote asset, which the manager must hold.
    if (ITradeModuleQuote(params.perpTradeModule).quoteAsset() != params.cash) revert("trade module quote is not the cash");
    if (ITradeModuleQuote(params.perpTradeModule).owner() != params.vault) revert("trade module is not owned by the vault");
    (ISpotFeed spot,,) = StandardManager(params.perpSrm).getMarketFeeds(1);
    if (address(spot) != params.indexFeed) revert("index feed is not the perp market's");

    if (params.expiry <= block.timestamp + FIXING_WINDOW) revert("expiry too soon");
    if (params.lastTradeTime >= params.expiry || params.lastTradeTime > params.expiry - FIXING_WINDOW) {
      revert("last trade must be no later than the fixing window's start");
    }
    if (params.contractSize == 0) revert("CONTRACT_SIZE is zero");
    if (params.futureOICap == 0) revert("FUTURE_OI_CAP is zero");
    if (params.futureCngnCap == 0) revert("FUTURE_CNGN_CAP is zero");

    if (params.forwardSigner == address(0)) revert("FORWARD_SIGNER is zero");
    if (params.forwardSigner == params.vault) revert("FORWARD_SIGNER must not be the vault");
    // The index band is what bounds a bad forward. It only does if the index is signed by someone else.
    if (LyraSpotFeed(params.indexFeed).isSigner(params.forwardSigner)) {
      revert("FORWARD_SIGNER must not also sign the index");
    }
    if (params.initialMark == 0) revert("INITIAL_MARK is zero");
    if (params.carry > MAX_CARRY) revert("CARRY over 100% a year: give it 18dp (0.2e18 for 20%)");
    if (params.initialMarkTolerance == 0 || params.initialMarkTolerance > MAX_MARK_INDEX_DEVIATION) {
      revert("INITIAL_MARK_TOLERANCE out of range");
    }

    uint index = indexPrice(params);
    // The first daily mark is banded against the spot index; an initial mark outside it cannot be followed by one.
    if (_outside(params.initialMark, index, MAX_MARK_INDEX_DEVIATION)) revert("INITIAL_MARK is outside the index band");
    // And it must be the forward the carry implies, not just near spot.
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

    d.future = new FutureAsset(subAccounts, params.contractSize);
    d.viewer = new BasePortfolioViewer(subAccounts, ICashAsset(params.cash));
    d.manager = new FutureManager(
      subAccounts,
      ICashAsset(params.cash),
      IDutchAuction(params.auction),
      d.viewer,
      IFutureAsset(address(d.future)),
      IAsset(params.cngnEscrow),
      ISpotFeed(params.indexFeed)
    );
    d.poolAccount = d.manager.accId();

    d.manager.setMarginParams(
      FutureManager.MarginParams({
        mmReq: MM_REQ, imReq: IM_REQ, cngnMarginFactor: CNGN_MARGIN_FACTOR, cngnIMScale: CNGN_IM_SCALE
      })
    );
    d.manager.setMaxAccountSize(MAX_ACCOUNT_SIZE);

    d.future.setWhitelistManager(address(d.manager), true);
    // Closed: see DEPLOYED CLOSED.
    d.future.setTotalPositionCap(d.manager, 0);
    d.future.setMarkBounds(MAX_MARK_DEVIATION, MAX_MARK_DELAY);
    d.future.setIndexParams(
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

    // No OI fee: the TradeModule's taker fee is the venue's fee. Explicit so the artifact states it.
    d.viewer.setOIFeeRateBPS(address(d.future), 0);

    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      IOwnable2Step(owned[i]).transferOwnership(params.vault);
    }
  }

  function ownedContracts(Deployment memory d) public pure returns (address[] memory owned) {
    owned = new address[](4);
    owned[0] = address(d.future);
    owned[1] = address(d.viewer);
    owned[2] = address(d.manager);
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

    if (address(d.manager.cashAsset()) != params.cash) revert("manager cash is not the perp cash");
    if (address(d.manager.cngnAsset()) != params.cngnEscrow) revert("manager does not settle in the escrow");
    if (address(d.manager.spotFeed()) != params.indexFeed) revert("manager does not value cNGN at the index");
    if (address(d.manager.liquidation()) != params.auction) revert("manager liquidation is not the perp auction");
    if (address(d.manager.future()) != address(d.future)) revert("manager future mismatch");

    (uint mm, uint im, uint factor, uint scale) = d.manager.marginParams();
    if (mm != MM_REQ || im != IM_REQ || factor != CNGN_MARGIN_FACTOR || scale != CNGN_IM_SCALE) {
      revert("margin params not set");
    }

    // The pool is the manager's own account, so only the manager moves it.
    SubAccounts subAccounts = SubAccounts(params.subAccounts);
    if (subAccounts.ownerOf(d.poolAccount) != address(d.manager)) revert("pool not owned by the manager");
    if (address(subAccounts.manager(d.poolAccount)) != address(d.manager)) revert("pool not under the manager");

    if (!d.future.whitelistedManager(address(d.manager))) revert("future does not whitelist the manager");
    if (d.future.totalPositionCap(d.manager) != 0) revert("future must deploy closed (cap 0)");
    if (address(d.future.indexFeed()) != params.indexFeed) revert("future index not set");
    if (d.future.maxMarkIndexDeviation() == 0 || d.future.maxMarkDeviation() == 0) revert("mark bounds not set");
    if (d.future.minMarkIndexDeviation() == 0 || d.future.bandNarrowingPeriod() == 0) revert("band does not narrow");

    // Marks come from the new forward feed, on the perp's index, signed by the forward key alone.
    if (address(d.future.forwardFeed()) != address(d.forwardFeed)) revert("future does not read the forward feed");
    if (d.future.minMarkInterval() == 0) revert("pulls are not rate limited");
    if (address(d.forwardFeed.spotFeed()) != params.indexFeed) revert("forward feed is not on the index");
    if (!d.forwardFeed.isSigner(params.forwardSigner)) revert("forward feed missing its signer");
    // msg.sender is the deployer when run() calls this
    if (d.forwardFeed.isSigner(msg.sender)) revert("deployer signs the forward feed");

    IFutureAsset.FutureContract memory c = d.future.futureContracts(d.subId);
    if (!c.listed || c.expiry != params.expiry || c.markPrice != params.initialMark) revert("contract not listed");

    // Nothing reused is changed by the deployer: wiring is the vault's.
    if (CashAsset(params.cash).whitelistedManager(address(d.manager))) revert("cash wired before the vault batch");
    if (WrappedERC20Asset(params.cngnEscrow).whitelistedManager(address(d.manager))) {
      revert("escrow wired before the vault batch");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployment memory d, Params memory params) internal {
    string memory obj = "cngn-future";
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "viewer", address(d.viewer));
    vm.serializeAddress(obj, "manager", address(d.manager));
    vm.serializeAddress(obj, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(obj, "forwardSigner", params.forwardSigner);
    vm.serializeUint(obj, "poolAccount", d.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
    vm.serializeUint(obj, "carry", params.carry);
    vm.serializeUint(obj, "initialMarkTolerance", params.initialMarkTolerance);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "cngnEscrow", params.cngnEscrow);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "auction", params.auction);
    vm.serializeAddress(obj, "perpTradeModule", params.perpTradeModule);
    vm.serializeUint(obj, "futureOICap", params.futureOICap);
    string memory json = vm.serializeUint(obj, "futureCngnCap", params.futureCngnCap);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(d, params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(d, params));
  }

  /// @dev Accept every contract, then wire the manager into the perp stack's cash, escrow and auction. Opens nothing.
  function vaultActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    address[] memory owned = ownedContracts(d);
    bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
    json = "[";
    for (uint i = 0; i < owned.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [cNGN future]", owned[i], accept));
    }
    address manager = address(d.manager);
    json = string.concat(
      json,
      ",",
      _action(
        "cash.setWhitelistManager(manager, true) [margin, fees and VM shortfalls in the perp's USDC cash]",
        params.cash,
        abi.encodeWithSignature("setWhitelistManager(address,bool)", manager, true)
      ),
      ",",
      _action(
        "escrow.setWhitelistManager(manager, true) [VM settles in this cNGN]",
        params.cngnEscrow,
        abi.encodeWithSignature("setWhitelistManager(address,bool)", manager, true)
      ),
      ",",
      _action(
        string.concat("escrow.setTotalPositionCap(manager, ", vm.toString(params.futureCngnCap), ") [cNGN under the manager]"),
        params.cngnEscrow,
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", manager, params.futureCngnCap)
      ),
      ",",
      _action(
        "auction.setWhitelistManager(manager, true) [futures liquidate through the perp auction and SecurityModule]",
        params.auction,
        abi.encodeWithSignature("setWhitelistManager(address,bool)", manager, true)
      ),
      "]"
    );
  }

  function vaultActionCount(Deployment memory d) public pure returns (uint) {
    return ownedContracts(d).length + 4;
  }

  /// @dev Opens the market: the position cap, then the future on the perp TradeModule. Run last, on its own.
  function enableActionsJson(Deployment memory d, Params memory params) public pure returns (string memory json) {
    json = string.concat(
      "[",
      _action(
        string.concat("future.setTotalPositionCap(manager, ", vm.toString(params.futureOICap), ") [opens the market]"),
        address(d.future),
        abi.encodeWithSignature("setTotalPositionCap(address,uint256)", address(d.manager), params.futureOICap)
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
    return 2;
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
