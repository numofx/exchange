// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {SubAccounts} from "../src/SubAccounts.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../src/interfaces/IFutureAssetV3.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {StreamsIndexAdapter} from "../src/feeds/StreamsIndexAdapter.sol";
import {OnchainBook, IOnchainBookManager} from "../src/periphery/OnchainBook.sol";
import {OnchainBookRouter, IRouterCash} from "../src/periphery/OnchainBookRouter.sol";

import {Utils} from "./utils.sol";

interface ITradeModuleFeeRecipientCngn {
  function feeRecipient() external view returns (uint);
  function matching() external view returns (address);
}

/**
 * @title DeployOnchainBookCngn
 *
 * @dev An OnchainBook (v2 code with adapter-less markets, 050324c) with its router, for cNGN-30NOV26 on the cNGN
 *      FutureAsset v2 (MARGIN_ENGINE_V2.json) under MarginEngine v2. Owner's decision 2026-11-18: move the cNGN future
 *      onto the on-chain book now. The EURC books (ONCHAIN_BOOK*.json) are untouched; this writes ONCHAIN_BOOK_CNGN*.
 *
 * @dev NO ADAPTER. cNGN's index is our signed spot feed, not a Data Streams pair, so the market is created with
 *      adapter 0: it quotes self-priced splines only, inside the future's own index band, and stops if the future's
 *      index is rotated (OnchainBook.indexFeedOf). takeMaxAge then gates nothing and is set to 1.
 *
 * @dev Otherwise as deploy-onchain-book.s.sol: deployed closed, nominated to the vault; setup (accept, allow the
 *      maker) and enable are vault batches. The fee is the registry's (15 bps for cNGN-30NOV26), never a default.
 *
 * Usage:
 *   TAKER_FEE_RATE=1500000000000000 MAKER_OWNER=<addr> [USED_DEPLOYER=<addr>] \
 *     forge script scripts/deploy-onchain-book-cngn.s.sol --rpc-url $BASE_RPC_URL --private-key ... --broadcast
 */
contract DeployOnchainBookCngn is Utils {
  string internal constant ARTIFACT_NAME = "ONCHAIN_BOOK_CNGN";
  string internal constant SERIES_NAME = "MARGIN_ENGINE_V2";
  string internal constant VAULT_ACTIONS_NAME = "ONCHAIN_BOOK_CNGN_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "ONCHAIN_BOOK_CNGN_ENABLE_VAULT_ACTIONS";
  uint internal constant BOOK_VERSION = 2;

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
  /// @dev cNGN is the engine's market 1
  uint internal constant ENGINE_MARKET_ID = 1;
  uint internal constant BOOK_MARKET_ID = 1;

  /// @dev cNGN is ~0.00069 USDC: 1e10 is 0.15 bps (EURC's 1e12 would be 15 bps). Lot 1e15 is 1,000 cNGN (~$0.69).
  uint internal constant DEFAULT_TICK_SIZE = 1e10;
  uint internal constant DEFAULT_LOT_SIZE = 1e15;
  uint32 internal constant TAKE_MAX_AGE = 1; // no reports: gates nothing on an adapter-less market
  uint32 internal constant DEFAULT_MAX_TTL = 1 hours;
  uint16 internal constant DEFAULT_MAX_MAKERS = 10;
  uint internal constant DEFAULT_GAS_FLOOR = 700_000;
  uint32 internal constant DEFAULT_SELF_PRICED_TTL_CAP = 60;

  uint internal constant MAX_TICK_SIZE = 1e12; // 0.000001 USDC: ~15 bps at 0.00069
  uint internal constant MAX_TAKER_FEE_RATE = 0.01e18;
  uint32 internal constant MAX_TTL_LIMIT = 1 days;
  uint16 internal constant MAX_MAKERS_LIMIT = 10;
  uint32 internal constant MAX_SELF_PRICED_TTL_CAP = 60;
  uint internal constant MIN_GAS_FLOOR = 600_000;
  uint internal constant MIN_LEAD = 2 hours;
  uint internal constant UNSET = type(uint).max;

  struct Params {
    address subAccounts;
    address vault;
    address engine;
    address future;
    address indexFeed;
    address cash;
    address tradeModule;
    uint96 subId;
    uint64 expiry;
    uint64 lastTradeTime;
    uint feeRecipient;
    uint tickSize;
    uint lotSize;
    uint takerFeeRate;
    uint32 maxTtl;
    uint16 maxMakers;
    uint gasFloor;
    uint32 selfPricedTtlCap;
    address makerOwner;
  }

  function run() external {
    Params memory params = loadParams();
    checkDeployer(params, msg.sender, vm.getNonce(msg.sender), vm.envOr("USED_DEPLOYER", address(0)));
    if (vm.exists(_deploymentPath(ARTIFACT_NAME))) {
      revert("ONCHAIN_BOOK_CNGN.json exists: a cNGN book is deployed on this chain; move the record aside deliberately");
    }

    vm.startBroadcast();
    OnchainBook book = deploy(params);
    OnchainBookRouter router = new OnchainBookRouter(book, IRouterCash(params.cash));
    vm.stopBroadcast();

    assertDeployment(book, params, msg.sender);
    assertRouter(router, book, params);
    _writeArtifacts(book, router, params);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function loadParams() public view returns (Params memory params) {
    params = loadChainParams();
    params.tickSize = vm.envOr("TICK_SIZE", params.tickSize);
    params.lotSize = vm.envOr("LOT_SIZE", params.lotSize);
    uint fee = vm.envOr("TAKER_FEE_RATE", UNSET);
    if (fee == UNSET) revert("set TAKER_FEE_RATE (18 dp): it has no default");
    params.takerFeeRate = fee;
    params.maxTtl = uint32(vm.envOr("MAX_TTL", uint(params.maxTtl)));
    params.maxMakers = uint16(vm.envOr("MAX_MAKERS", uint(params.maxMakers)));
    params.gasFloor = vm.envOr("GAS_FLOOR", params.gasFloor);
    params.selfPricedTtlCap = uint32(vm.envOr("SELF_PRICED_TTL_CAP", uint(params.selfPricedTtlCap)));
    params.makerOwner = vm.envOr("MAKER_OWNER", address(0));
    checkParams(params);
  }

  /// @dev The series is the engine artifact's (cNGN-30NOV26); the future's own records are what is checked.
  function loadChainParams() public view returns (Params memory params) {
    string memory series = _readDeploymentFile(SERIES_NAME);
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.engine = vm.parseJsonAddress(series, ".manager");
    params.future = vm.parseJsonAddress(series, ".future");
    params.indexFeed = vm.parseJsonAddress(series, ".indexFeed");
    params.cash = vm.parseJsonAddress(series, ".cash");
    params.tradeModule = vm.parseJsonAddress(series, ".tradeModule");
    params.expiry = uint64(vm.parseJsonUint(series, ".expiry"));
    params.subId = uint96(vm.parseJsonUint(series, ".subId"));
    params.lastTradeTime = FutureAsset(params.future).futureContracts(params.subId).lastTradeTime;
    params.feeRecipient = ITradeModuleFeeRecipientCngn(params.tradeModule).feeRecipient();
    params.tickSize = DEFAULT_TICK_SIZE;
    params.lotSize = DEFAULT_LOT_SIZE;
    params.takerFeeRate = UNSET;
    params.maxTtl = DEFAULT_MAX_TTL;
    params.maxMakers = DEFAULT_MAX_MAKERS;
    params.gasFloor = DEFAULT_GAS_FLOOR;
    params.selfPricedTtlCap = DEFAULT_SELF_PRICED_TTL_CAP;
  }

  /// @dev A used key is accepted only by name: the v2 book's deployer, reused rather than funding a new one.
  function checkDeployer(Params memory params, address deployer, uint nonce, address usedDeployer) public pure {
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");
    if (nonce > 1 && deployer != usedDeployer) {
      revert("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)");
    }
    if (deployer == params.vault) revert("deployer is the vault");
    if (deployer == params.makerOwner) revert("deployer is the maker owner");
  }

  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    MarginEngine engine = MarginEngine(params.engine);
    if (engine.owner() != params.vault) revert("v2 engine is not owned by the vault");
    if (address(engine.subAccounts()) != params.subAccounts) revert("engine is on another SubAccounts");
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the artifact's");
    if (address(engine.assetMap(ENGINE_MARKET_ID, IMarginEngine.AssetType.Future)) != params.future) {
      revert("engine market 1's future is not the cNGN future");
    }

    FutureAsset future = FutureAsset(params.future);
    if (!future.whitelistedManager(params.engine)) revert("the future does not whitelist the engine");
    IFutureAsset.FutureContract memory c = future.futureContracts(params.subId);
    if (!c.listed || c.settled) revert("cNGN-30NOV26 is not listed, or settled");
    if (c.expiry != params.expiry || future.getSubId(params.expiry) != params.subId) revert("the series is not the artifact's");
    if (block.timestamp + MIN_LEAD >= c.lastTradeTime) revert("under 2 hours to the series' last trade");
    if (future.totalPositionCap(IManager(params.engine)) == 0) revert("the series is closed (cap 0)");
    if (address(future.indexFeed()) != params.indexFeed) revert("the future's index is not the artifact's");
    if (future.markIndexBand(params.expiry) == 0) revert("the future has no index band: a self-priced mid is unbounded");

    if (params.feeRecipient == 0) revert("the TradeModule has no fee recipient");
    if (address(SubAccounts(params.subAccounts).manager(params.feeRecipient)) == address(0)) {
      revert("the fee recipient account does not exist");
    }

    if (params.tickSize == 0 || params.tickSize > MAX_TICK_SIZE) revert("TICK_SIZE: 1 to 1e12 (0.000001 USDC per cNGN)");
    if (params.lotSize == 0 || params.lotSize > 1e18) revert("LOT_SIZE: 1 to 1e18 (one contract)");
    if (params.takerFeeRate > MAX_TAKER_FEE_RATE) revert("TAKER_FEE_RATE over 1%: give it 18dp (15 bps is 1.5e15)");
    if (params.maxTtl == 0 || params.maxTtl > MAX_TTL_LIMIT) revert("MAX_TTL: 1 s to 1 day");
    if (params.maxMakers == 0 || params.maxMakers > MAX_MAKERS_LIMIT) revert("MAX_MAKERS: 1 to 10");
    if (params.gasFloor < MIN_GAS_FLOOR) revert("GAS_FLOOR under 600,000 skips honest makers");
    if (
      params.selfPricedTtlCap == 0 || params.selfPricedTtlCap > MAX_SELF_PRICED_TTL_CAP
        || params.selfPricedTtlCap > params.maxTtl
    ) revert("SELF_PRICED_TTL_CAP: 1 to 60 s, and no more than MAX_TTL");

    if (params.makerOwner == address(0)) revert("set MAKER_OWNER: the address owning the maker's account");
    if (params.makerOwner == params.vault) revert("MAKER_OWNER is the vault");
    if (params.makerOwner == ITradeModuleFeeRecipientCngn(params.tradeModule).matching()) {
      revert("MAKER_OWNER is Matching: the book cannot reach accounts Matching holds");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // deployment
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (OnchainBook book) {
    book = new OnchainBook(ISubAccounts(params.subAccounts), IAsset(params.cash), params.feeRecipient);
    uint id = book.createMarket(
      IFutureAssetV3(params.future),
      params.subId,
      IOnchainBookManager(params.engine),
      StreamsIndexAdapter(address(0)),
      params.tickSize,
      params.lotSize
    );
    if (id != BOOK_MARKET_ID) revert("the book's first market is not 1");
    book.setMarketParams(id, params.takerFeeRate, TAKE_MAX_AGE, params.maxTtl, params.maxMakers, false);
    book.setGasFloor(params.gasFloor);
    book.setSelfPricedTtlCap(id, params.selfPricedTtlCap);
    book.transferOwnership(params.vault);
  }

  // ---------------------------------------------------------------------------------------------
  // postconditions
  // ---------------------------------------------------------------------------------------------

  function assertDeployment(OnchainBook book, Params memory params, address deployer) public view {
    if (book.pendingOwner() != params.vault) revert("book not nominated to the vault");
    if (address(book.subAccounts()) != params.subAccounts) revert("book subAccounts");
    if (address(book.cash()) != params.cash) revert("book cash");
    if (book.feeRecipient() != params.feeRecipient) revert("book fee recipient");
    if (book.gasFloor() != params.gasFloor) revert("book gas floor");
    if (book.priorityTaxRate() != 0) revert("book priority tax");
    if (book.maxSelfPricedTtl(BOOK_MARKET_ID) != params.selfPricedTtlCap) revert("book self-priced ttl cap");
    if (book.nextMarketId() != BOOK_MARKET_ID + 1) revert("the book lists one market");
    if (book.indexFeedOf(BOOK_MARKET_ID) != params.indexFeed) revert("the market's index feed is not the future's");

    OnchainBook.Market memory m = marketOf(book);
    if (address(m.future) != params.future || address(m.engine) != params.engine || m.subId != params.subId) {
      revert("market series");
    }
    if (m.lastTradeTime != params.lastTradeTime) revert("market last trade");
    if (address(m.adapter) != address(0)) revert("market adapter: cNGN's market has none");
    if (m.tickSize != params.tickSize || m.lotSize != params.lotSize) revert("market tick or lot");
    if (m.takerFeeRate != params.takerFeeRate) revert("market fee");
    if (m.takeMaxAge != TAKE_MAX_AGE || m.maxTtl != params.maxTtl || m.maxMakers != params.maxMakers) {
      revert("market params");
    }
    if (m.enabled) revert("the market must deploy closed");
    if (book.makerAllowed(params.makerOwner) || book.makerAllowed(deployer)) revert("a maker allowed before the vault");

    MarginEngine e = MarginEngine(params.engine);
    if (e.trustedRiskAssessor(address(book))) revert("the book is a trustedRiskAssessor");
    if (e.feeBypassedCaller(address(book))) revert("the book is a feeBypassedCaller");
  }

  function assertRouter(OnchainBookRouter router, OnchainBook book, Params memory params) public view {
    if (address(router.book()) != address(book)) revert("router book");
    if (address(router.cash()) != params.cash) revert("router cash");
    if (address(router.subAccounts()) != params.subAccounts) revert("router subAccounts");
  }

  function marketOf(OnchainBook book) public view returns (OnchainBook.Market memory m) {
    (bool ok, bytes memory ret) = address(book).staticcall(abi.encodeCall(book.markets, (BOOK_MARKET_ID)));
    if (!ok) revert("markets() reverted");
    m = abi.decode(ret, (OnchainBook.Market));
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _deploymentPath(string memory name) internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "/", name, ".json");
  }

  function _writeArtifacts(OnchainBook book, OnchainBookRouter router, Params memory params) internal {
    string memory obj = "onchain-book-cngn";
    vm.serializeAddress(obj, "book", address(book));
    vm.serializeUint(obj, "version", BOOK_VERSION);
    vm.serializeAddress(obj, "router", address(router));
    vm.serializeUint(obj, "deployBlock", block.number);
    vm.serializeUint(obj, "bookMarketId", BOOK_MARKET_ID);
    vm.serializeString(obj, "symbol", "cNGN-30NOV26");
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "subAccounts", params.subAccounts);
    vm.serializeAddress(obj, "manager", params.engine);
    vm.serializeAddress(obj, "future", params.future);
    vm.serializeAddress(obj, "adapter", address(0));
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    vm.serializeUint(obj, "subId", params.subId);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "feeRecipient", params.feeRecipient);
    vm.serializeUint(obj, "tickSize", params.tickSize);
    vm.serializeUint(obj, "lotSize", params.lotSize);
    vm.serializeUint(obj, "takerFeeRate", params.takerFeeRate);
    vm.serializeUint(obj, "takeMaxAge", TAKE_MAX_AGE);
    vm.serializeUint(obj, "maxTtl", params.maxTtl);
    vm.serializeUint(obj, "maxMakers", params.maxMakers);
    vm.serializeUint(obj, "gasFloor", params.gasFloor);
    vm.serializeUint(obj, "priorityTaxRate", 0);
    vm.serializeUint(obj, "selfPricedTtlCap", params.selfPricedTtlCap);
    vm.serializeString(obj, "units", "tickSize in USDC per cNGN (18 dp); lotSize in contracts (18 dp); fee of notional");
    string memory json = vm.serializeAddress(obj, "makerOwner", params.makerOwner);
    _writeToDeployments(ARTIFACT_NAME, json);
    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(address(book), params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(address(book), params));
  }

  function vaultActionsJson(address book, Params memory params) public pure returns (string memory) {
    return string.concat(
      "[",
      _action("acceptOwnership() [OnchainBook cNGN]", book, abi.encodeWithSignature("acceptOwnership()")),
      ",",
      _action(
        string.concat("book.setMakerAllowed(", vm.toString(params.makerOwner), ", true) [the cNGN book maker]"),
        book,
        abi.encodeWithSignature("setMakerAllowed(address,bool)", params.makerOwner, true)
      ),
      "]"
    );
  }

  function enableActionsJson(address book, Params memory params) public pure returns (string memory) {
    return string.concat(
      "[",
      _action("book.setMarketParams(1, ..., enabled = true) [opens cNGN-30NOV26 on the OnchainBook]", book, enableCalldata(params)),
      "]"
    );
  }

  function enableCalldata(Params memory params) public pure returns (bytes memory) {
    return abi.encodeWithSignature(
      "setMarketParams(uint256,uint256,uint32,uint32,uint16,bool)",
      BOOK_MARKET_ID,
      params.takerFeeRate,
      TAKE_MAX_AGE,
      params.maxTtl,
      params.maxMakers,
      true
    );
  }

  /// @dev Digest is keccak(to ‖ keccak(data)), as deploy-onchain-book.s.sol's.
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
