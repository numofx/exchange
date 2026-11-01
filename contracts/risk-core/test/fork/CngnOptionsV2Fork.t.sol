// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {OptionAsset} from "../../src/assets/OptionAsset.sol";
import {FutureAsset} from "../../src/assets/FutureAsset.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {LyraVolFeed} from "../../src/feeds/LyraVolFeed.sol";
import {FutureFixingSettlementFeed} from "../../src/feeds/FutureFixingSettlementFeed.sol";
import {BaseLyraFeed} from "../../src/feeds/BaseLyraFeed.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseManager} from "../../src/interfaces/IBaseManager.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IFutureAsset} from "../../src/interfaces/IFutureAsset.sol";
import {ISpotFeed} from "../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../../src/interfaces/IVolFeed.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {ILyraVolFeed} from "../../src/interfaces/ILyraVolFeed.sol";
import {OptionEncoding} from "lyra-utils/encoding/OptionEncoding.sol";
import {Black76} from "lyra-utils/math/Black76.sol";
import {FixedPointMathLib} from "lyra-utils/math/FixedPointMathLib.sol";

/// @dev contracts/execution's Matching and TradeModule, as deployed: declared here, as in EurcFutureV2Fork.
struct EAction {
  uint subaccountId;
  uint nonce;
  address module;
  bytes data;
  uint expiry;
  address owner;
  address signer;
}

struct ETradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct EFillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct EOrderData {
  uint takerAccount;
  uint takerFee;
  EFillDetails[] fillDetails;
  bytes managerData;
}

interface IEMatching {
  function verifyAndMatch(EAction[] memory actions, bytes[] memory signatures, bytes memory actionData) external;
  function depositSubAccount(uint accountId) external;
  function setTradeExecutor(address tradeExecutor, bool canExecute) external;
  function domainSeparator() external view returns (bytes32);
  function getActionHash(EAction memory action) external pure returns (bytes32);
}

interface IETradeModule {
  function matching() external view returns (address);
  function quoteAsset() external view returns (address);
  function isPerpAsset(address asset) external view returns (bool);
  function isDatedFutureAsset(address asset) external view returns (bool);
}

/**
 * cNGN-USDC options on the live MarginEngine v2 (0x0705…, cNGN market 1), first expiry 30NOV26 with the future.
 *
 * Deploys an OptionAsset and a LyraVolFeed on a Base fork pinned before any options batch, executes the batch the vault
 * would (whitelist, margin params, oracle contingency, oracles, cap) and proves:
 *   - the batch leaves every live account's margin and every neighbouring setting exactly as it was; and that check
 *     catches the one dangerous action, setOraclesForMarket, which rewrites market 1's spot feed along with the rest;
 *   - the future's own forward feed serves options at their expiry, unchanged;
 *   - vol and Black-76 marks hold their precision at cNGN's ~0.00072 USDC strikes;
 *   - the option deploys closed (cap 0) and opens on the cap alone;
 *   - a short put opened at exactly initial margin stays solvent through a 25% devaluation step;
 *   - a stale vol feed halts option accounts' margin (so their liquidations) but not futures-only accounts, still lets
 *     a short close, and recovers on the next publish;
 *   - low vol confidence raises initial margin only: maintenance, and so liquidation, is untouched (the "degrade" mode);
 *   - an expiry the vol feed has not published cannot be shorted.
 *
 * Margin parameters below are CANDIDATES for the batch, chosen here to be tested, not decided.
 *
 * The cNGN index is held with mockCall (its heartbeat is 20 minutes); the forward feed is read live where no time
 * passes and held where it does. Requires BASE_RPC_URL.
 */
contract CngnOptionsV2Fork is Test {
  using FixedPointMathLib for uint;

  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint constant MARKET = 1;
  address constant TRADE_MODULE = 0xDea968188598BA0E3F58A56C0fdfF338C74F699f; // MARGIN_ENGINE_V2.json tradeModule
  uint64 constant EXPIRY = 1796047200; // 2026-11-30 14:00 UTC, cNGN-30NOV26's

  // Before any options action, 2026-11-01. The world after the batch is asserted by this suite, not read at head.
  uint constant FORK_BLOCK = 53_390_600;

  // CANDIDATE parameters, under test
  uint constant ATM_VOL = 0.4e18;
  uint constant OPTION_CAP = 100_000_000e18; // 100M cNGN of options, both sides
  uint64 constant VOL_HEARTBEAT = 30 minutes;

  // Derived rather than memorable: well-known keys carry EIP-7702 delegations on Base.
  uint volPk = uint(keccak256("numo.cngn-options-v2-fork.vol-signer"));
  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address executor = address(0xE1EC);
  uint makerPk = uint(keccak256("numo.cngn-options-v2-fork.maker"));
  uint takerPk = uint(keccak256("numo.cngn-options-v2-fork.taker"));
  uint nonce;
  IEMatching matching;

  SubAccounts subAccounts;
  MarginEngine engine;
  CashAsset cash;
  ISpotFeed spotFeed; // the live cNGN index, market 1's spot
  IForwardFeed forwardFeed; // the future's LyraForwardFeed
  FutureAsset future;
  OptionAsset option;
  LyraVolFeed volFeed;
  FutureFixingSettlementFeed settlement;

  uint spot; // USDC per cNGN, live at the fork block
  uint fwd; // the forward at EXPIRY, live at the fork block

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    string memory v2 = vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/MARGIN_ENGINE_V2.json"));
    engine = MarginEngine(vm.parseJsonAddress(v2, ".manager"));
    subAccounts = SubAccounts(address(engine.subAccounts()));
    cash = CashAsset(vm.parseJsonAddress(v2, ".cash"));
    spotFeed = ISpotFeed(vm.parseJsonAddress(v2, ".indexFeed"));
    forwardFeed = IForwardFeed(vm.parseJsonAddress(v2, ".forwardFeed"));
    future = FutureAsset(vm.parseJsonAddress(v2, ".future"));

    (spot,) = spotFeed.getSpot();
    (fwd,) = forwardFeed.getForwardPrice(EXPIRY);

    // what the deploy script will do: deploy, configure, hand both to the vault
    settlement = new FutureFixingSettlementFeed(future);
    option = new OptionAsset(subAccounts, address(settlement));
    volFeed = new LyraVolFeed();
    volFeed.addSigner(vm.addr(volPk), true);
    volFeed.setHeartbeat(VOL_HEARTBEAT);
    option.transferOwnership(VAULT);
    volFeed.transferOwnership(VAULT);
    vm.startPrank(VAULT);
    option.acceptOwnership();
    volFeed.acceptOwnership();
    vm.stopPrank();
  }

  ///////////////////////
  //  the live engine  //
  ///////////////////////

  function testTheLiveEngineIsWhatTheBatchExpects() public view {
    assertEq(engine.owner(), VAULT);
    assertEq(engine.lastMarketId(), 2);
    (ISpotFeed s, IForwardFeed f, IVolFeed v) = engine.getMarketFeeds(MARKET);
    assertEq(address(s), address(spotFeed), "market 1 reads the cNGN index");
    assertEq(address(f), address(0), "no forward yet");
    assertEq(address(v), address(0), "no vol yet");
    assertEq(address(engine.assetMap(MARKET, IMarginEngine.AssetType.Option)), address(0), "no option yet");
    assertEq(address(engine.assetMap(MARKET, IMarginEngine.AssetType.Future)), address(future));
    assertEq(future.futureContracts(EXPIRY).expiry, EXPIRY, "the options' expiry is the future's");
  }

  /// @dev The future's forward feed prices from the same index and already publishes for EXPIRY.
  function testTheFutureForwardFeedServesTheOptionsExpiry() public view {
    assertGt(fwd, 0);
    assertApproxEqRel(fwd, spot, 0.02e18, "forward within 2% of the index, a month out");
  }

  /////////////////
  //  the batch  //
  /////////////////

  /// @dev Every live v2 account margins identically (IM and MM), and nothing a neighbour reads moves.
  function testTheBatchLeavesLiveAccountsAndNeighboursUnchanged() public {
    uint[5] memory live = [uint(37), 39, 40, 42, 43]; // pool, future makers cNGN/EURC, spot makers cNGN/EURC
    int[10] memory before;
    for (uint i; i < live.length; ++i) {
      before[2 * i] = engine.getMargin(live[i], true);
      before[2 * i + 1] = engine.getMargin(live[i], false);
    }
    bytes32 settings = _neighbourSettings();

    _batch(address(spotFeed));

    for (uint i; i < live.length; ++i) {
      assertEq(engine.getMargin(live[i], true), before[2 * i], string.concat("IM moved: ", vm.toString(live[i])));
      assertEq(engine.getMargin(live[i], false), before[2 * i + 1], string.concat("MM moved: ", vm.toString(live[i])));
    }
    assertEq(_neighbourSettings(), settings, "a neighbouring setting moved");

    (ISpotFeed s, IForwardFeed f, IVolFeed v) = engine.getMarketFeeds(MARKET);
    assertEq(address(s), address(spotFeed));
    assertEq(address(f), address(forwardFeed));
    assertEq(address(v), address(volFeed));
    assertEq(address(engine.assetMap(MARKET, IMarginEngine.AssetType.Option)), address(option));
  }

  /// @dev Break it: setOraclesForMarket writes all three feeds at once. A batch that gets the spot wrong breaks every
  ///      live cNGN account, and the test above sees it.
  function testAWrongSpotFeedInTheBatchBreaksLiveAccountsAndIsCaught() public {
    bytes32 settings = _neighbourSettings();
    _batch(address(0));
    vm.expectRevert();
    engine.getMargin(39, true); // the cNGN future maker
    vm.expectRevert();
    engine.getMargin(42, true); // the cNGN spot maker
    assertTrue(_neighbourSettings() != settings, "the neighbour check catches it");
  }

  ///////////////////////////
  //  vol at cNGN's scale  //
  ///////////////////////////

  function testVolAtCngnStrikesHasTheCandidateShape() public {
    _batch(address(spotFeed));
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    uint atmK = _strike(fwd);
    (uint atm,) = volFeed.getVol(uint128(atmK), EXPIRY);
    (uint down,) = volFeed.getVol(uint128(_strike(fwd * 80 / 100)), EXPIRY);
    (uint up,) = volFeed.getVol(uint128(_strike(fwd * 120 / 100)), EXPIRY);
    assertApproxEqRel(atm, ATM_VOL, 0.005e18, "ATM is the hand-set level");
    assertGt(down, atm, "the devaluation wing is dearer");
    assertApproxEqRel(up, atm, 0.05e18, "the revaluation wing near ATM");
    assertGt(down, up, "skewed to cNGN puts");
    emit log_named_decimal_uint("vol at 0.8F", down, 18);
    emit log_named_decimal_uint("vol at F", atm, 18);
    emit log_named_decimal_uint("vol at 1.2F", up, 18);
  }

  /// @dev Strikes are stored to 1e-8 USDC: about 0.0014% of a cNGN, fine enough for a strike grid, and a finer one is
  ///      refused rather than rounded.
  function testStrikeGranularityAtCngnScale() public {
    uint k = 0.00072e18;
    uint96 subId = OptionEncoding.toSubId(EXPIRY, k, false);
    (uint e, uint k2, bool isCall) = OptionEncoding.fromSubId(subId);
    assertEq(e, EXPIRY);
    assertEq(k2, k);
    assertFalse(isCall);
    vm.expectRevert(abi.encodeWithSelector(OptionEncoding.OE_StrikeTooGranular.selector, k + 1));
    this.encode(k + 1);
  }

  function encode(uint strike) external pure returns (uint96) {
    return OptionEncoding.toSubId(EXPIRY, strike, false);
  }

  /// @dev An ATM option's Black-76 mark ~ F * vol * sqrt(T) / sqrt(2 pi): the engine's mark at F ~ 7e14 wei must agree.
  function testAtmMarkHoldsPrecisionAtCngnScale() public {
    _batch(address(spotFeed));
    _holdSpot(spot);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    uint k = _strike(fwd);
    int size = 1_000_000e18; // 1M cNGN, one future contract's worth
    (, int callMtm) = engine.getIsolatedMargin(MARKET, k, EXPIRY, true, size, true);
    (, int putMtm) = engine.getIsolatedMargin(MARKET, k, EXPIRY, false, size, true);
    uint tau = Black76.annualise(uint64(EXPIRY - block.timestamp));
    uint approx = fwd * ATM_VOL / 1e18 * FixedPointMathLib.sqrt(tau) / 1e18 * 398_942 / 1_000_000 * 1_000_000;
    assertApproxEqRel(uint(callMtm), approx, 0.01e18, "ATM call mark");
    // put-call parity at K ~ F (no discounting): C - P = F - K
    assertApproxEqAbs(callMtm - putMtm, (int(fwd) - int(k)) * 1_000_000, 1e15, "parity");
  }

  ///////////////////
  //  open/closed  //
  ///////////////////

  function testDeploysClosedAndOpensOnTheCapAlone() public {
    _batch(address(spotFeed));
    _holdSpot(spot);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    (uint seller, uint buyer) = _fundedAccounts(1_000e6, 1_000e6);
    uint96 subId = OptionEncoding.toSubId(EXPIRY, _strike(fwd), false);
    vm.expectRevert(IBaseManager.BM_AssetCapExceeded.selector);
    _trade(seller, buyer, subId, 100_000e18, 0);
    _openCap();
    _trade(seller, buyer, subId, 100_000e18, 0);
    assertEq(subAccounts.getBalance(buyer, option, subId), 100_000e18);
    assertEq(subAccounts.getBalance(seller, option, subId), -100_000e18);
  }

  //////////////////////////
  //  devaluation step    //
  //////////////////////////

  /// @dev A naked ATM put written with exactly initial margin: the index and forward step 25% down (cNGN devalues), vol
  ///      jumps to 80%. The writer's account is still worth more than nothing: the step is covered.
  function testAShortPutAtInitialMarginSurvivesATwentyFivePercentStep() public {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    uint96 subId = OptionEncoding.toSubId(EXPIRY, _strike(fwd), false);
    int size = 1_000_000e18;

    uint writer = _account(alice);
    uint holder = _account(bob);
    _depositUsdc(bob, holder, 10_000e6);
    _depositUsdc(alice, writer, 10_000e6);
    (, int putMtm) = engine.getIsolatedMargin(MARKET, _strike(fwd), EXPIRY, false, -size, true);
    uint premium = uint(-putMtm);
    _trade(writer, holder, subId, uint(size), premium);

    // take out everything above initial margin, leaving the writer exactly at IM
    int excess = engine.getMargin(writer, true);
    assertGt(excess, 0);
    _withdrawCash(alice, writer, uint(excess) / 1e12);
    int atIm = engine.getMargin(writer, true);
    assertGe(atIm, 0);
    assertLt(atIm, 1e13, "at initial margin");

    // the step: index -25%, the forward with it (it is index + a small diff), vol doubled
    vm.warp(block.timestamp + 1 minutes);
    uint stepped = spot * 75 / 100;
    _holdSpot(stepped);
    _holdForward(fwd * 75 / 100);
    _publishVol(EXPIRY, 2 * ATM_VOL, 1e18);
    (, int equity) = engine.getMarginAndMarkToMarket(writer, false, 0);
    assertGt(equity, 0, "the writer is still solvent after the step");
    emit log_named_decimal_int("writer equity after 25% step (USDC)", equity, 18);
  }

  ///////////////////////
  //  stale/low conf   //
  ///////////////////////

  /// @dev Fail closed: past the heartbeat, option accounts cannot be margined (new risk and liquidations stop), futures-
  ///      only accounts carry on, a short can still close, and the next publish restores everything.
  function testStaleVolHaltsOptionAccountsOnlyAndRecovers() public {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _holdForward(fwd);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    (uint seller, uint buyer) = _fundedAccounts(2_000e6, 2_000e6);
    uint96 subId = OptionEncoding.toSubId(EXPIRY, _strike(fwd), false);
    _trade(seller, buyer, subId, 200_000e18, 0);

    vm.warp(block.timestamp + VOL_HEARTBEAT + 1);
    _holdSpot(spot);
    vm.expectRevert(IBaseLyraFeed.BLF_DataTooOld.selector);
    engine.getMargin(seller, false);
    vm.expectRevert(IBaseLyraFeed.BLF_DataTooOld.selector);
    _trade(seller, buyer, subId, 1e18, 0); // more risk: refused
    engine.getMargin(39, false); // the cNGN future maker: unaffected

    _trade(buyer, seller, subId, 200_000e18, 0); // the short buys back: no margin check needed
    assertEq(subAccounts.getBalance(seller, option, subId), 0, "closed while the feed was stale");

    _publishVol(EXPIRY, ATM_VOL, 1e18);
    engine.getMargin(buyer, false);
    _trade(seller, buyer, subId, 1e18, 0);
  }

  /// @dev Degrade: confidence under the threshold costs initial margin by (1 - conf) x OCFactor x spot x shorts, and
  ///      leaves maintenance exactly where it was.
  function testLowConfidenceRaisesInitialMarginNotMaintenance() public {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _holdForward(fwd);
    uint64 tau = uint64(Black76.annualise(uint64(EXPIRY - block.timestamp)));
    _publishVolAt(EXPIRY, ATM_VOL, 1e18, tau);
    (uint seller, uint buyer) = _fundedAccounts(2_000e6, 2_000e6);
    uint96 subId = OptionEncoding.toSubId(EXPIRY, _strike(fwd), false);
    uint shorts = 200_000e18;
    _trade(seller, buyer, subId, shorts, 0);

    // the baseline after the warp a republish needs, so theta is out of the comparison; then the same surface again
    // (same tau, so the same vols) with only the confidence lowered
    vm.warp(block.timestamp + 1);
    int im0 = engine.getMargin(seller, true);
    int mm0 = engine.getMargin(seller, false);
    _publishVolAt(EXPIRY, ATM_VOL, 0.5e18, tau);

    (, uint optionThreshold,, uint ocFactor) = _ocParams();
    assertLt(0.5e18, optionThreshold, "under the threshold");
    uint penalty = (1e18 - 0.5e18) * ocFactor / 1e18 * spot / 1e18 * shorts / 1e18;
    assertApproxEqAbs(im0 - engine.getMargin(seller, true), int(penalty), 1e6, "IM costs the penalty");
    assertEq(engine.getMargin(seller, false), mm0, "MM untouched: no one is liquidated for it");
  }

  /// @dev Only published expiries trade: shorting another is refused, not margined at a made-up vol.
  function testAnUnpublishedExpiryCannotBeShorted() public {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _holdForward(fwd);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    (uint seller, uint buyer) = _fundedAccounts(2_000e6, 2_000e6);
    uint96 other = OptionEncoding.toSubId(EXPIRY + 7 days, _strike(fwd), false);
    vm.mockCall(
      address(forwardFeed),
      abi.encodeWithSelector(IForwardFeed.getForwardPrice.selector, EXPIRY + 7 days),
      abi.encode(fwd, 1e18)
    );
    vm.expectRevert(ILyraVolFeed.LVF_MissingExpiryData.selector);
    _trade(seller, buyer, other, 1e18, 0);
  }

  //////////////////
  //  settlement  //
  //////////////////

  /// @dev The index fixing settles the future and, through the adapter, the options at the same price: a put written at
  ///      the forward pays (K - fixing) x size when cNGN fixes 10% down, the call nothing, and cash moves only between
  ///      the two sides.
  function testOptionsSettleAtTheFuturesIndexFixing() public {
    (uint writer, uint holder, uint96 put, uint96 call, uint k) = _openPutAndCall();
    uint fixing = spot * 90 / 100;
    _fixAtIndex(fixing);

    (bool settled, uint price) = settlement.getSettlementPrice(EXPIRY);
    assertTrue(settled);
    assertEq(price, fixing, "the index fixing");
    assertEq(price, future.futureContracts(EXPIRY).markPrice, "the future's own settlement price");

    // interest realised first: settleOptions realises it too, and it is not the payout
    int writerBefore = _settledCash(writer);
    int holderBefore = _settledCash(holder);
    engine.settleOptions(option, writer);
    engine.settleOptions(option, holder);
    int payout = int(k - fixing) * int(SETTLE_SIZE) / 1e18;
    assertGt(payout, 0);
    assertEq(_cash(holder) - holderBefore, payout, "the put holder is paid (K - fixing) x size");
    assertEq(writerBefore - _cash(writer), payout, "the writer pays exactly that");
    assertEq(subAccounts.getBalance(holder, option, put), 0, "put closed");
    assertEq(subAccounts.getBalance(holder, option, call), 0, "OTM call closed for nothing");
    assertEq(subAccounts.getBalance(writer, option, put), 0);
    assertEq(subAccounts.getBalance(writer, option, call), 0);
  }

  /// @dev Expired but not yet fixed: settleOptions does nothing, and the positions wait for the fixing.
  function testOptionsWaitForTheFixing() public {
    (uint writer,, uint96 put,,) = _openPutAndCall();
    vm.warp(EXPIRY + 1);
    (bool settled,) = settlement.getSettlementPrice(EXPIRY);
    assertFalse(settled);
    engine.settleOptions(option, writer);
    assertEq(subAccounts.getBalance(writer, option, put), -int(SETTLE_SIZE), "still open: no price yet");
  }

  /// @dev Break the fixing (no samples): the vault's bounded fallback settles the future after its delay, and the
  ///      options settle at that same price.
  function testTheVaultFallbackSettlesOptionsAtTheSamePrice() public {
    (uint writer, uint holder, uint96 put,, uint k) = _openPutAndCall();
    vm.warp(EXPIRY + future.fallbackDelay());
    _holdSpot(spot);
    uint fallbackPrice = future.fallbackReference(uint96(EXPIRY)) * 99 / 100; // inside the 2% band
    vm.prank(VAULT);
    future.setSettlementPrice(uint96(EXPIRY), fallbackPrice);

    (, uint price) = settlement.getSettlementPrice(EXPIRY);
    assertEq(price, fallbackPrice);
    int holderBefore = _settledCash(holder);
    engine.settleOptions(option, holder);
    engine.settleOptions(option, writer);
    int payout = k > fallbackPrice ? int(k - fallbackPrice) * int(SETTLE_SIZE) / 1e18 : int(0);
    assertEq(_cash(holder) - holderBefore, payout);
    assertEq(subAccounts.getBalance(writer, option, put), 0);
  }

  /// @dev An expiry no future lists cannot be settled, and says so.
  function testAnExpiryWithNoFutureIsRefusedBySettlement() public {
    uint64 other = EXPIRY + 7 days;
    vm.expectRevert(abi.encodeWithSelector(FutureFixingSettlementFeed.FFSF_NoFutureForExpiry.selector, other));
    settlement.getSettlementPrice(other);
  }

  /// @dev Why settlement needs a keeper at expiry: no vol can be published past expiry, so once the last publish ages
  ///      out, an unsettled option account cannot be margined (nor liquidated) until it is settled. Settling clears it.
  function testAnUnsettledExpiredAccountIsStuckUntilSettled() public {
    (uint writer,,,,) = _openPutAndCall();
    _recordFixing(spot);
    vm.warp(EXPIRY + VOL_HEARTBEAT + 1);
    _holdSpot(spot);
    vm.expectRevert(ILyraVolFeed.LVF_InvalidVolDataTimestamp.selector);
    this.publishVol(EXPIRY, ATM_VOL);
    vm.expectRevert(IBaseLyraFeed.BLF_DataTooOld.selector);
    engine.getMargin(writer, false);

    future.fixSettlementFromIndex(uint96(EXPIRY));
    engine.settleOptions(option, writer);
    engine.getMargin(writer, false); // no options left: margined again
  }

  function publishVol(uint64 expiry, uint atmVol) external {
    _publishVolAt(expiry, atmVol, 1e18, 1e15);
  }

  ////////////////////////////////
  //  through the live venue    //
  ////////////////////////////////

  /// @dev The live TradeModule needs no registration for options: an asset that is neither perp nor dated future fills
  ///      as price x amount in its quote asset (v2 cash), which is an option premium. Price is USDC per cNGN, amount in
  ///      cNGN; the writer is margined in the same batch.
  function testItFillsThroughTheLiveTradeModuleAsAPremium() public {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _holdForward(fwd);
    _publishVol(EXPIRY, ATM_VOL, 1e18);

    IETradeModule tm = IETradeModule(TRADE_MODULE);
    assertEq(tm.quoteAsset(), address(cash), "premium is paid in v2 cash");
    assertFalse(tm.isPerpAsset(address(option)));
    assertFalse(tm.isDatedFutureAsset(address(option)));
    // a trusted assessor is held to maintenance only: venue writers must stay at initial margin
    assertFalse(engine.trustedRiskAssessor(TRADE_MODULE), "TradeModule fills are checked at IM");
    matching = IEMatching(tm.matching());
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);

    uint takerAcc = _matchingAccount(vm.addr(takerPk), 1_000e6);
    uint makerAcc = _matchingAccount(vm.addr(makerPk), 1_000e6);
    uint96 subId = OptionEncoding.toSubId(EXPIRY, _strike(fwd), false);
    (, int putMtm) = engine.getIsolatedMargin(MARKET, _strike(fwd), EXPIRY, false, 1e18, true);
    int price = putMtm; // the premium per cNGN, at the mark
    uint amount = 1_000_000e18;

    int takerCash = _cash(takerAcc);
    int makerCash = _cash(makerAcc);
    _fill(takerAcc, makerAcc, subId, amount, price); // taker buys the put, maker writes it

    assertEq(subAccounts.getBalance(takerAcc, option, subId), int(amount), "taker long 1M cNGN of puts");
    assertEq(subAccounts.getBalance(makerAcc, option, subId), -int(amount), "maker short");
    int premium = price * int(amount) / 1e18;
    assertEq(takerCash - _cash(takerAcc), premium, "taker paid price x amount");
    assertEq(_cash(makerAcc) - makerCash, premium, "maker received it");
    emit log_named_decimal_int("premium for 1M cNGN ATM put (USDC)", premium, 18);

    // the writer is margined in the fill: one with too little cash cannot write
    uint thinAcc = _matchingAccount(vm.addr(makerPk), 20e6);
    // signed first: an expectRevert placed before _fill would be spent on the signing's view calls, not the match
    (EAction[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _prepareFill(takerAcc, thinAcc, subId, amount, price);
    vm.prank(executor);
    vm.expectRevert(IMarginEngine.SRM_PortfolioBelowMargin.selector);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  /////////////////
  //   helpers   //
  /////////////////

  /// @dev The batch, as the vault executes it. The cap is a separate (enable) action.
  function _batch(address spotForBatch) internal {
    vm.startPrank(VAULT);
    option.setWhitelistManager(address(engine), true);
    engine.whitelistAsset(option, MARKET, IMarginEngine.AssetType.Option);
    engine.setOptionMarginParams(MARKET, _candidateMarginParams());
    engine.setOracleContingencyParams(MARKET, _candidateOcParams());
    engine.setOraclesForMarket(MARKET, ISpotFeed(spotForBatch), forwardFeed, volFeed);
    vm.stopPrank();
  }

  uint constant SETTLE_SIZE = 1_000_000e18;

  /// @dev holder buys a put and a call at the forward from writer, premium paid at the mark.
  function _openPutAndCall() internal returns (uint writer, uint holder, uint96 put, uint96 call, uint k) {
    _batch(address(spotFeed));
    _openCap();
    _holdSpot(spot);
    _holdForward(fwd);
    _publishVol(EXPIRY, ATM_VOL, 1e18);
    k = _strike(fwd);
    put = OptionEncoding.toSubId(EXPIRY, k, false);
    call = OptionEncoding.toSubId(EXPIRY, k, true);
    writer = _account(alice);
    holder = _account(bob);
    _depositUsdc(alice, writer, 2_000e6);
    _depositUsdc(bob, holder, 2_000e6);
    _trade(writer, holder, put, SETTLE_SIZE, 0);
    _trade(writer, holder, call, SETTLE_SIZE, 0);
  }

  /// @dev Samples the future's fixing window (the keeper's job) with the index held at `price`, ending at expiry.
  function _recordFixing(uint price) internal {
    for (uint t = EXPIRY - 1 hours; t <= EXPIRY; t += 10 minutes) {
      vm.warp(t);
      _holdSpot(price);
      future.recordFixingSample(uint96(EXPIRY));
    }
  }

  function _fixAtIndex(uint price) internal {
    _recordFixing(price);
    vm.warp(EXPIRY + 1);
    future.fixSettlementFromIndex(uint96(EXPIRY));
  }

  function _openCap() internal {
    vm.prank(VAULT);
    option.setTotalPositionCap(engine, OPTION_CAP);
  }

  /// @dev CANDIDATES. IM 25-30% of spot on a naked short (a 25% devaluation step); MM 15%.
  function _candidateMarginParams() internal pure returns (IMarginEngine.OptionMarginParams memory) {
    return IMarginEngine.OptionMarginParams({
      maxSpotReq: 0.3e18,
      minSpotReq: 0.25e18,
      mmCallSpotReq: 0.15e18,
      mmPutSpotReq: 0.15e18,
      MMPutMtMReq: 0.5e18,
      unpairedIMScale: 1.2e18,
      unpairedMMScale: 1.1e18,
      mmOffsetScale: 1.05e18
    });
  }

  /// @dev CANDIDATES. Keeps perp and base thresholds as they are; adds the option threshold and factor.
  function _candidateOcParams() internal view returns (IMarginEngine.OracleContingencyParams memory p) {
    (uint perpT,, uint baseT, uint factor) = _ocParams();
    p = IMarginEngine.OracleContingencyParams({
      perpThreshold: perpT, optionThreshold: 0.8e18, baseThreshold: baseT, OCFactor: factor == 0 ? 0.5e18 : factor
    });
  }

  function _ocParams() internal view returns (uint, uint, uint, uint) {
    return engine.oracleContingencyParams(MARKET);
  }

  /// @dev SVI with ATM total variance from the hand-set level; m = 0, sigma 0.1, rho -0.5, b = 2 x ATM variance: the
  ///      left (cNGN down) wing rises ~20% over ATM at -20% moneyness, the right ~2%.
  function _publishVol(uint64 expiry, uint atmVol, uint64 confidence) internal {
    _publishVolAt(expiry, atmVol, confidence, uint64(Black76.annualise(uint64(expiry - block.timestamp))));
  }

  function _publishVolAt(uint64 expiry, uint atmVol, uint64 confidence, uint64 tau) internal {
    uint atmVar = atmVol * atmVol / 1e18 * tau / 1e18;
    uint sigma = 0.1e18;
    uint b = 2 * atmVar;
    int a = int(atmVar) - int(b * sigma / 1e18);
    bytes memory data = abi.encode(expiry, a, b, int(-0.5e18), int(0), sigma, fwd, tau, confidence);
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: data,
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    bytes32 structHash = keccak256(
      abi.encode(volFeed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp)
    );
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(volPk, MessageHashUtils.toTypedDataHash(volFeed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = vm.addr(volPk);
    volFeed.acceptData(abi.encode(feedData));
  }

  function _holdSpot(uint price) internal {
    vm.mockCall(address(spotFeed), abi.encodeWithSelector(ISpotFeed.getSpot.selector), abi.encode(price, 1e18));
  }

  function _holdForward(uint price) internal {
    vm.mockCall(
      address(forwardFeed),
      abi.encodeWithSelector(IForwardFeed.getForwardPrice.selector, EXPIRY),
      abi.encode(price, 1e18)
    );
  }

  /// @dev To the 1e-8 USDC grid OptionEncoding stores.
  function _strike(uint price) internal pure returns (uint) {
    return price / 1e10 * 1e10;
  }

  function _neighbourSettings() internal view returns (bytes32 h) {
    for (uint id = 1; id <= 2; ++id) {
      (uint f, uint s) = engine.baseMarginParams(id);
      (ISpotFeed sf,,) = engine.getMarketFeeds(id);
      address base = address(engine.assetMap(id, IMarginEngine.AssetType.Base));
      (uint mm, uint im) = engine.futureMarginRequirements(id);
      h = keccak256(
        abi.encode(
          h,
          f,
          s,
          address(sf),
          base,
          WrappedERC20Asset(base).totalPositionCap(engine),
          address(engine.assetMap(id, IMarginEngine.AssetType.Future)),
          mm,
          im
        )
      );
    }
    IFutureAsset.FutureContract memory c = future.futureContracts(EXPIRY);
    h = keccak256(
      abi.encode(h, future.totalPositionCap(engine), c.markPrice, c.lastMarkTime, engine.accId(), engine.lastMarketId())
    );
  }

  function _account(address user) internal returns (uint) {
    return subAccounts.createAccountWithApproval(user, address(this), IManager(address(engine)));
  }

  function _fundedAccounts(uint sellerUsdc, uint buyerUsdc) internal returns (uint seller, uint buyer) {
    seller = _account(alice);
    buyer = _account(bob);
    _depositUsdc(alice, seller, sellerUsdc);
    _depositUsdc(bob, buyer, buyerUsdc);
  }

  function _depositUsdc(address user, uint acc, uint amount) internal {
    deal(USDC, user, amount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(address(cash), amount);
    cash.deposit(acc, amount);
    vm.stopPrank();
  }

  function _withdrawCash(address user, uint acc, uint amount) internal {
    vm.prank(user);
    cash.withdraw(acc, amount, user);
  }

  /// @dev seller writes `amount` of the option to buyer, who pays `premium` (18dp USDC) for it.
  function _trade(uint seller, uint buyer, uint96 subId, uint amount, uint premium) internal {
    ISubAccounts.AssetTransfer[] memory t = new ISubAccounts.AssetTransfer[](premium == 0 ? 1 : 2);
    t[0] = ISubAccounts.AssetTransfer({
      fromAcc: seller, toAcc: buyer, asset: option, subId: subId, amount: int(amount), assetData: bytes32(0)
    });
    if (premium != 0) {
      t[1] = ISubAccounts.AssetTransfer({
        fromAcc: buyer,
        toAcc: seller,
        asset: IAsset(address(cash)),
        subId: 0,
        amount: int(premium),
        assetData: bytes32(0)
      });
    }
    subAccounts.submitTransfers(t, "");
  }

  function _settledCash(uint acc) internal returns (int) {
    engine.settleInterest(acc);
    return _cash(acc);
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, IAsset(address(cash)), 0);
  }

  function _matchingAccount(address owner, uint usdcAmount) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(engine)));
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(address(cash), usdcAmount);
    cash.deposit(accountId, usdcAmount);
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  function _fill(uint takerAcc, uint makerAcc, uint96 subId, uint amount, int price) internal {
    (EAction[] memory actions, bytes[] memory sigs, bytes memory orderData) =
      _prepareFill(takerAcc, makerAcc, subId, amount, price);
    vm.prank(executor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _prepareFill(uint takerAcc, uint makerAcc, uint96 subId, uint amount, int price)
    internal
    returns (EAction[] memory actions, bytes[] memory sigs, bytes memory orderData)
  {
    nonce++;
    actions = new EAction[](2);
    sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, takerPk, subId, price, amount);
    (actions[1], sigs[1]) = _sign(makerAcc, false, makerPk, subId, price, amount);
    EFillDetails[] memory fills = new EFillDetails[](1);
    fills[0] = EFillDetails({filledAccount: makerAcc, amountFilled: amount, price: price, fee: 0});
    orderData = abi.encode(EOrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: ""}));
  }

  function _sign(uint accountId, bool isBid, uint pk, uint96 subId, int price, uint amount)
    internal
    view
    returns (EAction memory action, bytes memory signature)
  {
    address owner = vm.addr(pk);
    action = EAction({
      subaccountId: accountId,
      nonce: nonce,
      module: TRADE_MODULE,
      data: abi.encode(
        ETradeData({
          asset: address(option),
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
