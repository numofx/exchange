// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployEurcSpot} from "../../scripts/deploy-eurc-spot.s.sol";
import {EURCSpotBatch} from "../../scripts/eurc-spot-batch.sol";
import {SubAccounts} from "../../src/SubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {BaseManager} from "../../src/risk-managers/BaseManager.sol";
import {ChainlinkSpotFeed, IAggregatorV3} from "../../src/feeds/ChainlinkSpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IManagerWhitelist} from "../../src/interfaces/IManagerWhitelist.sol";
import {
  Action,
  TradeData,
  FillDetails,
  OrderData,
  IMatchingLike,
  ITradeModuleLike
} from "./MarginEngineTradeModuleFork.t.sol";

/**
 * @title EurcSpotFork
 * @notice The EURC listing on the live MarginEngine: the deploy script and both vault batches run against Base as the
 *         vault would run them, then EURC is deposited, margined, borrowed against and traded for USDC through the live
 *         Matching and TradeModule.
 *
 * Pinned to a block before the batch (CLAUDE.md, "Chain state moves under tests"): the engine has one market there, and
 * the batch is only valid in that world. Once the batch has landed this suite describes history, and the head-state
 * assertions belong in a test of the deployed listing, not here.
 *
 * The EURC/USD aggregator is held with mockCall where a test moves the price or ages it; nothing else is mocked.
 *
 * Requires BASE_RPC_URL.
 */
contract EurcSpotFork is Test {
  uint constant FORK_BLOCK = 52893000;
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
  address constant TRADE_MODULE = 0xDea968188598BA0E3F58A56C0fdfF338C74F699f;

  uint makerPk = uint(keccak256("numo.eurc-spot-fork.maker"));
  uint takerPk = uint(keccak256("numo.eurc-spot-fork.taker"));
  address maker;
  address taker;
  address executor = address(0xE1EC);

  DeployEurcSpot script;
  DeployEurcSpot.Params params;
  DeployEurcSpot.Deployed d;
  EURCSpotBatch.Ctx ctx;
  MarginEngine engine;
  SubAccounts subAccounts;
  CashAsset cash;
  IMatchingLike matching;
  ITradeModuleLike tradeModule;
  IAsset cngnEscrow;
  uint marketOneFactor;
  uint marketOneScale;
  uint nonce;
  /// @dev The taker's signed per-unit fee ceiling; 1e18 (1 USDC per EURC) unless a test narrows it.
  uint takerWorstFee = 1e18;
  /// @dev EURC-USDC's taker fee in markets-service's registry (services/markets/internal/instruments/registry.go).
  uint constant TAKER_FEE_BPS = 5;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    script = new DeployEurcSpot();
    params = script.loadParams();
    d = script.deploy(params);
    ctx = script.batchCtx(d, params);
    engine = MarginEngine(params.engine);
    subAccounts = SubAccounts(params.subAccounts);
    tradeModule = ITradeModuleLike(TRADE_MODULE);
    cash = CashAsset(tradeModule.quoteAsset());
    matching = IMatchingLike(tradeModule.matching());
    cngnEscrow = engine.assetMap(1, IMarginEngine.AssetType.Base);
    (marketOneFactor, marketOneScale) = engine.baseMarginParams(1);
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);
  }

  // ---------------------------------------------------------------------------------------------
  // the batches
  // ---------------------------------------------------------------------------------------------

  /// The world the batch was written for: one market, owned by the vault, and the escrow and feed nominated to it.
  function testPreconditionsHoldAtThePinnedBlock() public view {
    assertEq(engine.lastMarketId(), 1, "one market before the batch");
    assertEq(params.marketId, 2, "createMarket returns 2");
    EURCSpotBatch.checkPreconditions(ctx);
  }

  /// The configuring batch builds market 2 and leaves market 1 exactly as it was.
  function testTheBatchListsEurcAsMarketTwo() public {
    _configure();
    assertEq(engine.lastMarketId(), 2);
    (ISpotFeed spot,,) = engine.getMarketFeeds(2);
    assertEq(address(spot), address(d.spotFeed), "market 2 reads the Chainlink adapter");
    (uint factor, uint scale) = engine.baseMarginParams(2);
    assertEq(factor, 0.9e18);
    assertEq(scale, 0.8e18);
    assertEq(address(engine.assetMap(2, IMarginEngine.AssetType.Base)), address(d.escrow));
    IMarginEngine.AssetDetail memory detail = engine.assetDetails(d.escrow);
    assertTrue(detail.isWhitelisted);
    assertEq(detail.marketId, 2);
    assertEq(d.escrow.totalPositionCap(IManager(address(engine))), 5_000_000e18);
    assertEq(d.escrow.owner(), VAULT);
    assertEq(d.spotFeed.owner(), VAULT);

    assertEq(address(engine.assetMap(1, IMarginEngine.AssetType.Base)), address(cngnEscrow), "cNGN still market 1");
    assertTrue(engine.assetDetails(cngnEscrow).isWhitelisted, "cNGN still whitelisted");
    (uint f1, uint s1) = engine.baseMarginParams(1);
    assertEq(f1, marketOneFactor, "market 1's haircut untouched");
    assertEq(s1, marketOneScale, "market 1's IM scale untouched");
  }

  /// The batch refuses a world where market 2 exists already: whitelisting into an occupied slot de-whitelists it.
  function testPreconditionsRefuseAnEngineWithASecondMarket() public {
    vm.prank(VAULT);
    engine.createMarket("OTHER");
    vm.expectRevert(bytes("PRE: createMarket would not return the recorded market id"));
    this.checkPreconditions(ctx);
  }

  /// The guard in front of cNGN. With the id check satisfied (lastMarketId mocked to 0, so 1 is "next"), a batch
  /// aimed at market 1 is still refused: its Base slot holds the cNGN escrow, which whitelistAsset would de-whitelist.
  function testPreconditionsRefuseAnOccupiedBaseSlot() public {
    EURCSpotBatch.Ctx memory wrong = ctx;
    wrong.marketId = 1;
    vm.mockCall(address(engine), abi.encodeWithSelector(engine.lastMarketId.selector), abi.encode(uint(0)));
    vm.expectRevert(bytes("PRE: the market's Base slot is occupied; whitelisting would de-whitelist it"));
    this.checkPreconditions(wrong);
  }

  /// Every prefix of the configuring batch leaves deposits shut: only the enable action opens them.
  function testDepositsAreShutUntilTheEnableAction() public {
    _configure();
    uint acc = subAccounts.createAccount(address(this), IManager(address(engine)));
    deal(EURC, address(this), 100e6);
    IERC20Metadata(EURC).approve(address(d.escrow), 100e6);
    vm.expectRevert(IManagerWhitelist.MW_UnknownManager.selector);
    d.escrow.deposit(acc, 100e6);

    _enable();
    d.escrow.deposit(acc, 100e6);
    assertEq(subAccounts.getBalance(acc, d.escrow, 0), 100e18, "6dp EURC lands as 18dp");
  }

  /// The cap is enforced on EURC deposits summed across the engine.
  function testTheCapRefusesADepositPastIt() public {
    _configure();
    _enable();
    uint acc = subAccounts.createAccount(address(this), IManager(address(engine)));
    deal(EURC, address(this), 5_000_001e6);
    IERC20Metadata(EURC).approve(address(d.escrow), 5_000_001e6);
    vm.expectRevert();
    d.escrow.deposit(acc, 5_000_001e6);
    d.escrow.deposit(acc, 5_000_000e6);
  }

  // ---------------------------------------------------------------------------------------------
  // margin
  // ---------------------------------------------------------------------------------------------

  /// EURC credits 90% of its oracle value at maintenance and 72% at initial margin.
  function testEurcCountsAsMarginAtTheHaircut() public {
    _ready();
    uint acc = _eurcAccount(address(this), 1_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    uint value = 1_000 * spot;
    assertApproxEqAbs(engine.getMargin(acc, false), int(value * 90 / 100), 1e6, "MM credit 90%");
    assertApproxEqAbs(engine.getMargin(acc, true), int(value * 72 / 100), 1e6, "IM credit 72%");
  }

  /// An account borrows USDC against EURC up to initial margin and no further.
  function testBorrowingAgainstEurcStopsAtInitialMargin() public {
    _ready();
    uint acc = _eurcAccount(address(this), 1_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    uint limit6 = 1_000 * spot * 72 / 100 / 1e12; // USDC, 6dp
    vm.expectRevert(IMarginEngine.SRM_PortfolioBelowMargin.selector);
    cash.withdraw(acc, limit6 + 1e6, address(this));
    cash.withdraw(acc, limit6 - 1e6, address(this));
    assertLt(subAccounts.getBalance(acc, cash, 0), 0, "borrowed");
  }

  /// What the haircut buys. From the IM limit, a 19% EURC drop leaves the account above maintenance, 21% makes it
  /// liquidatable while it is still solvent, and only past 28% is it under water. A one-day EUR/USD move has not
  /// exceeded 3%.
  function testTheHaircutLeavesALiquidationWindowBeforeInsolvency() public {
    _ready();
    uint acc = _eurcAccount(address(this), 1_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    cash.withdraw(acc, 1_000 * spot * 72 / 100 / 1e12 - 1e6, address(this));

    _setPrice(spot * 81 / 100);
    assertGt(engine.getMargin(acc, false), 0, "-19%: above maintenance");
    _setPrice(spot * 79 / 100);
    assertLt(engine.getMargin(acc, false), 0, "-21%: liquidatable");
    (, int mtm) = engine.getMarginAndMarkToMarket(acc, false, 0);
    assertGt(mtm, 0, "-21%: still solvent");
    _setPrice(spot * 71 / 100);
    (, mtm) = engine.getMarginAndMarkToMarket(acc, false, 0);
    assertLt(mtm, 0, "-29%: under water");
  }

  /// A stale feed fails closed for accounts holding EURC and for nobody else.
  function testAStaleFeedStopsOnlyEurcHolders() public {
    _ready();
    uint holder = _eurcAccount(address(this), 100e6);
    uint usdcOnly = subAccounts.createAccount(address(this), IManager(address(engine)));
    deal(USDC, address(this), 100e6);
    IERC20Metadata(USDC).approve(address(cash), 100e6);
    cash.deposit(usdcOnly, 100e6);

    (uint spot,) = d.spotFeed.getSpot();
    _mockRound(int(spot / 1e10), block.timestamp - 25 hours - 1);
    vm.expectRevert(ChainlinkSpotFeed.CLF_DataTooOld.selector);
    d.escrow.withdraw(holder, 1e6, address(this));
    cash.withdraw(usdcOnly, 50e6, address(this));

    _mockRound(int(spot / 1e10), block.timestamp - 25 hours + 60);
    d.escrow.withdraw(holder, 1e6, address(this));
  }

  // ---------------------------------------------------------------------------------------------
  // the venue's order path
  // ---------------------------------------------------------------------------------------------

  /// EURC-USDC fills through the live TradeModule: EURC moves seller to buyer, USDC cash price x amount the other way.
  function testASpotFillThroughTheLiveTradeModule() public {
    _ready();
    uint makerAcc = _eurcAccount(maker, 1_000e6);
    uint takerAcc = _usdcAccount(taker, 2_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    int price = int(spot);
    int takerCash = subAccounts.getBalance(takerAcc, cash, 0);
    int makerCash = subAccounts.getBalance(makerAcc, cash, 0);

    _fill(makerAcc, takerAcc, 100e18, price, 0);

    assertEq(subAccounts.getBalance(takerAcc, d.escrow, 0), 100e18, "buyer receives 100 EURC");
    assertEq(subAccounts.getBalance(makerAcc, d.escrow, 0), 900e18, "seller delivers it");
    assertEq(takerCash - subAccounts.getBalance(takerAcc, cash, 0), price * 100, "buyer pays price x amount");
    assertEq(subAccounts.getBalance(makerAcc, cash, 0) - makerCash, price * 100, "seller receives it");
  }

  /// The 5 bps taker fee is charged in USDC cash on top of the notional and lands in the TradeModule's fee account
  /// (under the old SRM: a transfer across managers, as on every market); the maker pays nothing.
  function testTheFiveBpsTakerFeeIsCollected() public {
    _ready();
    uint makerAcc = _eurcAccount(maker, 1_000e6);
    uint takerAcc = _usdcAccount(taker, 2_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    uint fee = spot * 100 * TAKER_FEE_BPS / 10_000; // 100 EURC: 5 bps of ~112 USDC, ~0.056 USDC
    uint feeAcc = tradeModule.feeRecipient();
    // The fee account's accrued interest would land with the fee; settle it first so the delta is the fee alone.
    BaseManager(address(subAccounts.manager(feeAcc))).settleInterest(feeAcc);
    int feeBefore = subAccounts.getBalance(feeAcc, cash, 0);
    int takerCash = subAccounts.getBalance(takerAcc, cash, 0);
    int makerCash = subAccounts.getBalance(makerAcc, cash, 0);

    _fill(makerAcc, takerAcc, 100e18, int(spot), fee);

    assertEq(subAccounts.getBalance(feeAcc, cash, 0) - feeBefore, int(fee), "the fee lands in the fee account");
    assertEq(takerCash - subAccounts.getBalance(takerAcc, cash, 0), int(spot) * 100 + int(fee), "taker: notional + fee");
    assertEq(subAccounts.getBalance(makerAcc, cash, 0) - makerCash, int(spot) * 100, "maker: notional, no fee");
  }

  /// The chain holds the taker to the per-unit fee ceiling it signed (the bound the market maker derives from
  /// /v1/markets): a ceiling of exactly 5 bps at the fill price clears a 5 bps fee, one wei less does not.
  function testTheTakersSignedCeilingBoundsTheFee() public {
    _ready();
    uint makerAcc = _eurcAccount(maker, 1_000e6);
    uint takerAcc = _usdcAccount(taker, 2_000e6);
    (uint spot,) = d.spotFeed.getSpot();
    uint perUnit = spot * TAKER_FEE_BPS / 10_000;
    uint fee = perUnit * 100;

    takerWorstFee = perUnit - 1;
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(makerAcc, takerAcc, 100e18, int(spot), fee);
    vm.prank(executor);
    vm.expectRevert();
    matching.verifyAndMatch(actions, sigs, orderData);

    takerWorstFee = perUnit;
    _fill(makerAcc, takerAcc, 100e18, int(spot), fee);
    assertEq(subAccounts.getBalance(takerAcc, d.escrow, 0), 100e18, "filled at a ceiling of exactly 5 bps");
  }

  /// Before the enable action the escrow refuses the engine, so the book cannot settle a fill.
  function testNoFillBeforeTheEnableAction() public {
    _configure();
    uint takerAcc = _usdcAccount(taker, 2_000e6);
    uint makerAcc = subAccounts.createAccount(maker, IManager(address(engine)));
    vm.startPrank(maker);
    subAccounts.approve(address(matching), makerAcc);
    matching.depositSubAccount(makerAcc);
    vm.stopPrank();
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(makerAcc, takerAcc, 1e18, int(1.1e18), 0);
    vm.prank(executor);
    vm.expectRevert();
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  // ---------------------------------------------------------------------------------------------

  function checkPreconditions(EURCSpotBatch.Ctx memory c) external view {
    EURCSpotBatch.checkPreconditions(c);
  }

  function _ready() internal {
    _configure();
    _enable();
  }

  function _configure() internal {
    EURCSpotBatch.checkPreconditions(ctx);
    _execute(script.vaultActionsJson(ctx), EURCSpotBatch.ACTION_COUNT);
  }

  function _enable() internal {
    _execute(script.enableActionsJson(ctx), EURCSpotBatch.ENABLE_ACTION_COUNT);
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

  function _setPrice(uint price18) internal {
    _mockRound(int(price18 / 1e10), block.timestamp);
  }

  function _mockRound(int answer8, uint updatedAt) internal {
    vm.mockCall(
      params.aggregator,
      abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
      abi.encode(uint80(1), answer8, updatedAt, updatedAt, uint80(1))
    );
  }

  function _eurcAccount(address owner, uint amount6) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, IManager(address(engine)));
    deal(EURC, address(this), amount6);
    IERC20Metadata(EURC).approve(address(d.escrow), amount6);
    d.escrow.deposit(acc, amount6);
    _toMatching(owner, acc);
  }

  function _usdcAccount(address owner, uint amount6) internal returns (uint acc) {
    acc = subAccounts.createAccount(owner, IManager(address(engine)));
    deal(USDC, address(this), amount6);
    IERC20Metadata(USDC).approve(address(cash), amount6);
    cash.deposit(acc, amount6);
    _toMatching(owner, acc);
  }

  /// Only the venue's own accounts go to Matching; a test that withdraws keeps its account.
  function _toMatching(address owner, uint acc) internal {
    if (owner == address(this)) return;
    vm.startPrank(owner);
    subAccounts.approve(address(matching), acc);
    matching.depositSubAccount(acc);
    vm.stopPrank();
  }

  function _fill(uint makerAcc, uint takerAcc, uint amount, int price, uint takerFee) internal {
    (Action[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _order(makerAcc, takerAcc, amount, price, takerFee);
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _order(uint makerAcc, uint takerAcc, uint amount, int price, uint takerFee)
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
          asset: address(d.escrow),
          subId: 0,
          limitPrice: price,
          desiredAmount: int(amount),
          worstFee: isBid ? takerWorstFee : 1e18,
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
