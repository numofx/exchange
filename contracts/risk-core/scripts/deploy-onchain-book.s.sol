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
import {EurcIndexFeed} from "../src/feeds/EurcIndexFeed.sol";
import {OnchainBook, IOnchainBookManager} from "../src/periphery/OnchainBook.sol";
import {OnchainBookRouter, IRouterCash} from "../src/periphery/OnchainBookRouter.sol";

import {Utils} from "./utils.sol";

interface ITradeModuleFeeRecipient {
  function feeRecipient() external view returns (uint);
  function matching() external view returns (address);
}

/**
 * @title DeployOnchainBook
 *
 * @dev The OnchainBook, v2 (spec C4: quote, self-priced splines; C6), with its router, beside the live contracts: one
 *      market on a series of the deployed EURC FutureAsset v3 (EURC_FUTURE_V3.json), chosen by EXPIRY, under
 *      MarginEngine v2, priced off the future's StreamsIndexAdapter. The `Matching` path keeps running.
 *
 * @dev HISTORY. v1 (pegged splines only) was deployed from this script on 2026-11-16 for EURC-30NOV26
 *      (ONCHAIN_BOOK.json and its two vault-action files). This version writes ONCHAIN_BOOK_V2*.json and refuses to
 *      overwrite them, so the v1 record stays. The series is read from the future (EXPIRY must be listed there, by
 *      the vault's `setContract`), not from the artifact, which records the first series only.
 *
 * @dev SELF-PRICED CAP. The deployer sets `maxSelfPricedTtl` (60 s, decision C6) while it still owns the book, as it
 *      sets the market's other parameters; the proposer checks it. The priority-fee tax deploys off (C6: on when
 *      outside takers arrive, a vault action).
 *
 * @dev NOTHING ON THE ENGINE OR THE FUTURE CHANGES. FutureAsset accepts a priced transfer from any caller holding
 *      the accounts' allowances and band-checks the price as it does a TradeModule fill; the engine margins it as any
 *      transfer. The book is never a trustedRiskAssessor or feeBypassedCaller (B4), and checkParams refuses both.
 *
 * @dev DEPLOYED CLOSED. The deployer creates the market with `enabled = false` and nominates the vault. Setup
 *      (VAULT_ACTIONS): accept ownership, allow the maker. Enable (ENABLE_VAULT_ACTIONS): the same parameters with
 *      `enabled = true`. A maker can register and quote between the two; nothing fills until enable.
 *
 * @dev PARAMETERS await decision (B14). Defaults are the values the tests ran on (B15); each is an env override.
 *      Two have no default: TAKER_FEE_RATE, because the fee schedule lives in the instruments registry and the
 *      proposer checks the book against it, and MAKER_OWNER, the address that owns the maker's account outside
 *      `Matching` (B3). The fee recipient is the TradeModule's, read live: one fee account for both paths.
 *
 * Usage (a fresh keystore account, or a used one named in USED_DEPLOYER):
 *   EXPIRY=<unix> TAKER_FEE_RATE=500000000000000 MAKER_OWNER=<addr> forge script scripts/deploy-onchain-book.s.sol \
 *     --rpc-url $BASE_RPC_URL --account <keystore> --broadcast
 */
contract DeployOnchainBook is Utils {
  string internal constant ARTIFACT_NAME = "ONCHAIN_BOOK_V2";
  string internal constant SERIES_NAME = "EURC_FUTURE_V3";
  string internal constant VAULT_ACTIONS_NAME = "ONCHAIN_BOOK_V2_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "ONCHAIN_BOOK_V2_ENABLE_VAULT_ACTIONS";
  uint internal constant BOOK_VERSION = 2;

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
  uint internal constant MARKET_ID = 2;
  /// @dev The book's first market: createMarket numbers from 1
  uint internal constant BOOK_MARKET_ID = 1;

  /// @dev B15: the values the unit, invariant and fork suites ran on
  uint internal constant DEFAULT_TICK_SIZE = 1e12; // 0.000001 USDC per EURC
  uint internal constant DEFAULT_LOT_SIZE = 1e15; // 1 EURC: 0.001 of a 1,000-EURC contract
  uint32 internal constant DEFAULT_TAKE_MAX_AGE = 1;
  uint32 internal constant DEFAULT_MAX_TTL = 1 hours;
  uint16 internal constant DEFAULT_MAX_MAKERS = 10;
  uint internal constant DEFAULT_GAS_FLOOR = 700_000;
  uint internal constant DEFAULT_PRIORITY_TAX_RATE = 0; // B12: tax off at rollout
  uint32 internal constant DEFAULT_SELF_PRICED_TTL_CAP = 60; // C6

  /// @dev Bounds a mistyped env would cross
  uint internal constant MAX_TICK_SIZE = 1e15; // 0.001 USDC per EURC: ~9 bps at 1.10
  uint internal constant MAX_TAKER_FEE_RATE = 0.01e18; // the contract's own bound
  uint32 internal constant MAX_TTL_LIMIT = 1 days;
  /// @dev B10: a take walking 10 makers measured 6.6M gas on the Base fork
  uint16 internal constant MAX_MAKERS_LIMIT = 10;
  /// @dev C6: 60 s is the cap; a self-priced quote is only as fresh as its maker's last update
  uint32 internal constant MAX_SELF_PRICED_TTL_CAP = 60;
  /// @dev B5a: a settlement batch on the fork measured ~600k; below this the floor skips honest makers
  uint internal constant MIN_GAS_FLOOR = 600_000;
  /// @dev Time before the series' last trade for the vault's two batches and some trading
  uint internal constant MIN_LEAD = 2 hours;
  uint internal constant UNSET = type(uint).max;

  struct Params {
    address subAccounts;
    address vault;
    address engine;
    address future;
    address adapter;
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
    uint32 takeMaxAge;
    uint32 maxTtl;
    uint16 maxMakers;
    uint gasFloor;
    uint priorityTaxRate;
    uint32 selfPricedTtlCap;
    address makerOwner;
  }

  function run() external {
    Params memory params = loadParams();
    checkDeployer(params, msg.sender, vm.getNonce(msg.sender), vm.envOr("USED_DEPLOYER", address(0)));

    if (vm.exists(_deploymentPath(ARTIFACT_NAME))) {
      revert("ONCHAIN_BOOK_V2.json exists: a v2 book is deployed on this chain; move the record aside deliberately");
    }

    vm.startBroadcast();
    OnchainBook book = deploy(params);
    OnchainBookRouter router = deployRouter(book, params);
    vm.stopBroadcast();

    assertDeployment(book, params, msg.sender);
    assertRouter(router, book, params);
    _writeArtifacts(book, router, params);
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function loadParams() public view returns (Params memory params) {
    uint expiry = resolveRequired(vm.envOr("EXPIRY", UNSET), "EXPIRY");
    if (expiry > type(uint64).max) revert("EXPIRY is not a unix time");
    params = loadChainParams(uint64(expiry));
    params.tickSize = vm.envOr("TICK_SIZE", params.tickSize);
    params.lotSize = vm.envOr("LOT_SIZE", params.lotSize);
    params.takerFeeRate = resolveRequired(vm.envOr("TAKER_FEE_RATE", UNSET), "TAKER_FEE_RATE");
    params.takeMaxAge = uint32(vm.envOr("TAKE_MAX_AGE", uint(params.takeMaxAge)));
    params.maxTtl = uint32(vm.envOr("MAX_TTL", uint(params.maxTtl)));
    params.maxMakers = uint16(vm.envOr("MAX_MAKERS", uint(params.maxMakers)));
    params.gasFloor = vm.envOr("GAS_FLOOR", params.gasFloor);
    params.priorityTaxRate = vm.envOr("PRIORITY_TAX_RATE", params.priorityTaxRate);
    params.selfPricedTtlCap = uint32(vm.envOr("SELF_PRICED_TTL_CAP", uint(params.selfPricedTtlCap)));
    params.makerOwner = vm.envOr("MAKER_OWNER", address(0));
    checkParams(params);
  }

  /// @dev No silent default: the fee is the registry's, never this script's.
  function resolveRequired(uint value, string memory name) public pure returns (uint) {
    if (value == UNSET) revert(string.concat("set ", name, " (18 dp): it has no default"));
    return value;
  }

  /// @dev Chain reads, the series' artifact and defaults; no environment, no checks. The fork test builds on this.
  ///      The series is `expiry` on the artifact's future: its subId and last trade are the future's.
  function loadChainParams(uint64 expiry) public view returns (Params memory params) {
    string memory series = _readDeploymentFile(SERIES_NAME);
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.vault = EXPECTED_VAULT;
    params.engine = vm.parseJsonAddress(series, ".manager");
    params.future = vm.parseJsonAddress(series, ".future");
    params.adapter = vm.parseJsonAddress(series, ".adapter");
    params.indexFeed = vm.parseJsonAddress(series, ".indexFeed");
    params.cash = vm.parseJsonAddress(series, ".cash");
    params.tradeModule = vm.parseJsonAddress(series, ".tradeModule");
    params.expiry = expiry;
    params.subId = FutureAsset(params.future).getSubId(expiry);
    params.lastTradeTime = FutureAsset(params.future).futureContracts(params.subId).lastTradeTime;
    params.feeRecipient = ITradeModuleFeeRecipient(params.tradeModule).feeRecipient();

    params.tickSize = DEFAULT_TICK_SIZE;
    params.lotSize = DEFAULT_LOT_SIZE;
    params.takerFeeRate = UNSET;
    params.takeMaxAge = DEFAULT_TAKE_MAX_AGE;
    params.maxTtl = DEFAULT_MAX_TTL;
    params.maxMakers = DEFAULT_MAX_MAKERS;
    params.gasFloor = DEFAULT_GAS_FLOOR;
    params.priorityTaxRate = DEFAULT_PRIORITY_TAX_RATE;
    params.selfPricedTtlCap = DEFAULT_SELF_PRICED_TTL_CAP;
  }

  function checkDeployer(Params memory params, address deployer, uint nonce, address usedDeployer) public pure {
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");
    if (nonce > 1 && deployer != usedDeployer) {
      revert("deployer key must be single use: it has sent transactions before (name it in USED_DEPLOYER to accept)");
    }
    if (deployer == params.vault) revert("deployer is the vault");
    if (deployer == params.makerOwner) revert("deployer is the maker owner");
  }

  /// @dev Each check is a way the book lands and then cannot be opened, quotes off the wrong price, or holds power
  ///      over the engine it should not.
  function checkParams(Params memory params) public view {
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    MarginEngine engine = MarginEngine(params.engine);
    if (engine.owner() != params.vault) revert("v2 engine is not owned by the vault");
    if (address(engine.subAccounts()) != params.subAccounts) revert("engine is on another SubAccounts");
    if (address(engine.cashAsset()) != params.cash) revert("engine cash is not the series artifact's");

    // the series: the engine's EUR future, listed, open for long enough to matter
    if (address(engine.assetMap(MARKET_ID, IMarginEngine.AssetType.Future)) != params.future) {
      revert("market 2's future is not the EURC v3 series");
    }
    FutureAsset future = FutureAsset(params.future);
    if (!future.whitelistedManager(params.engine)) revert("the future does not whitelist the engine");
    IFutureAsset.FutureContract memory c = future.futureContracts(params.subId);
    if (!c.listed || c.settled) revert("the series is not listed, or settled: the vault lists EXPIRY first (setContract)");
    if (c.expiry != params.expiry || future.getSubId(params.expiry) != params.subId) revert("the series is not EXPIRY");
    if (c.lastTradeTime != params.lastTradeTime) revert("the series' last trade is not the future's");
    if (block.timestamp + MIN_LEAD >= c.lastTradeTime) revert("under 2 hours to the series' last trade");
    if (future.totalPositionCap(IManager(params.engine)) == 0) revert("the series is closed (cap 0)");

    // the book prices off the reports the future band-checks with: the same adapter, behind the future's index
    if (address(future.indexFeed()) != params.indexFeed) revert("the future's index is not the artifact's");
    if (address(EurcIndexFeed(params.indexFeed).adapter()) != params.adapter) {
      revert("the index's adapter is not the artifact's");
    }
    uint indexMaxAge = EurcIndexFeed(params.indexFeed).indexMaxAge();

    // one fee account for both paths, and one the engines can credit
    if (params.feeRecipient == 0) revert("the TradeModule has no fee recipient");
    if (address(SubAccounts(params.subAccounts).manager(params.feeRecipient)) == address(0)) {
      revert("the fee recipient account does not exist");
    }

    if (params.tickSize == 0 || params.tickSize > MAX_TICK_SIZE) revert("TICK_SIZE: 1 to 1e15 (0.001 USDC per EURC)");
    if (params.lotSize == 0 || params.lotSize > 1e18) revert("LOT_SIZE: 1 to 1e18 (one contract)");
    if (params.takerFeeRate > MAX_TAKER_FEE_RATE) revert("TAKER_FEE_RATE over 1%: give it 18dp (5 bps is 5e14)");
    if (params.takeMaxAge == 0 || params.takeMaxAge > indexMaxAge) {
      revert("TAKE_MAX_AGE must be positive and no longer than the index's own max age (B6a)");
    }
    if (params.maxTtl == 0 || params.maxTtl > MAX_TTL_LIMIT) revert("MAX_TTL: 1 s to 1 day");
    if (params.maxMakers == 0 || params.maxMakers > MAX_MAKERS_LIMIT) {
      revert("MAX_MAKERS: 1 to 10 (B10: 10 makers is 6.6M gas a take)");
    }
    if (params.gasFloor < MIN_GAS_FLOOR) revert("GAS_FLOOR under 600,000 skips honest makers (B5a, B10)");
    if (params.priorityTaxRate != 0) revert("PRIORITY_TAX_RATE must be 0 at rollout (B12: tax off)");
    if (
      params.selfPricedTtlCap == 0 || params.selfPricedTtlCap > MAX_SELF_PRICED_TTL_CAP
        || params.selfPricedTtlCap > params.maxTtl
    ) revert("SELF_PRICED_TTL_CAP: 1 to 60 s (C6), and no more than MAX_TTL");

    if (params.makerOwner == address(0)) revert("set MAKER_OWNER: the address owning the maker's account (B3)");
    if (params.makerOwner == params.vault) revert("MAKER_OWNER is the vault");
    if (params.makerOwner == ITradeModuleFeeRecipient(params.tradeModule).matching()) {
      revert("MAKER_OWNER is Matching: the book cannot reach accounts Matching holds (B3)");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (OnchainBook book) {
    book = new OnchainBook(ISubAccounts(params.subAccounts), IAsset(params.cash), params.feeRecipient);
    uint id = book.createMarket(
      IFutureAssetV3(params.future),
      params.subId,
      IOnchainBookManager(params.engine),
      StreamsIndexAdapter(params.adapter),
      params.tickSize,
      params.lotSize
    );
    if (id != BOOK_MARKET_ID) revert("the book's first market is not 1");
    book.setMarketParams(id, params.takerFeeRate, params.takeMaxAge, params.maxTtl, params.maxMakers, false);
    book.setGasFloor(params.gasFloor);
    book.setSelfPricedTtlCap(id, params.selfPricedTtlCap);
    book.transferOwnership(params.vault);
  }

  /// @dev Ownerless: it holds nothing and acts only for an account's owner (C4.3).
  function deployRouter(OnchainBook book, Params memory params) public returns (OnchainBookRouter) {
    return new OnchainBookRouter(book, IRouterCash(params.cash));
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
    _assertMarket(book, params);
    if (book.makerAllowed(params.makerOwner) || book.makerAllowed(deployer)) {
      revert("a maker allowed before the vault");
    }

    // B4: the engine grants the book nothing
    MarginEngine e = MarginEngine(params.engine);
    if (e.trustedRiskAssessor(address(book))) revert("the book is a trustedRiskAssessor");
    if (e.feeBypassedCaller(address(book))) revert("the book is a feeBypassedCaller");
  }

  function assertRouter(OnchainBookRouter router, OnchainBook book, Params memory params) public view {
    if (address(router.book()) != address(book)) revert("router book");
    if (address(router.cash()) != params.cash) revert("router cash");
    if (address(router.subAccounts()) != params.subAccounts) revert("router subAccounts");
  }

  /// @dev The getter returns the struct's fields flattened, which is the encoding of the (all-static) struct itself:
  ///      decoded whole, so thirteen fields never sit on the stack.
  function marketOf(OnchainBook book) public view returns (OnchainBook.Market memory m) {
    (bool ok, bytes memory ret) = address(book).staticcall(abi.encodeCall(book.markets, (BOOK_MARKET_ID)));
    if (!ok) revert("markets() reverted");
    m = abi.decode(ret, (OnchainBook.Market));
  }

  function _assertMarket(OnchainBook book, Params memory params) internal view {
    OnchainBook.Market memory m = marketOf(book);
    if (address(m.future) != params.future || address(m.engine) != params.engine || m.subId != params.subId) {
      revert("market series");
    }
    if (m.lastTradeTime != params.lastTradeTime) revert("market last trade");
    if (address(m.adapter) != params.adapter) revert("market adapter");
    if (m.tickSize != params.tickSize || m.lotSize != params.lotSize) revert("market tick or lot");
    if (m.takerFeeRate != params.takerFeeRate) revert("market fee");
    if (m.takeMaxAge != params.takeMaxAge || m.maxTtl != params.maxTtl || m.maxMakers != params.maxMakers) {
      revert("market params");
    }
    if (m.enabled) revert("the market must deploy closed");
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function symbolOf(Params memory params) public pure returns (string memory) {
    return string.concat("EURC-", _expiryCode(params.expiry));
  }

  function _deploymentPath(string memory name) internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "/", name, ".json");
  }

  function _writeArtifacts(OnchainBook book, OnchainBookRouter router, Params memory params) internal {
    string memory obj = "onchain-book";
    vm.serializeAddress(obj, "book", address(book));
    vm.serializeUint(obj, "version", BOOK_VERSION);
    vm.serializeAddress(obj, "router", address(router));
    vm.serializeUint(obj, "deployBlock", block.number);
    vm.serializeUint(obj, "bookMarketId", BOOK_MARKET_ID);
    vm.serializeString(obj, "symbol", symbolOf(params));
    vm.serializeUint(obj, "expiry", params.expiry);
    vm.serializeAddress(obj, "deployer", msg.sender);
    vm.serializeUint(obj, "deployerNonce", vm.getNonce(msg.sender));
    vm.serializeAddress(obj, "subAccounts", params.subAccounts);
    vm.serializeAddress(obj, "manager", params.engine);
    vm.serializeAddress(obj, "future", params.future);
    vm.serializeAddress(obj, "adapter", params.adapter);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "tradeModule", params.tradeModule);
    vm.serializeUint(obj, "subId", params.subId);
    vm.serializeUint(obj, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(obj, "feeRecipient", params.feeRecipient);
    vm.serializeUint(obj, "tickSize", params.tickSize);
    vm.serializeUint(obj, "lotSize", params.lotSize);
    vm.serializeUint(obj, "takerFeeRate", params.takerFeeRate);
    vm.serializeUint(obj, "takeMaxAge", params.takeMaxAge);
    vm.serializeUint(obj, "maxTtl", params.maxTtl);
    vm.serializeUint(obj, "maxMakers", params.maxMakers);
    vm.serializeUint(obj, "gasFloor", params.gasFloor);
    vm.serializeUint(obj, "priorityTaxRate", params.priorityTaxRate);
    vm.serializeUint(obj, "selfPricedTtlCap", params.selfPricedTtlCap);
    vm.serializeString(obj, "units", "tickSize in USDC per EURC (18 dp); lotSize in contracts (18 dp); fee of notional");
    string memory json = vm.serializeAddress(obj, "makerOwner", params.makerOwner);
    _writeToDeployments(ARTIFACT_NAME, json);

    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(address(book), params));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(address(book), params));
  }

  /// @dev Accept the book; allow the maker. Opens nothing: the market stays disabled.
  function vaultActionsJson(address book, Params memory params) public pure returns (string memory) {
    return string.concat(
      "[",
      _action("acceptOwnership() [OnchainBook]", book, abi.encodeWithSignature("acceptOwnership()")),
      ",",
      _action(
        string.concat("book.setMakerAllowed(", vm.toString(params.makerOwner), ", true) [the maker, outside Matching]"),
        book,
        abi.encodeWithSignature("setMakerAllowed(address,bool)", params.makerOwner, true)
      ),
      "]"
    );
  }

  function vaultActionCount() public pure returns (uint) {
    return 2;
  }

  /// @dev The deployed parameters again, enabled: the one action that lets a take fill.
  function enableActionsJson(address book, Params memory params) public pure returns (string memory) {
    return string.concat(
      "[",
      _action(
        string.concat("book.setMarketParams(1, ..., enabled = true) [opens ", symbolOf(params), " on the OnchainBook]"),
        book,
        enableCalldata(params)
      ),
      "]"
    );
  }

  function enableCalldata(Params memory params) public pure returns (bytes memory) {
    return abi.encodeWithSignature(
      "setMarketParams(uint256,uint256,uint32,uint32,uint16,bool)",
      BOOK_MARKET_ID,
      params.takerFeeRate,
      params.takeMaxAge,
      params.maxTtl,
      params.maxMakers,
      true
    );
  }

  function enableActionCount() public pure returns (uint) {
    return 1;
  }

  /// @dev Digest is keccak(to ‖ keccak(data)), as deploy-eurc-future-v3.s.sol's.
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

