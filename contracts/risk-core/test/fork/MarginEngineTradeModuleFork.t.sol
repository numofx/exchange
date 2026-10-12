// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployMarginEngine} from "../../scripts/deploy-margin-engine.s.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {StandardManager} from "../../src/risk-managers/StandardManager.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";

/// @dev contracts/execution's Matching and TradeModule, as deployed. Declared here rather than imported: the execution
///      tree builds separately. The structs are field-for-field copies of IActionVerifier.Action and ITradeModule's.
struct Action {
  uint subaccountId;
  uint nonce;
  address module;
  bytes data;
  uint expiry;
  address owner;
  address signer;
}

struct TradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct FillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct OrderData {
  uint takerAccount;
  uint takerFee;
  FillDetails[] fillDetails;
  bytes managerData;
}

interface IMatchingLike {
  function verifyAndMatch(Action[] memory actions, bytes[] memory signatures, bytes memory actionData) external;
  function depositSubAccount(uint accountId) external;
  function setTradeExecutor(address tradeExecutor, bool canExecute) external;
  function domainSeparator() external view returns (bytes32);
  function getActionHash(Action memory action) external pure returns (bytes32);
  function allowedModules(address module) external view returns (bool);
}

interface ITradeModuleLike {
  function matching() external view returns (address);
  function quoteAsset() external view returns (address);
  function feeRecipient() external view returns (uint);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

/**
 * @title MarginEngineTradeModuleFork
 * @notice Real fills of the future: signed orders matched through the live Matching and the live cNGN TradeModule, the
 *         way the matcher submits them, on accounts under the MarginEngine.
 *
 * Every other engine test opens positions straight through SubAccounts. This one goes through the venue's actual order
 * path: the signatures, the TradeModule's dated-future branch (no quote leg; the fill price carried to the future in
 * assetData), its fee leg into the fee account under the old SRM, and the engine's margin check on both sides.
 *
 * At head, with the deploy script and both vault batches run as on mainnet. The index is held with mockCall once the
 * test warps, as in MarginEngineDeployFork; nothing else is mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract MarginEngineTradeModuleFork is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint64 constant EXPIRY = 1796047200;
  uint constant CARRY = 0.2e18;

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint makerPk = uint(keccak256("numo.margin-engine.trade-fork.maker"));
  uint takerPk = uint(keccak256("numo.margin-engine.trade-fork.taker"));
  uint forwardPk = uint(keccak256("numo.margin-engine.trade-fork.forward-signer"));
  address maker;
  address taker;
  address executor = address(0xE1EC);

  DeployMarginEngine script;
  DeployMarginEngine.Params params;
  DeployMarginEngine.Deployment d;
  SubAccounts subAccounts;
  IMatchingLike matching;
  ITradeModuleLike tradeModule;

  uint spot;
  uint mark0;
  uint nonce;
  uint makerAcc;
  uint takerAcc;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    script = new DeployMarginEngine();

    string memory stack = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_PERP_STACK.json"));
    (spot,) = ISpotFeed(vm.parseJsonAddress(stack, ".indexFeed")).getSpot();
    uint index = 1e36 / spot;
    vm.setEnv("CARRY", vm.toString(CARRY));
    vm.setEnv("INITIAL_MARK", vm.toString(index + index * CARRY / 1e18 * (uint(EXPIRY) - block.timestamp) / 365 days));
    vm.setEnv("FORWARD_SIGNER", vm.toString(vm.addr(forwardPk)));
    params = script.loadParams();
    subAccounts = SubAccounts(params.subAccounts);
    d = script.deploy(params);

    tradeModule = ITradeModuleLike(params.perpTradeModule);
    matching = IMatchingLike(tradeModule.matching());
    assertTrue(matching.allowedModules(address(tradeModule)), "the live TradeModule trades on this Matching");
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);

    _execute(script.vaultActionsJson(d, params), script.vaultActionCount(d));
    mark0 = d.future.futureContracts(d.subId).markPrice;
    makerAcc = _openFundedAccount(maker, 1_000e6);
    takerAcc = _openFundedAccount(taker, 1_000e6);
  }

  // ---------------------------------------------------------------------------------------------

  /// Before the enable batch the future is unregistered and its cap is zero: the venue cannot trade it.
  function testTheBookIsClosedUntilTheEnableBatch() public {
    assertFalse(tradeModule.isDatedFutureAsset(address(d.future)), "unregistered before enable");
    _expectFillReverts(1e18, int(mark0), 0);
  }

  /// The future fills through the venue's order path: positions on both sides, no quote leg, margin checked by the
  /// engine on both accounts.
  function testAFutureFillsThroughTheLiveTradeModule() public {
    _enable();
    int takerCash = _cashOf(takerAcc);
    int makerCash = _cashOf(makerAcc);
    _fill(1e18, int(mark0), 0);

    assertEq(subAccounts.getBalance(takerAcc, d.future, d.subId), 1e18, "taker long one contract");
    assertEq(subAccounts.getBalance(makerAcc, d.future, d.subId), -1e18, "maker short one contract");
    assertEq(_cashOf(takerAcc), takerCash, "no quote leg: a future moves no premium");
    assertEq(_cashOf(makerAcc), makerCash, "no quote leg: a future moves no premium");
    assertGt(d.engine.getMargin(takerAcc, true), 0, "both sides above IM after the fill");
    assertGt(d.engine.getMargin(makerAcc, true), 0, "both sides above IM after the fill");
  }

  /// The fill price reaches the future: traded 1% above the mark, the long owes the difference as VM and the short is
  /// owed it. The engine settles VM before its risk check, so it is paid within the fill: the pool, unseeded, takes the
  /// long's cash and pays the short. A TradeModule that dropped the price (assetData 0) would move nothing.
  function testTheFillPriceReachesTheFuture() public {
    _enable();
    int takerCash = _cashOf(takerAcc);
    int makerCash = _cashOf(makerAcc);
    _fill(1e18, int(mark0) * 101 / 100, 0);
    int paid = takerCash - _cashOf(takerAcc);
    int received = _cashOf(makerAcc) - makerCash;
    assertGt(paid, 0, "the long bought above the mark: it paid VM in the fill");
    assertApproxEqAbs(received, paid, 1e12, "and the short received it");
    assertEq(d.future.getPendingVM(takerAcc, d.subId), 0, "settled, not left pending");
  }

  /// A fill outside the index band is refused by the future, through the TradeModule.
  function testAFillOutsideTheIndexBandIsRefused() public {
    _enable();
    uint band = d.future.markIndexBand(EXPIRY);
    uint index = 1e36 / spot;
    int outside = int(index + index * band / 1e18) * 102 / 100;
    _expectFillRevertsWith(1e18, outside, 0, IFutureAsset.FA_FillOutsideIndexBand.selector);
  }

  /// The taker fee is collected in the perp cash, into the TradeModule's fee account under the old SRM: a transfer
  /// across managers that runs both hooks.
  function testTheTakerFeeIsCollectedInPerpCash() public {
    _enable();
    uint feeAcc = tradeModule.feeRecipient();
    assertEq(address(subAccounts.manager(feeAcc)), params.srm, "the fee account sits under the old SRM");
    StandardManager(params.srm).settleInterest(feeAcc); // so the delta below is the fee alone
    int feeBefore = _cashOf(feeAcc);
    int takerCash = _cashOf(takerAcc);
    _fill(1e18, int(mark0), 1e18); // $1
    assertEq(_cashOf(feeAcc) - feeBefore, 1e18, "the fee lands in the fee account");
    assertEq(takerCash - _cashOf(takerAcc), 1e18, "paid by the taker in perp cash");
  }

  /// Fills that pay a fee also depend on the old SRM: its fee account is under it, so a pause there stops them.
  function testPausingTheOldSrmStopsFillsThatPayAFee() public {
    _enable();
    StandardManager srm = StandardManager(params.srm);
    vm.prank(srm.guardian());
    srm.setAdjustmentsPaused(true);
    _expectFillRevertsWith(1e18, int(mark0), 1e18, IBaseManager.BM_AdjustmentsPaused.selector);
  }

  /// The engine refuses an order the account cannot margin, on the venue path as on a direct transfer.
  function testAnUndermarginedOrderIsRefusedByTheEngine() public {
    _enable();
    // IM is 25% of notional: 1,000 USDC margins about eight contracts, not ten (inside the 15-a-side cap)
    _expectFillRevertsWith(10e18, int(mark0), 0, IMarginEngine.SRM_PortfolioBelowMargin.selector);
  }

  // ---------------------------------------------------------------------------------------------
  // orders, signed as the matcher's clients sign them
  // ---------------------------------------------------------------------------------------------

  function _fill(uint amount, int price, uint takerFee) internal {
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) = _order(amount, price, takerFee);
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _expectFillReverts(uint amount, int price, uint takerFee) internal {
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) = _order(amount, price, takerFee);
    vm.prank(executor);
    vm.expectRevert();
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _expectFillRevertsWith(uint amount, int price, uint takerFee, bytes4 selector) internal {
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) = _order(amount, price, takerFee);
    vm.prank(executor);
    vm.expectRevert(selector);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _order(uint amount, int price, uint takerFee)
    internal
    returns (Action[] memory actions, bytes[] memory sigs, bytes memory orderData)
  {
    nonce++;
    actions = new Action[](2);
    sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, taker, takerPk, price, amount);
    (actions[1], sigs[1]) = _sign(makerAcc, false, maker, makerPk, price, amount);
    FillDetails[] memory fills = new FillDetails[](1);
    fills[0] = FillDetails({filledAccount: makerAcc, amountFilled: amount, price: price, fee: 0});
    orderData = abi.encode(OrderData({takerAccount: takerAcc, takerFee: takerFee, fillDetails: fills, managerData: ""}));
  }

  function _sign(uint accountId, bool isBid, address owner, uint pk, int price, uint amount)
    internal
    view
    returns (Action memory action, bytes memory signature)
  {
    action = Action({
      subaccountId: accountId,
      nonce: nonce,
      module: address(tradeModule),
      data: abi.encode(
        TradeData({
          asset: address(d.future),
          subId: d.subId,
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

  // ---------------------------------------------------------------------------------------------

  function _enable() internal {
    _execute(script.enableActionsJson(d, params), script.enableActionCount());
    vm.mockCall(params.indexFeed, abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(spot, 1e18));
  }

  function _execute(string memory json, uint count) internal {
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      assertEq(
        vm.parseJsonBytes32(json, string.concat(key, ".digest")), keccak256(abi.encodePacked(to, keccak256(data)))
      );
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, string.concat("vault action ", vm.toString(i), " failed"));
    }
  }

  function _openFundedAccount(address owner, uint usdcAmount) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(d.engine)));
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(params.cash, usdcAmount);
    CashAsset(params.cash).deposit(accountId, usdcAmount);
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  function _cashOf(uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, IAsset(params.cash), 0);
  }
}
