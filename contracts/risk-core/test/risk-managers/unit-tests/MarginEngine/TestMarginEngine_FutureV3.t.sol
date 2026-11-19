// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../../src/SubAccounts.sol";
import "../../../../src/risk-managers/MarginEnginePortfolioViewer.sol";
import "../../../../src/risk-managers/MarginEngine.sol";
import {IMarginEngine} from "../../../../src/interfaces/IMarginEngine.sol";
import {IVolFeed} from "../../../../src/interfaces/IVolFeed.sol";
import {FutureAsset} from "../../../../src/assets/FutureAsset.sol";
import {IFutureAsset} from "../../../../src/interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../../../../src/interfaces/IFutureAssetV3.sol";
import {ICashAsset} from "../../../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../../../src/interfaces/IDutchAuction.sol";
import {ISpotFeed} from "../../../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../../../src/interfaces/IForwardFeed.sol";

import "../../../shared/mocks/MockERC20.sol";
import "../../../shared/mocks/MockFeeds.sol";
import "../../../shared/mocks/MockCash.sol";
import "../../mocks/MockDutchAuction.sol";

/// @dev An index that reverts when stale, as EurcIndexFeed does (docs/eurc-usdc-futures-spec.md, A2.3).
contract StaleableSpotFeed is ISpotFeed {
  uint public spot;
  bool public stale;

  error StaleIndex();

  function set(uint _spot) external {
    spot = _spot;
    stale = false;
  }

  function setStale(bool _stale) external {
    stale = _stale;
  }

  function getSpot() external view returns (uint, uint) {
    if (stale) revert StaleIndex();
    return (spot, 1e18);
  }
}

/**
 * FutureAsset v3 under MarginEngine v2: recovery fixing, the timelocked per-window index feed, marks until settlement,
 * and no owner settlement price (docs/eurc-usdc-futures-spec.md, A8, tests A8.7). VM accounting and fills are v2's,
 * covered by TestMarginEngine_Future against FutureAssetV2; the engine tests here prove the deployed engine margins and
 * settles a v3 series unchanged.
 *
 * Prices are USDC per EURC: index and mark 1.10, one contract 1,000 EURC, so a 0.011 move is 11 USDC per contract.
 */
contract TestMarginEngine_FutureV3 is Test {
  SubAccounts subAccounts;
  MarginEngine manager;
  MarginEnginePortfolioViewer viewer;
  MockDutchAuction auction;
  MockCash cash;
  MockERC20 usdc;
  FutureAsset future;
  MockFeeds spotFeed; // the market's spot feed: non-reverting (A2.3 rule)
  MockFeeds forwardFeed;
  StaleableSpotFeed index;
  uint marketId;

  uint aliceAcc;
  uint bobAcc;
  uint pool;
  address alice = address(0xaa);
  address bob = address(0xbb);

  uint96 subId;
  uint expiry;

  uint constant CONTRACT_SIZE = 1_000e18;
  uint constant PRICE = 1.1e18;
  uint constant TIMELOCK = 2 days;
  uint constant WINDOW = 30 minutes;
  uint constant GAP = 5 minutes;
  uint constant RECOVERY_DELAY = 1 hours;
  uint constant NARROWING = 7 days;

  function setUp() public {
    vm.warp(1_790_000_000);
    subAccounts = new SubAccounts("Numo Margin Accounts", "NumoMarginNFTs");
    usdc = new MockERC20("USDC", "USDC");
    usdc.setDecimals(6);
    cash = new MockCash(usdc, subAccounts);
    viewer = new MarginEnginePortfolioViewer(subAccounts, cash);
    auction = new MockDutchAuction();

    index = new StaleableSpotFeed();
    index.set(PRICE);
    spotFeed = new MockFeeds();
    spotFeed.setSpot(PRICE, 1e18);
    forwardFeed = new MockFeeds();

    future = new FutureAsset(subAccounts, CONTRACT_SIZE, index, TIMELOCK);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, WINDOW, GAP, RECOVERY_DELAY);
    future.setForwardFeed(forwardFeed, 0);

    manager = new MarginEngine(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), viewer);
    viewer.setMarginEngine(manager);
    marketId = manager.createMarket("eur");
    manager.whitelistAsset(future, marketId, IMarginEngine.AssetType.Future);
    manager.setOraclesForMarket(marketId, ISpotFeed(address(spotFeed)), IForwardFeed(address(0)), IVolFeed(address(0)));
    MockFeeds stable = new MockFeeds();
    stable.setSpot(1e18, 1e18);
    manager.setStableFeed(stable);
    manager.setFutureMarginRequirements(marketId, 0.1e18, 0.2e18);
    pool = manager.accId();

    future.setWhitelistManager(address(manager), true);
    future.setTotalPositionCap(manager, 1e36);

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), manager);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), manager);

    expiry = block.timestamp + 30 days;
    subId = future.setContract(uint64(expiry), uint64(expiry - 1 hours), PRICE);
    forwardFeed.setForwardPrice(expiry, PRICE, 1e18);

    usdc.approve(address(cash), type(uint).max);
  }

  ///////////////////
  //    helpers    //
  ///////////////////

  function _fund(uint acc, uint amount18) internal {
    usdc.mint(address(this), amount18);
    cash.deposit(acc, amount18);
  }

  /// @dev bob sells one contract to alice at the mark, both funded well above IM
  function _open() internal {
    _fund(aliceAcc, 1_000e18);
    _fund(bobAcc, 1_000e18);
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: subId, amount: 1e18, assetData: bytes32(PRICE)
      }),
      ""
    );
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  /// @dev sample a window from `start` every GAP to `end` inclusive at `price`, leaving the clock at `end`
  function _sampleEvery(uint start, uint end, uint price) internal {
    index.set(price);
    for (uint t = start; t <= end; t += GAP) {
      vm.warp(t);
      future.recordFixingSample(subId);
    }
    vm.warp(end);
  }

  /// @dev the original window, sampled with one gap of 2 x GAP in the middle: it cannot complete
  function _breakOriginalWindow(uint price) internal {
    index.set(price);
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId);
    vm.warp(start + 2 * GAP + 1);
    future.recordFixingSample(subId);
    _sampleEvery(start + 3 * GAP + 1, expiry, price);
  }

  function _openRecovery() internal returns (uint start, uint end) {
    future.openRecoveryWindow(subId);
    IFutureAssetV3.Fixing memory f = future.fixings(subId);
    return (f.windowStart, f.windowEnd);
  }

  //////////////////////////////////////
  //  the engine margins v3 unchanged //
  //////////////////////////////////////

  /// @dev MarginEngine calls a future through IFutureAsset; v3 must answer the same selectors.
  function testEngineFacingSelectorsMatchIFutureAsset() public pure {
    assertEq(IFutureAssetV3.contractSize.selector, IFutureAsset.contractSize.selector);
    assertEq(IFutureAssetV3.futureContracts.selector, IFutureAsset.futureContracts.selector);
    assertEq(IFutureAssetV3.getPendingVM.selector, IFutureAsset.getPendingVM.selector);
    assertEq(IFutureAssetV3.settleAccountVM.selector, IFutureAsset.settleAccountVM.selector);
  }

  function testEngineSettlesVMAndClosesOutAV3Series() public {
    _open();
    vm.warp(block.timestamp + 1 days);
    index.set(1.111e18);
    forwardFeed.setForwardPrice(expiry, 1.111e18, 1e18);
    future.pullMark(subId);
    manager.settleAccount(aliceAcc);
    manager.settleAccount(bobAcc);
    assertEq(_cash(aliceAcc), 1_011e18, "long gains 0.011 x 1,000");
    assertEq(_cash(bobAcc), 989e18);
    assertEq(_cash(pool), 0, "zero-sum");

    _sampleEvery(expiry - WINDOW, expiry, 1.111e18);
    future.fixSettlementFromIndex(subId);
    manager.closeOutExpired(aliceAcc, subId);
    manager.closeOutExpired(bobAcc, subId);
    assertEq(subAccounts.getBalance(aliceAcc, future, subId), 0);
    assertEq(_cash(aliceAcc) + _cash(bobAcc) + _cash(pool), 2_000e18, "cash conserved");
  }

  ///////////////////
  //    fixing     //
  ///////////////////

  function testCompleteWindowSettlesAtItsTWAP() public {
    _sampleEvery(expiry - WINDOW, expiry - WINDOW / 2 - 1, 1.1e18); // samples at 0, 5, 10 minutes
    _sampleEvery(expiry - WINDOW / 2, expiry, 1.2e18); // 15 .. 30: no gap over 5 minutes
    future.fixSettlementFromIndex(subId);
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    assertTrue(c.settled);
    assertGt(c.markPrice, 1.1e18);
    assertLt(c.markPrice, 1.2e18);
  }

  /// @dev A8.7: a gap -> fixSettlementFromIndex reverts -> a recovery window opens -> the series settles from it.
  function testGapBreaksTheFixingAndARecoveryWindowSettlesIt() public {
    _open();
    _breakOriginalWindow(1.1e18);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);

    (uint start, uint end) = _openRecovery();
    assertEq(start, block.timestamp + RECOVERY_DELAY);
    assertEq(end, start + WINDOW);
    assertEq(future.fixings(subId).round, 1);

    vm.warp(start - 1);
    vm.expectRevert(IFutureAssetV3.FA_OutsideFixingWindow.selector);
    future.recordFixingSample(subId);

    _sampleEvery(start, end, 1.15e18);
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.15e18);

    manager.closeOutExpired(aliceAcc, subId);
    manager.closeOutExpired(bobAcc, subId);
    assertEq(_cash(aliceAcc), 1_050e18, "long paid 0.05 x 1,000 at the recovery price");
    assertEq(_cash(bobAcc), 950e18);
    assertEq(_cash(pool), 0);
  }

  /// @dev A8.7: the recovery window also breaks -> the next opens and settles.
  function testABrokenRecoveryWindowIsFollowedByAnother() public {
    _breakOriginalWindow(1.1e18);
    (uint start, uint end) = _openRecovery();
    index.set(1.1e18);
    vm.warp(start);
    future.recordFixingSample(subId); // then nothing until the end: broken
    vm.warp(end);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);

    (start, end) = _openRecovery();
    assertEq(future.fixings(subId).round, 2);
    _sampleEvery(start, end, 1.12e18);
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.12e18);
  }

  /// @dev A8.7: the broken window's samples do not reach the recovery price.
  function testBrokenWindowSamplesAreDiscarded() public {
    _breakOriginalWindow(0.5e18); // wildly off, and discarded
    (uint start, uint end) = _openRecovery();
    _sampleEvery(start, end, 1.1e18);
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.1e18, "exactly the recovery window's index");
  }

  function testAWindowNeverSampledRecovers() public {
    vm.warp(expiry);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
    (uint start, uint end) = _openRecovery();
    assertEq(future.fixings(subId).round, 1);
    _sampleEvery(start, end, 1.1e18);
    future.fixSettlementFromIndex(subId);
    assertTrue(future.futureContracts(subId).settled);
  }

  /// @dev A stale index is a gap, never a price: samples revert, and recovery handles the rest.
  function testAStaleIndexBreaksTheWindowAndRecoveryHandlesIt() public {
    uint start = expiry - WINDOW;
    vm.warp(start);
    future.recordFixingSample(subId);
    index.setStale(true);
    vm.warp(start + GAP);
    vm.expectRevert(StaleableSpotFeed.StaleIndex.selector);
    future.recordFixingSample(subId);
    vm.warp(expiry);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);

    uint end;
    (start, end) = _openRecovery();
    _sampleEvery(start, end, 1.1e18); // sets the index, which also clears the stale flag
    future.fixSettlementFromIndex(subId);
    assertTrue(future.futureContracts(subId).settled);
  }

  function testCannotOpenRecoveryWhileAFixingIsAvailable() public {
    _sampleEvery(expiry - WINDOW, expiry, 1.1e18);
    vm.expectRevert(IFutureAssetV3.FA_FixingAvailable.selector);
    future.openRecoveryWindow(subId);
  }

  function testCannotOpenRecoveryBeforeTheCurrentWindowIsOver() public {
    vm.warp(expiry - 1);
    vm.expectRevert(IFutureAssetV3.FA_NotExpired.selector);
    future.openRecoveryWindow(subId);

    _breakOriginalWindow(1.1e18);
    (, uint end) = _openRecovery();
    vm.warp(end - 1);
    vm.expectRevert(IFutureAssetV3.FA_WindowNotOver.selector);
    future.openRecoveryWindow(subId);
  }

  function testCannotFixARecoveryWindowBeforeItEnds() public {
    _breakOriginalWindow(1.1e18);
    (uint start, uint end) = _openRecovery();
    _sampleEvery(start, end - GAP, 1.1e18);
    vm.expectRevert(IFutureAssetV3.FA_WindowNotOver.selector);
    future.fixSettlementFromIndex(subId);
  }

  function testNothingAfterSettlement() public {
    _sampleEvery(expiry - WINDOW, expiry, 1.1e18);
    future.fixSettlementFromIndex(subId);
    vm.expectRevert(IFutureAssetV3.FA_AlreadySettled.selector);
    future.fixSettlementFromIndex(subId);
    vm.expectRevert(IFutureAssetV3.FA_AlreadySettled.selector);
    future.openRecoveryWindow(subId);
    vm.expectRevert(IFutureAssetV3.FA_AlreadySettled.selector);
    future.recordFixingSample(subId);
    vm.warp(block.timestamp + 1 hours);
    vm.expectRevert(IFutureAssetV3.FA_AlreadySettled.selector);
    future.pullMark(subId);
  }

  /// @dev A series keeps the fixing parameters it was listed with: a window under way keeps its gap limit.
  function testParamsCannotMoveAWindowUnderWay() public {
    uint start = expiry - WINDOW;
    _sampleEvery(start, start + 2 * GAP, 1.1e18);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 4 * WINDOW, WINDOW, RECOVERY_DELAY); // a gap of 30 minutes
    vm.warp(expiry);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
  }

  /// @dev Review finding 1: the owner shrank the fixing to one sample (window = gap = 60s) just before it opened, and
  ///      a single sample at expiry settled the series. The setting is now refused, and a setting that is allowed
  ///      reaches only series listed after it.
  function testTheOwnerCannotShrinkAListedSeriesFixingToOneSample() public {
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 60, 60, RECOVERY_DELAY);

    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 15 minutes, 225, RECOVERY_DELAY); // the shortest allowed
    index.set(1.1e18);
    vm.warp(expiry - WINDOW);
    future.recordFixingSample(subId);
    index.set(1.13e18);
    vm.warp(expiry); // one sample at the end of the shortest window allowed now
    future.recordFixingSample(subId);
    vm.expectRevert(IFutureAssetV3.FA_FixingIncomplete.selector);
    future.fixSettlementFromIndex(subId);
    IFutureAssetV3.Fixing memory f = future.fixings(subId);
    assertEq(f.windowEnd - f.windowStart, WINDOW, "still the 30-minute window it was listed with");
    assertEq(f.maxSampleGap, GAP);
  }

  /// @dev Review finding 3: widening the window to a day and the delay to a week, just before round 0, made it fail
  ///      and each retry a week away. A listed series is untouched, and the delay is now bounded at 6 hours.
  function testTheOwnerCannotStretchAListedSeriesRecovery() public {
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 1 days, GAP, 7 days);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 1 days, GAP, 6 hours);
    _breakOriginalWindow(1.1e18);
    (uint start, uint end) = _openRecovery();
    assertEq(start, block.timestamp + RECOVERY_DELAY, "the delay it was listed with");
    assertEq(end - start, WINDOW, "the window it was listed with");

    uint64 later = uint64(expiry + 60 days);
    uint96 next = future.setContract(later, later - 1 hours, PRICE);
    IFutureAssetV3.FixingParams memory p = future.seriesFixing(next);
    assertEq(p.fixingWindow, 1 days, "a series listed after the change takes it");
    assertEq(p.recoveryDelay, 6 hours);
    assertEq(future.seriesFixing(subId).fixingWindow, WINDOW);
  }

  function testASeriesCannotBeListedBeforeTheFixingParamsAreSet() public {
    FutureAsset fresh = new FutureAsset(subAccounts, CONTRACT_SIZE, index, TIMELOCK);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    fresh.setContract(uint64(expiry), uint64(expiry - 1 hours), PRICE);
  }

  ////////////////////////////////////
  //  no owner lever on settlement  //
  ////////////////////////////////////

  /// @dev Bounds stop a setting from preventing settlement: no endless delay, no window too long, no gap too small.
  function testFixingParamsAreBounded() public {
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, WINDOW, GAP, 6 hours + 1);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 1 days + 1, GAP, RECOVERY_DELAY);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 15 minutes - 1, 1 minutes, RECOVERY_DELAY);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, WINDOW, 1 minutes - 1, RECOVERY_DELAY);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, WINDOW, WINDOW / 4 + 1, RECOVERY_DELAY);
    vm.expectRevert(IFutureAssetV3.FA_InvalidIndexParams.selector);
    future.setIndexParams(0.1e18, 0.11e18, NARROWING, WINDOW, GAP, RECOVERY_DELAY);
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 1 days, 1 minutes, 6 hours); // the bounds themselves
    future.setIndexParams(0.1e18, 0.01e18, NARROWING, 15 minutes, 225, 0);
  }

  function testIndexFeedChangeWaitsForTheTimelock() public {
    StaleableSpotFeed other = new StaleableSpotFeed();
    vm.prank(alice);
    vm.expectRevert();
    future.proposeIndexFeed(other);

    vm.expectRevert(IFutureAssetV3.FA_NoPendingFeed.selector);
    future.activateIndexFeed();

    future.proposeIndexFeed(other);
    assertEq(future.pendingIndexFeedEffectiveAt(), block.timestamp + TIMELOCK);
    vm.warp(block.timestamp + TIMELOCK - 1);
    vm.expectRevert(IFutureAssetV3.FA_TimelockNotElapsed.selector);
    future.activateIndexFeed();

    vm.warp(block.timestamp + 1);
    vm.prank(alice); // anyone activates once the timelock has passed
    future.activateIndexFeed();
    assertEq(address(future.indexFeed()), address(other));
    assertEq(future.feedHistory().length, 2);
  }

  function testAPendingFeedCanBeCancelled() public {
    future.proposeIndexFeed(new StaleableSpotFeed());
    future.cancelIndexFeed();
    vm.warp(block.timestamp + TIMELOCK);
    vm.expectRevert(IFutureAssetV3.FA_NoPendingFeed.selector);
    future.activateIndexFeed();
    vm.expectRevert(IFutureAssetV3.FA_NoPendingFeed.selector);
    future.cancelIndexFeed();
  }

  /// @dev A series that trades until a second before expiry: its fixing window opens while trading is still on, so a
  ///      feed change inside the window is not barred by last trade. The setUp series is moved out of the way.
  function _listLateLastTradeSeries() internal {
    uint64 early = uint64(block.timestamp + 10 days);
    subId = future.setContract(early, early - 1, PRICE);
    expiry = early;
  }

  /// @dev A8.7: a feed activated while a window is open never reaches that window's samples.
  function testAFeedChangeDuringAnOpenWindowDoesNotReachIt() public {
    _listLateLastTradeSeries();
    StaleableSpotFeed rogue = new StaleableSpotFeed();
    rogue.set(5e18);
    vm.warp(expiry - WINDOW - TIMELOCK + GAP + 1); // the timelock ends inside the window
    future.proposeIndexFeed(rogue);

    uint start = expiry - WINDOW;
    _sampleEvery(start, start + GAP, 1.1e18);
    vm.warp(start + GAP + 1); // past the proposal's effective time, mid-window
    future.activateIndexFeed();
    assertEq(address(future.indexFeed()), address(rogue), "marks and fills now read the new feed");

    for (uint t = start + 2 * GAP; t <= expiry; t += GAP) {
      vm.warp(t);
      future.recordFixingSample(subId);
    }
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.1e18, "settled from the feed in effect at the window's start");
  }

  /// @dev Activated after the window started but before its first sample: still not the window's feed.
  function testAFeedActivatedAfterTheWindowStartsButBeforeItsFirstSampleDoesNotReachIt() public {
    _listLateLastTradeSeries();
    StaleableSpotFeed rogue = new StaleableSpotFeed();
    rogue.set(5e18);
    uint start = expiry - WINDOW;
    vm.warp(start - TIMELOCK + 1);
    future.proposeIndexFeed(rogue);
    vm.warp(start + 1);
    future.activateIndexFeed();
    _sampleEvery(start + 2, expiry, 1.1e18);
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.1e18);
  }

  /// @dev A replacement for a dead feed is what the next window samples: how a discontinued stream is handled. After
  ///      last trade that is the only feed change allowed: the current one failing, and silent for a full window.
  function testAFeedActivatedBeforeARecoveryWindowIsTheOneItSamples() public {
    _breakOriginalWindow(1.1e18);
    index.setStale(true); // the stream is discontinued at expiry
    StaleableSpotFeed replacement = new StaleableSpotFeed();
    replacement.set(1.13e18);
    future.proposeIndexFeed(replacement);
    vm.warp(block.timestamp + TIMELOCK);
    future.activateIndexFeed();

    (uint start, uint end) = _openRecovery();
    for (uint t = start; t <= end; t += GAP) {
      vm.warp(t);
      future.recordFixingSample(subId);
    }
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.13e18);
    assertEq(future.fixings(subId).feed, address(replacement));
  }

  /// @dev Review finding 2: a proposal made while holders could exit, held in reserve, and activated after last trade
  ///      against a live feed, settled the series at 1.50 against an honest 1.10. Refused while the feed is alive.
  function testAFeedProposalCannotBeActivatedAfterLastTradeWhileTheFeedIsAlive() public {
    StaleableSpotFeed rogue = new StaleableSpotFeed();
    rogue.set(1.5e18);
    vm.warp(expiry - 1 hours - TIMELOCK); // effective exactly at last trade
    future.proposeIndexFeed(rogue);
    vm.warp(expiry - 1 hours);
    vm.expectRevert(IFutureAssetV3.FA_FeedChangeAfterLastTrade.selector);
    future.activateIndexFeed();

    _breakOriginalWindow(1.1e18); // a broken window: the feed is alive, but it was not sampled
    vm.expectRevert(IFutureAssetV3.FA_FeedChangeAfterLastTrade.selector);
    future.activateIndexFeed();
    (uint start, uint end) = _openRecovery();
    _sampleEvery(start, end, 1.1e18);
    future.fixSettlementFromIndex(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.1e18, "the honest index");
  }

  /// @dev After last trade, a failing feed is not enough: it must have given no price for a full fixing window. Each
  ///      price read (a mark, a fill, a sample) restarts that, so anyone posting reports keeps the feed and blocks it.
  function testAfterLastTradeTheFeedMustBeDeadForAFullWindow() public {
    StaleableSpotFeed replacement = new StaleableSpotFeed();
    replacement.set(1.1e18);
    vm.warp(expiry - TIMELOCK);
    future.proposeIndexFeed(replacement);
    vm.warp(expiry);
    future.pullMark(subId); // the current feed answers at expiry
    index.setStale(true);
    vm.warp(expiry + WINDOW - 1);
    vm.expectRevert(IFutureAssetV3.FA_FeedChangeAfterLastTrade.selector);
    future.activateIndexFeed();

    index.set(1.1e18); // someone posts a report: alive again
    vm.warp(expiry + WINDOW);
    vm.expectRevert(IFutureAssetV3.FA_FeedChangeAfterLastTrade.selector);
    future.activateIndexFeed();

    index.setStale(true);
    future.activateIndexFeed(); // failing now, and nothing read it for a full window since expiry
    assertEq(address(future.indexFeed()), address(replacement));
  }

  /// @dev Before last trade a change needs only the timelock, as before: holders can still exit.
  function testBeforeLastTradeAFeedChangeNeedsOnlyTheTimelock() public {
    future.proposeIndexFeed(new StaleableSpotFeed());
    vm.warp(block.timestamp + TIMELOCK);
    future.activateIndexFeed();
  }

  /// @dev A proposal not activated within FEED_ACTIVATION_PERIOD of its timelock ending lapses: none held in reserve.
  function testAFeedProposalLapses() public {
    future.proposeIndexFeed(new StaleableSpotFeed());
    uint effective = block.timestamp + TIMELOCK;
    vm.warp(effective + 2 days + 1);
    vm.expectRevert(IFutureAssetV3.FA_FeedProposalLapsed.selector);
    future.activateIndexFeed();
    vm.warp(effective + 2 days);
    future.activateIndexFeed(); // the last second it may
  }

  /// @dev A settled series no longer bars a change.
  function testASettledSeriesDoesNotBarAFeedChange() public {
    _sampleEvery(expiry - WINDOW, expiry, 1.1e18);
    future.fixSettlementFromIndex(subId);
    future.proposeIndexFeed(new StaleableSpotFeed());
    vm.warp(block.timestamp + TIMELOCK);
    future.activateIndexFeed();
  }

  /// @dev A8.7 ABI check: the full function list, so a new function (an owner price setter, a feed setter outside
  ///      the timelock) cannot be added without this test being changed in the same review.
  function testTheABIHasNoOwnerPriceAndNoFeedSetterOutsideTheTimelock() public view {
    string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/FutureAsset.sol/FutureAsset.json"));
    string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
    string[61] memory allowed = [
      "acceptOwnership()",
      "accountCashToSettle(uint256,uint256)",
      "accountLastCumulativeVM(uint256,uint256)",
      "activateIndexFeed()",
      "bandNarrowingPeriod()",
      "cancelIndexFeed()",
      "contractSize()",
      "feedHistory()",
      "FEED_ACTIVATION_PERIOD()",
      "feedTimelock()",
      "fixings(uint256)",
      "fixingWindow()",
      "fixSettlementFromIndex(uint96)",
      "forwardFeed()",
      "futureContracts(uint256)",
      "getPendingVM(uint256,uint256)",
      "getReferencePrice(uint256)",
      "getSubId(uint64)",
      "handleAdjustment((uint256,address,uint256,int256,bytes32),uint256,int256,address,address)",
      "indexFeed()",
      "indexFeedAt(uint64)",
      "lastIndexReadAt()",
      "markIndexBand(uint64)",
      "MAX_FIXING_WINDOW()",
      "MAX_RECOVERY_DELAY()",
      "maxMarkDelay()",
      "maxMarkDeviation()",
      "maxMarkIndexDeviation()",
      "maxSampleGap()",
      "MIN_FIXING_WINDOW()",
      "MIN_GAPS_PER_WINDOW()",
      "MIN_SAMPLE_GAP()",
      "minMarkIndexDeviation()",
      "minMarkInterval()",
      "openRecoveryWindow(uint96)",
      "owner()",
      "parseSubId(uint96)",
      "pendingIndexFeed()",
      "pendingIndexFeedEffectiveAt()",
      "pendingOwner()",
      "proposeIndexFeed(address)",
      "pullMark(uint96)",
      "recordFixingSample(uint96)",
      "recoveryDelay()",
      "renounceOwnership()",
      "seriesFixing(uint256)",
      "setContract(uint64,uint64,uint256)",
      "setForwardFeed(address,uint256)",
      "setIndexParams(uint256,uint256,uint256,uint256,uint256,uint256)",
      "setMark(uint96,uint64,uint256)",
      "setMarkBounds(uint256,uint256)",
      "settleAccountVM(uint256,uint256)",
      "setTotalPositionCap(address,uint256)",
      "setWhitelistManager(address,bool)",
      "subAccounts()",
      "totalPosition(address)",
      "totalPositionBeforeTrade(address,uint256)",
      "totalPositionCap(address)",
      "transferOwnership(address)",
      "whitelistedManager(address)",
      "" // padding so the array literal's length is the declared one; never matches a signature
    ];
    assertEq(sigs.length, allowed.length - 1, "the function list changed: review it, then update this list");
    for (uint i; i < sigs.length; ++i) {
      bool found;
      for (uint j; j < allowed.length - 1; ++j) {
        if (keccak256(bytes(sigs[i])) == keccak256(bytes(allowed[j]))) found = true;
      }
      assertTrue(found, string.concat("unexpected function: ", sigs[i]));
      assertFalse(_contains(sigs[i], "SettlementPrice"), sigs[i]);
    }
  }

  function _contains(string memory s, string memory part) internal pure returns (bool) {
    bytes memory a = bytes(s);
    bytes memory b = bytes(part);
    if (b.length > a.length) return false;
    for (uint i; i <= a.length - b.length; ++i) {
      bool m = true;
      for (uint j; j < b.length && m; ++j) {
        if (a[i + j] != b[j]) m = false;
      }
      if (m) return true;
    }
    return false;
  }

  ///////////////////
  //     marks     //
  ///////////////////

  /// @dev Review finding 7: the forward publisher stops at last trade and its forward ages out before expiry, leaving
  ///      no permissionless mark. From last trade on the mark is the index.
  function testMarksRunFromTheIndexFromLastTrade() public {
    forwardFeed.setForwardPrice(expiry, 1.104e18, 1e18);
    vm.warp(expiry - 1 hours - 1);
    future.pullMark(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.104e18, "the forward until last trade");

    forwardFeed.setForwardPrice(expiry, 1.3e18, 1e18); // stale or wrong: ignored from last trade
    index.set(1.105e18);
    vm.warp(expiry - 1 hours);
    future.pullMark(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.105e18);
  }

  /// @dev Review finding 4: owner marks were not rate-limited, and each reset pullMark's cooldown. They now obey
  ///      minMarkInterval as pullMark does: one 2% owner step per interval, and permissionless marks resume after it.
  function testTheOwnersMarkObeysTheMarkInterval() public {
    future.setMarkBounds(0.02e18, 0);
    future.setForwardFeed(forwardFeed, 1 hours);
    vm.warp(block.timestamp + 1 days);
    future.setMark(subId, uint64(block.timestamp), 1.12e18);
    vm.warp(block.timestamp + 1);
    vm.expectRevert(IFutureAssetV3.FA_MarkTooSoon.selector);
    future.setMark(subId, uint64(block.timestamp), 1.14e18); // the reviewer's second step, one block later
    vm.warp(block.timestamp + 1 hours - 1);
    future.pullMark(subId); // not held off past the interval
    assertEq(future.futureContracts(subId).markPrice, 1.1e18, "back to the forward");
  }

  /// @dev From expiry on the mark is the index, whatever the forward feed says, until the series settles.
  function testMarksRunAfterExpiryFromTheIndex() public {
    forwardFeed.setForwardPrice(expiry, 1.3e18, 1e18); // ignored after expiry
    vm.warp(expiry + 10 minutes);
    index.set(1.105e18);
    future.pullMark(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.105e18);
  }

  function testAStaleIndexStopsMarksEvenWithNoBand() public {
    future.setIndexParams(0, 0, 0, WINDOW, GAP, RECOVERY_DELAY);
    index.setStale(true);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(StaleableSpotFeed.StaleIndex.selector);
    future.pullMark(subId);
    vm.expectRevert(StaleableSpotFeed.StaleIndex.selector);
    future.setMark(subId, uint64(block.timestamp), PRICE);
  }

  /// @dev A8.7: a 10% step during a recovery: marks follow it, VM is paid, and cash is conserved through close-out.
  function testADepegStepDuringARecoveryIsMarkedAndPaid() public {
    future.setMarkBounds(0.02e18, 0);
    _open();
    _breakOriginalWindow(1.1e18);
    (uint start, uint end) = _openRecovery();

    index.set(0.99e18); // EURC -10% against USDC, after expiry: the band is at its narrowest, 1%
    uint steps;
    while (future.futureContracts(subId).markPrice > 0.99e18) {
      vm.warp(block.timestamp + 1 minutes);
      future.pullMark(subId); // permissionless: clamped to one 2% step, each closer to the index
      ++steps;
    }
    assertEq(steps, 6, "2% steps from 1.10 reach 0.99 in six marks");
    assertEq(future.getPendingVM(aliceAcc, subId), -110e18, "the long owes 0.11 x 1,000 before settlement");
    assertLt(manager.getMargin(aliceAcc, false), manager.getMargin(bobAcc, false), "margin follows the mark");

    _sampleEvery(start, end, 0.99e18);
    future.fixSettlementFromIndex(subId);
    manager.closeOutExpired(aliceAcc, subId);
    manager.closeOutExpired(bobAcc, subId);
    assertEq(_cash(aliceAcc), 890e18);
    assertEq(_cash(bobAcc), 1_110e18);
    assertEq(_cash(pool), 0, "the pool fronted nothing left over");
  }

  /// @dev A feed mark beyond the deviation bound is clamped to one step, not refused, so marks converge on their own.
  function testAFeedMarkIsClampedToOneStep() public {
    future.setMarkBounds(0.02e18, 0);
    vm.warp(expiry + 1 minutes);
    index.set(0.99e18);
    future.pullMark(subId);
    assertEq(future.futureContracts(subId).markPrice, 1.078e18, "1.10 less 2%");
  }

  /// @dev The owner's mark is not clamped: beyond the bound it is refused.
  function testTheOwnersMarkIsHeldToTheDeviationBound() public {
    future.setMarkBounds(0.02e18, 0);
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert(IFutureAssetV3.FA_MarkDeviationExceeded.selector);
    future.setMark(subId, uint64(block.timestamp), 1.07e18);
  }

  /// @dev Guard fires: inside the band any mark is allowed; outside it, a mark that is not closer to the index is not.
  function testAMarkOutsideTheBandMustMoveTowardsTheIndex() public {
    future.setMarkBounds(0.05e18, 0);
    vm.warp(expiry + 1 minutes); // band 1%
    index.set(1.0e18); // the mark, 1.10, is 10% away
    vm.expectRevert(IFutureAssetV3.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1.12e18); // further away
    vm.expectRevert(IFutureAssetV3.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1.1e18 + 1); // not closer
    future.setMark(subId, uint64(block.timestamp), 1.06e18); // closer, still outside the band
    assertEq(future.futureContracts(subId).markPrice, 1.06e18);
  }

  /// @dev Guard fires: a mark from inside the band may not leave it.
  function testAMarkInsideTheBandCannotLeaveIt() public {
    vm.warp(block.timestamp + 1 days); // band 10%, index 1.10
    vm.expectRevert(IFutureAssetV3.FA_MarkOutsideIndexBand.selector);
    future.setMark(subId, uint64(block.timestamp), 1.22e18);
    future.setMark(subId, uint64(block.timestamp), 1.21e18); // exactly 10% over
  }

  /// @dev Guard fires: fills are held to the band, with no towards-the-index allowance.
  function testAFillOutsideTheBandReverts() public {
    _fund(aliceAcc, 1_000e18);
    _fund(bobAcc, 1_000e18);
    vm.expectRevert(IFutureAssetV3.FA_FillOutsideIndexBand.selector);
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: subId, amount: 1e18, assetData: bytes32(uint(1.22e18))
      }),
      ""
    );
  }
}
