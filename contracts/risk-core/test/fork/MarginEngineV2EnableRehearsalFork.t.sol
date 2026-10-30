// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {FutureAsset} from "../../src/assets/FutureAsset.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";

/// @dev contracts/execution's Matching and TradeModule, as deployed: declared here, as in EurcFutureV2Fork.
struct RAction {
  uint subaccountId;
  uint nonce;
  address module;
  bytes data;
  uint expiry;
  address owner;
  address signer;
}

struct RTradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct RFillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct ROrderData {
  uint takerAccount;
  uint takerFee;
  RFillDetails[] fillDetails;
  bytes managerData;
}

interface IRMatching {
  function verifyAndMatch(RAction[] memory actions, bytes[] memory signatures, bytes memory actionData) external;
  function depositSubAccount(uint accountId) external;
  function tradeExecutors(address executor) external view returns (bool);
  function domainSeparator() external view returns (bytes32);
  function getActionHash(RAction memory action) external pure returns (bytes32);
}

interface IRTradeModule {
  function isDatedFutureAsset(address asset) external view returns (bool);
}

/**
 * The enable rehearsal for MarginEngine v2's two series, cNGN-30NOV26 and EURC-30NOV26, on a Base fork at head: the
 * deployed contracts as they stand, the marks the box's publishers have pushed, nothing deployed or mocked. It executes
 * MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS.json and EURC_FUTURE_V2_ENABLE_VAULT_ACTIONS.json byte for byte as the vault,
 * then trades each series through the live Matching and TradeModule with the venue's own executor, at its live mark.
 *
 * Run it just before proposing either batch. Once a cap is non-zero the enable has landed and there is nothing left to
 * rehearse, so the suite skips.
 *
 * Requires BASE_RPC_URL.
 */
contract MarginEngineV2EnableRehearsalFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant MATCHING = 0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191;
  address constant EXECUTOR = 0xF68ebcC8934B068655E1A4367Ba6C0e564678703; // the venue's KMS settlement key
  uint constant MAX_MARK_AGE = 2 hours; // the publishers mark hourly; forward-mark-late fires at 2h

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint makerPk = uint(keccak256("numo.v2-enable-rehearsal.maker"));
  uint takerPk = uint(keccak256("numo.v2-enable-rehearsal.taker"));

  SubAccounts subAccounts;
  MarginEngine engine;
  IRMatching matching;
  address tradeModule;
  address cash;
  FutureAsset cngn;
  uint cngnSubId;
  FutureAsset eurc;
  uint eurcSubId;
  FutureAsset v1Future;
  address v1Engine;
  uint nonce;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    string memory v2 = _artifact("MARGIN_ENGINE_V2");
    string memory e = _artifact("EURC_FUTURE_V2");
    string memory v1 = _artifact("MARGIN_ENGINE");
    engine = MarginEngine(vm.parseJsonAddress(v2, ".manager"));
    subAccounts = SubAccounts(address(engine.subAccounts()));
    matching = IRMatching(MATCHING);
    tradeModule = vm.parseJsonAddress(v2, ".tradeModule");
    cash = vm.parseJsonAddress(v2, ".cash");
    cngn = FutureAsset(vm.parseJsonAddress(v2, ".future"));
    cngnSubId = vm.parseJsonUint(v2, ".subId");
    eurc = FutureAsset(vm.parseJsonAddress(e, ".future"));
    eurcSubId = vm.parseJsonUint(e, ".subId");
    v1Future = FutureAsset(vm.parseJsonAddress(v1, ".future"));
    v1Engine = vm.parseJsonAddress(v1, ".manager");

    if (cngn.totalPositionCap(IManager(address(engine))) != 0 || eurc.totalPositionCap(IManager(address(engine))) != 0)
    {
      vm.skip(true);
    }
  }

  function testTheSeriesAreClosedAndMarkedBeforeEnable() public view {
    assertFalse(IRTradeModule(tradeModule).isDatedFutureAsset(address(cngn)), "cNGN not yet a dated future");
    assertFalse(IRTradeModule(tradeModule).isDatedFutureAsset(address(eurc)), "EURC not yet a dated future");
    _assertFreshMark(cngn, cngnSubId, "cNGN");
    _assertFreshMark(eurc, eurcSubId, "EURC");
    assertTrue(matching.tradeExecutors(EXECUTOR), "the venue's executor executes trades");
  }

  function testEnableOpensBothSeriesAndNothingElse() public {
    uint v1Cap = v1Future.totalPositionCap(IManager(v1Engine));
    bool v1Dated = IRTradeModule(tradeModule).isDatedFutureAsset(address(v1Future));
    _enableBoth();
    assertEq(cngn.totalPositionCap(IManager(address(engine))), 30e18, "cNGN cap 30 contracts");
    assertEq(eurc.totalPositionCap(IManager(address(engine))), 18e18, "EURC cap 18 contracts");
    assertTrue(IRTradeModule(tradeModule).isDatedFutureAsset(address(cngn)));
    assertTrue(IRTradeModule(tradeModule).isDatedFutureAsset(address(eurc)));
    assertEq(v1Future.totalPositionCap(IManager(v1Engine)), v1Cap, "v1's future untouched");
    assertEq(IRTradeModule(tradeModule).isDatedFutureAsset(address(v1Future)), v1Dated, "and its module flag");
  }

  function testEachSeriesFillsAtItsLiveMarkThroughTheVenue() public {
    _enableBoth();
    uint takerAcc = _matchingAccount(vm.addr(takerPk), 5_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 5_000e6);

    _fill(cngn, cngnSubId, takerAcc, makerAcc, 1e18);
    _fill(eurc, eurcSubId, takerAcc, makerAcc, 1e18);

    assertEq(subAccounts.getBalance(takerAcc, cngn, cngnSubId), 1e18, "taker long one cNGN contract");
    assertEq(subAccounts.getBalance(makerAcc, cngn, cngnSubId), -1e18, "maker short one");
    assertEq(subAccounts.getBalance(takerAcc, eurc, eurcSubId), 1e18, "taker long one EURC contract");
    assertEq(subAccounts.getBalance(makerAcc, eurc, eurcSubId), -1e18, "maker short one");
    assertGe(engine.getMargin(takerAcc, true), 0, "taker above initial margin");
    assertGe(engine.getMargin(makerAcc, true), 0, "maker above initial margin");
  }

  /// @dev A cap counts both sides: EURC's 18 is 9 contracts of open interest (9,000 EURC), cNGN's 30 is 15 (15M cNGN).
  function testEachCapHoldsAtHalfItsValueInOpenInterest() public {
    _enableBoth();
    uint takerAcc = _matchingAccount(vm.addr(takerPk), 20_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 20_000e6);
    _fill(eurc, eurcSubId, takerAcc, makerAcc, 9e18);
    _fillOverCap(eurc, eurcSubId, takerAcc, makerAcc);
    _fill(cngn, cngnSubId, takerAcc, makerAcc, 15e18);
    _fillOverCap(cngn, cngnSubId, takerAcc, makerAcc);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  function _artifact(string memory name) internal view returns (string memory) {
    return vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/", name, ".json"));
  }

  function _assertFreshMark(FutureAsset future, uint subId, string memory what) internal view {
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    assertGt(c.markPrice, 0, string.concat(what, " has a mark"));
    assertLe(block.timestamp - c.lastMarkTime, MAX_MARK_AGE, string.concat(what, "'s mark is fresh"));
  }

  function _enableBoth() internal {
    _executeFile("MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS", 2);
    _executeFile("EURC_FUTURE_V2_ENABLE_VAULT_ACTIONS", 2);
  }

  /// @dev Every action in the file, exactly as proposed (the count is pinned, so an added action fails here first).
  function _executeFile(string memory name, uint count) internal {
    string memory json = _artifact(name);
    assertFalse(vm.keyExistsJson(json, string.concat("[", vm.toString(count), "]")), "more actions than rehearsed");
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      assertEq(vm.parseJsonUint(json, string.concat(key, ".value")), 0, "no value");
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, string.concat(name, " action ", vm.toString(i), " failed"));
    }
  }

  function _matchingAccount(address owner, uint usdcAmount) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(engine)));
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(cash, usdcAmount);
    CashAsset(cash).deposit(accountId, usdcAmount);
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  /// @dev The taker buys `amount` from the maker at the series' live mark, signed and executed as the venue does.
  function _fill(FutureAsset future, uint subId, uint takerAcc, uint makerAcc, uint amount) internal {
    (RAction[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(future, subId, takerAcc, makerAcc, amount);
    vm.prank(EXECUTOR);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  /// @dev One more contract, which the cap refuses.
  function _fillOverCap(FutureAsset future, uint subId, uint takerAcc, uint makerAcc) internal {
    (RAction[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(future, subId, takerAcc, makerAcc, 1e18);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    vm.prank(EXECUTOR);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _order(FutureAsset future, uint subId, uint takerAcc, uint makerAcc, uint amount)
    internal
    returns (RAction[] memory actions, bytes[] memory sigs, bytes memory orderData)
  {
    int price = int(uint(future.futureContracts(subId).markPrice));
    nonce++;
    actions = new RAction[](2);
    sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(future, subId, takerAcc, true, takerPk, price, amount);
    (actions[1], sigs[1]) = _sign(future, subId, makerAcc, false, makerPk, price, amount);
    RFillDetails[] memory fills = new RFillDetails[](1);
    fills[0] = RFillDetails({filledAccount: makerAcc, amountFilled: amount, price: price, fee: 0});
    orderData = abi.encode(ROrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: ""}));
  }

  function _sign(FutureAsset future, uint subId, uint accountId, bool isBid, uint pk, int price, uint amount)
    internal
    view
    returns (RAction memory action, bytes memory signature)
  {
    address owner = vm.addr(pk);
    action = RAction({
      subaccountId: accountId,
      nonce: nonce,
      module: tradeModule,
      data: abi.encode(
        RTradeData({
          asset: address(future),
          subId: subId,
          limitPrice: price,
          desiredAmount: int(amount),
          worstFee: 1e18,
          recipientId: accountId,
          isBid: isBid
        })
      ),
      expiry: block.timestamp + 1 days,
      owner: owner,
      signer: owner
    });
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(action)));
    signature = bytes.concat(r, s, bytes1(v));
  }
}
