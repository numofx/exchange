// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SubAccounts} from "../src/SubAccounts.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {DatedFutureAsset} from "../src/assets/DatedFutureAsset.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {DatedFutureManager} from "../src/risk-managers/DatedFutureManager.sol";
import {BasePortfolioViewer} from "../src/risk-managers/BasePortfolioViewer.sol";
import {DutchAuction} from "../src/liquidation/DutchAuction.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {ICashAsset} from "../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IDatedFutureAsset} from "../src/interfaces/IDatedFutureAsset.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IManager} from "../src/interfaces/IManager.sol";

import {Utils, IOwnable2Step} from "./utils.sol";

interface ITradeModuleQuote {
  function quoteAsset() external view returns (address);
  function owner() external view returns (address);
}

/**
 * @title DeployCngnDatedFuture
 *
 * @dev A USDC/cNGN dated future, cash settled in cNGN, on its own DatedFutureManager beside the perp SRM. It reuses
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
 * @dev UNITS. Prices are cNGN per USDC. The index feed is USDC per cNGN; the asset inverts it.
 *
 * Usage (the deployer is forge's sender: a keystore account, never a key on the command line):
 *   INITIAL_MARK=<cNGN per USDC, 18dp, from the forward> \
 *     forge script scripts/deploy-cngn-dated-future.s.sol --rpc-url $BASE_RPC_URL --account numo-deployer --broadcast
 *
 * Optional env (defaults below): EXPIRY, LAST_TRADE_TIME, CONTRACT_SIZE, FUTURE_OI_CAP, FUTURE_CNGN_CAP.
 */
contract DeployCngnDatedFuture is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_NOV30_2026_DATED_FUTURE";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_NOV30_2026_DATED_FUTURE_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "CNGN_NOV30_2026_DATED_FUTURE_ENABLE_VAULT_ACTIONS";

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
  uint internal constant IM_REQ = 0.2e18;
  uint internal constant CNGN_MARGIN_FACTOR = 0.5e18;
  uint internal constant CNGN_IM_SCALE = 1e18;

  uint internal constant MAX_MARK_DEVIATION = 0.05e18;
  uint internal constant MAX_MARK_DELAY = 10 minutes;

  uint internal constant MAX_MARK_INDEX_DEVIATION = 0.1e18;
  uint internal constant FIXING_WINDOW = 1 hours;
  uint internal constant MAX_SAMPLE_GAP = 15 minutes;
  uint internal constant FALLBACK_DELAY = 24 hours;

  uint internal constant MAX_ACCOUNT_SIZE = 48;

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
    uint futureOICap;
    uint futureCngnCap;
  }

  struct Deployment {
    DatedFutureAsset future;
    BasePortfolioViewer viewer;
    DatedFutureManager manager;
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
    params.futureOICap = vm.envOr("FUTURE_OI_CAP", DEFAULT_FUTURE_OI_CAP);
    params.futureCngnCap = vm.envOr("FUTURE_CNGN_CAP", DEFAULT_FUTURE_CNGN_CAP);

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

    // The first daily mark is banded against the index; an initial mark outside the band cannot be followed by one.
    if (params.initialMark == 0) revert("INITIAL_MARK is zero");
    (uint spotPrice,) = ISpotFeed(params.indexFeed).getSpot();
    uint index = 1e36 / spotPrice;
    uint diff = params.initialMark > index ? params.initialMark - index : index - params.initialMark;
    if (diff * 1e18 > index * MAX_MARK_INDEX_DEVIATION) revert("INITIAL_MARK is outside the index band");
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployment memory d) {
    SubAccounts subAccounts = SubAccounts(params.subAccounts);

    d.future = new DatedFutureAsset(subAccounts, params.contractSize);
    d.viewer = new BasePortfolioViewer(subAccounts, ICashAsset(params.cash));
    d.manager = new DatedFutureManager(
      subAccounts,
      ICashAsset(params.cash),
      IDutchAuction(params.auction),
      d.viewer,
      IDatedFutureAsset(address(d.future)),
      IAsset(params.cngnEscrow),
      ISpotFeed(params.indexFeed)
    );
    d.poolAccount = d.manager.accId();

    d.manager.setMarginParams(
      DatedFutureManager.MarginParams({
        mmReq: MM_REQ, imReq: IM_REQ, cngnMarginFactor: CNGN_MARGIN_FACTOR, cngnIMScale: CNGN_IM_SCALE
      })
    );
    d.manager.setMaxAccountSize(MAX_ACCOUNT_SIZE);

    d.future.setWhitelistManager(address(d.manager), true);
    // Closed: see DEPLOYED CLOSED.
    d.future.setTotalPositionCap(d.manager, 0);
    d.future.setMarkBounds(MAX_MARK_DEVIATION, MAX_MARK_DELAY);
    d.future.setIndexParams(
      ISpotFeed(params.indexFeed), MAX_MARK_INDEX_DEVIATION, FIXING_WINDOW, MAX_SAMPLE_GAP, FALLBACK_DELAY
    );
    d.subId = d.future.setContract(params.expiry, params.lastTradeTime, params.initialMark);

    // No OI fee: the TradeModule's taker fee is the venue's fee. Explicit so the artifact states it.
    d.viewer.setOIFeeRateBPS(address(d.future), 0);

    address[] memory owned = ownedContracts(d);
    for (uint i = 0; i < owned.length; i++) {
      IOwnable2Step(owned[i]).transferOwnership(params.vault);
    }
  }

  function ownedContracts(Deployment memory d) public pure returns (address[] memory owned) {
    owned = new address[](3);
    owned[0] = address(d.future);
    owned[1] = address(d.viewer);
    owned[2] = address(d.manager);
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

    IDatedFutureAsset.FutureContract memory c = d.future.futureContracts(d.subId);
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
    string memory obj = "cngn-dated-future";
    vm.serializeAddress(obj, "future", address(d.future));
    vm.serializeAddress(obj, "viewer", address(d.viewer));
    vm.serializeAddress(obj, "manager", address(d.manager));
    vm.serializeUint(obj, "poolAccount", d.poolAccount);
    vm.serializeUint(obj, "subId", d.subId);
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "contractSize", params.contractSize);
    vm.serializeUint(obj, "initialMark", params.initialMark);
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
      json = string.concat(json, i == 0 ? "" : ",", _action("acceptOwnership() [cNGN dated future]", owned[i], accept));
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
