// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {StreamsIndexAdapter, IStreamsVerifierProxy} from "../../../src/feeds/StreamsIndexAdapter.sol";
import {EurcIndexFeed} from "../../../src/feeds/EurcIndexFeed.sol";

import "../../../src/SubAccounts.sol";
import "../../../src/risk-managers/MarginEnginePortfolioViewer.sol";
import "../../../src/risk-managers/MarginEngine.sol";
import {IMarginEngine} from "../../../src/interfaces/IMarginEngine.sol";
import {IBaseManager} from "../../../src/interfaces/IBaseManager.sol";
import {IVolFeed} from "../../../src/interfaces/IVolFeed.sol";
import {FutureAsset} from "../../../src/assets/FutureAsset.sol";
import {IFutureAssetV3} from "../../../src/interfaces/IFutureAssetV3.sol";
import {ICashAsset} from "../../../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../../../src/interfaces/IDutchAuction.sol";
import {ISpotFeed} from "../../../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../../../src/interfaces/IForwardFeed.sol";
import "../../shared/mocks/MockERC20.sol";
import "../../shared/mocks/MockFeeds.sol";
import "../../shared/mocks/MockCash.sol";
import "../../risk-managers/mocks/MockDutchAuction.sol";

/**
 * @dev Stands in for the Data Streams verifier proxy. "Verifies" by returning the report data embedded in the full
 *      report, as the real one does for a valid report. It can charge a fee the way a real FeeManager does (pull the
 *      fee token with transferFrom from the caller, or require native value), reject every report (a bad
 *      signature), or return data that differs from what was embedded.
 */
contract MockStreamsVerifier is IStreamsVerifierProxy {
  enum Mode {
    Free,
    ChargesFeeToken,
    ChargesNative,
    Rejects,
    Tampers
  }

  Mode public mode;
  MockERC20 public feeTokenContract;
  uint public calls;

  error BadSignature();
  error InsufficientNative();

  constructor(MockERC20 feeToken_) {
    feeTokenContract = feeToken_;
  }

  function setMode(Mode m) external {
    mode = m;
  }

  function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory) {
    calls++;
    if (mode == Mode.Rejects) revert BadSignature();
    if (mode == Mode.ChargesFeeToken) {
      address token = abi.decode(parameterPayload, (address));
      MockERC20(token).transferFrom(msg.sender, address(this), 1e18);
    }
    if (mode == Mode.ChargesNative && msg.value < 1 gwei) revert InsufficientNative();
    (, bytes memory reportData) = abi.decode(payload, (bytes32[3], bytes));
    if (mode == Mode.Tampers) {
      StreamsIndexAdapter.ReportV3 memory r = abi.decode(reportData, (StreamsIndexAdapter.ReportV3));
      r.observationsTimestamp += 1;
      return abi.encode(r);
    }
    return reportData;
  }
}

/// Spec A2.2, A2.3, A5: StreamsIndexAdapter and EurcIndexFeed.
contract StreamsIndexAdapterTest is Test {
  bytes32 constant EURC = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 constant USDC = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;
  uint constant MAX_AGE = 60;

  MockERC20 link;
  MockStreamsVerifier verifier;
  StreamsIndexAdapter adapter;
  EurcIndexFeed feed;

  function setUp() public {
    vm.warp(1_794_702_400);
    link = new MockERC20("LINK", "LINK");
    verifier = new MockStreamsVerifier(link);
    adapter = new StreamsIndexAdapter(verifier, address(link), EURC, USDC);
    feed = new EurcIndexFeed(adapter, MAX_AGE);
  }

  function _report(bytes32 feedId, uint observedAt, int price) internal pure returns (bytes memory) {
    StreamsIndexAdapter.ReportV3 memory r = StreamsIndexAdapter.ReportV3({
      feedId: feedId,
      validFromTimestamp: uint32(observedAt),
      observationsTimestamp: uint32(observedAt),
      nativeFee: 0,
      linkFee: 0,
      expiresAt: uint32(observedAt + 30 days),
      benchmarkPrice: int192(price),
      bid: int192(price),
      ask: int192(price)
    });
    bytes32[3] memory ctx;
    return abi.encode(ctx, abi.encode(r), new bytes32[](0), new bytes32[](0), bytes32(0));
  }

  function _post(bytes32 feedId, uint observedAt, int price) internal {
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(feedId, observedAt, price);
    adapter.postReports(reports);
  }

  function _postBoth(uint observedAt, int eurc, int usdc) internal {
    bytes[] memory reports = new bytes[](2);
    reports[0] = _report(EURC, observedAt, eurc);
    reports[1] = _report(USDC, observedAt, usdc);
    adapter.acceptData(abi.encode(reports));
  }

  //////////////////////////
  //   StreamsIndexAdapter //
  //////////////////////////

  function testConstructorRejectsBadConfig() public {
    vm.expectRevert(StreamsIndexAdapter.SIA_InvalidConfig.selector);
    new StreamsIndexAdapter(IStreamsVerifierProxy(address(0)), address(link), EURC, USDC);
    vm.expectRevert(StreamsIndexAdapter.SIA_InvalidConfig.selector);
    new StreamsIndexAdapter(verifier, address(link), EURC, EURC);
    vm.expectRevert(StreamsIndexAdapter.SIA_InvalidConfig.selector);
    new StreamsIndexAdapter(verifier, address(link), bytes32(0), USDC);
  }

  function testAcceptsNewerReport() public {
    _post(EURC, block.timestamp - 1, 1.0997e18);
    (uint price, uint64 observedAt) = adapter.latest(EURC);
    assertEq(price, 1.0997e18);
    assertEq(observedAt, block.timestamp - 1);

    _post(EURC, block.timestamp, 1.1e18);
    (price, observedAt) = adapter.latest(EURC);
    assertEq(price, 1.1e18);
    assertEq(observedAt, block.timestamp);
  }

  function testSkipsOlderAndEqualReportsWithoutRevertingOrVerifying() public {
    _post(EURC, block.timestamp, 1.1e18);
    uint callsBefore = verifier.calls();

    _post(EURC, block.timestamp, 1.2e18); // equal
    _post(EURC, block.timestamp - 5, 1.3e18); // older

    (uint price, uint64 observedAt) = adapter.latest(EURC);
    assertEq(price, 1.1e18);
    assertEq(observedAt, block.timestamp);
    assertEq(verifier.calls(), callsBefore, "skipped reports are not verified");
  }

  function testStreamsAreTrackedSeparately() public {
    _post(EURC, block.timestamp, 1.1e18);
    // a USDC report older than the stored EURC one is still the newest USDC report
    _post(USDC, block.timestamp - 10, 0.9998e18);
    (uint price,) = adapter.latest(USDC);
    assertEq(price, 0.9998e18);
  }

  function testRejectsUnknownFeed() public {
    bytes32 other = 0x00030af200000000000000000000000000000000000000000000000000000000;
    vm.expectRevert(abi.encodeWithSelector(StreamsIndexAdapter.SIA_UnknownFeed.selector, other));
    _post(other, block.timestamp, 1e18);
  }

  function testRejectsNonPositivePrice() public {
    vm.expectRevert(StreamsIndexAdapter.SIA_InvalidPrice.selector);
    _post(EURC, block.timestamp, 0);
    vm.expectRevert(StreamsIndexAdapter.SIA_InvalidPrice.selector);
    _post(EURC, block.timestamp, -1);
  }

  function testUnverifiedReportReverts() public {
    verifier.setMode(MockStreamsVerifier.Mode.Rejects);
    vm.expectRevert(MockStreamsVerifier.BadSignature.selector);
    _post(EURC, block.timestamp, 1.1e18);
  }

  function testStoresOnlyWhatTheVerifierReturnsAndRejectsAMismatch() public {
    verifier.setMode(MockStreamsVerifier.Mode.Tampers);
    vm.expectRevert(StreamsIndexAdapter.SIA_FeedMismatch.selector);
    _post(EURC, block.timestamp, 1.1e18);
  }

  /// A fee manager that pulls the fee token fails: the adapter holds none and approves nothing, even when funded.
  function testFeeInTokenFailsClosed() public {
    verifier.setMode(MockStreamsVerifier.Mode.ChargesFeeToken);
    link.mint(address(adapter), 100e18);
    vm.expectRevert();
    _post(EURC, block.timestamp, 1.1e18);
    assertEq(link.balanceOf(address(adapter)), 100e18);
  }

  /// A fee manager that wants native value fails: verify is called with none, even when the adapter holds ETH.
  function testNativeFeeFailsClosed() public {
    verifier.setMode(MockStreamsVerifier.Mode.ChargesNative);
    vm.deal(address(adapter), 1 ether);
    vm.expectRevert(MockStreamsVerifier.InsufficientNative.selector);
    _post(EURC, block.timestamp, 1.1e18);
  }

  function testFeeTokenIsNamedInParameterPayload() public {
    vm.expectCall(
      address(verifier),
      0,
      abi.encodeWithSelector(
        IStreamsVerifierProxy.verify.selector, _report(EURC, block.timestamp, 1.1e18), abi.encode(address(link))
      )
    );
    _post(EURC, block.timestamp, 1.1e18);
  }

  //////////////////////////
  //     EurcIndexFeed    //
  //////////////////////////

  function testFeedConstructorRejectsBadConfig() public {
    vm.expectRevert(EurcIndexFeed.EIF_InvalidConfig.selector);
    new EurcIndexFeed(adapter, 0);
    vm.expectRevert(EurcIndexFeed.EIF_InvalidConfig.selector);
    new EurcIndexFeed(StreamsIndexAdapter(address(0)), MAX_AGE);
  }

  function testRatio() public {
    _postBoth(block.timestamp, 1.0997e18, 0.99976e18);
    (uint spot, uint confidence) = feed.getSpot();
    assertEq(spot, uint(1.0997e18) * 1e18 / 0.99976e18);
    assertEq(confidence, 1e18);
  }

  function testRatioThroughEurcDepeg() public {
    _postBoth(block.timestamp, 0.95e18, 1e18);
    (uint spot,) = feed.getSpot();
    assertEq(spot, 0.95e18);
  }

  function testRatioThroughUsdcDepeg() public {
    _postBoth(block.timestamp, 1.1e18, 0.88e18);
    (uint spot,) = feed.getSpot();
    assertEq(spot, 1.25e18);
  }

  function testRevertsWithNoReport() public {
    vm.expectRevert(EurcIndexFeed.EIF_NoReport.selector);
    feed.getSpot();
    _post(EURC, block.timestamp, 1.1e18);
    vm.expectRevert(EurcIndexFeed.EIF_NoReport.selector);
    feed.getSpot();
  }

  function testFreshAtExactlyMaxAgeStaleOneSecondLater() public {
    _postBoth(block.timestamp, 1.1e18, 1e18);
    vm.warp(block.timestamp + MAX_AGE);
    feed.getSpot();
    vm.warp(block.timestamp + 1);
    vm.expectRevert(
      abi.encodeWithSelector(EurcIndexFeed.EIF_Stale.selector, EURC, uint64(block.timestamp - MAX_AGE - 1))
    );
    feed.getSpot();
  }

  function testStaleQuoteAloneReverts() public {
    uint t0 = block.timestamp;
    _postBoth(t0, 1.1e18, 1e18);
    vm.warp(t0 + MAX_AGE + 1);
    _post(EURC, block.timestamp, 1.1e18);
    vm.expectRevert(abi.encodeWithSelector(EurcIndexFeed.EIF_Stale.selector, USDC, uint64(t0)));
    feed.getSpot();
  }

  function testReportStampedAheadOfTheBlockIsFresh() public {
    _postBoth(block.timestamp + 2, 1.1e18, 1e18);
    (uint spot,) = feed.getSpot();
    assertEq(spot, 1.1e18);
  }
}

/// @dev The order TradeModule uses (execution/src/modules/TradeModule.sol:108, :171): hand `managerData` to each
///      receiver first, then submit the transfers with the same `managerData`, which the manager processes again after
///      the asset hooks.
contract TradeModuleOrder {
  function trade(ISubAccounts subAccounts, ISubAccounts.AssetTransfer calldata t, bytes calldata managerData) external {
    if (managerData.length != 0) {
      IBaseManager.ManagerData[] memory datas = abi.decode(managerData, (IBaseManager.ManagerData[]));
      for (uint i; i < datas.length; i++) {
        StreamsIndexAdapter(datas[i].receiver).acceptData(datas[i].data);
      }
    }
    subAccounts.submitTransfer(t, managerData);
  }
}

/// Spec A2.2, A5: reports attached to a trade reach the index the v3 future checks the fill against when they are
/// handed over before the transfer, as TradeModule does. The manager's own pass runs after the asset hooks: too late
/// for the fill check, which is why OnchainBook must post reports before its transfers too.
contract StreamsIndexAdapterManagerDataTest is Test {
  bytes32 constant EURC = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 constant USDC = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;
  uint constant PRICE = 1.1e18;

  SubAccounts subAccounts;
  MarginEngine manager;
  MockCash cash;
  MockERC20 usdc;
  FutureAsset future;
  MockStreamsVerifier verifier;
  StreamsIndexAdapter adapter;
  EurcIndexFeed feed;
  TradeModuleOrder tradeModule;
  uint aliceAcc;
  uint bobAcc;
  uint96 subId;

  function setUp() public {
    vm.warp(1_794_702_400);
    tradeModule = new TradeModuleOrder();
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");
    usdc = new MockERC20("USDC", "USDC");
    usdc.setDecimals(6);
    cash = new MockCash(usdc, subAccounts);
    MarginEnginePortfolioViewer viewer = new MarginEnginePortfolioViewer(subAccounts, cash);

    MockERC20 link = new MockERC20("LINK", "LINK");
    verifier = new MockStreamsVerifier(link);
    adapter = new StreamsIndexAdapter(verifier, address(link), EURC, USDC);
    feed = new EurcIndexFeed(adapter, 60);

    future = new FutureAsset(subAccounts, 1_000e18, feed, 1 days);
    future.setIndexParams(0.1e18, 0.01e18, 7 days, 30 minutes, 2 minutes, 1 hours);

    manager =
      new MarginEngine(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(new MockDutchAuction())), viewer);
    viewer.setMarginEngine(manager);
    uint marketId = manager.createMarket("eur");
    manager.whitelistAsset(future, marketId, IMarginEngine.AssetType.Future);
    MockFeeds spotFeed = new MockFeeds();
    spotFeed.setSpot(PRICE, 1e18);
    manager.setOraclesForMarket(marketId, ISpotFeed(address(spotFeed)), IForwardFeed(address(0)), IVolFeed(address(0)));
    MockFeeds stable = new MockFeeds();
    stable.setSpot(1e18, 1e18);
    manager.setStableFeed(stable);
    manager.setFutureMarginRequirements(marketId, 0.1e18, 0.2e18);
    manager.setWhitelistedCallee(address(adapter), true);

    future.setWhitelistManager(address(manager), true);
    future.setTotalPositionCap(manager, 1e36);

    aliceAcc = subAccounts.createAccountWithApproval(address(0xaa), address(tradeModule), manager);
    bobAcc = subAccounts.createAccountWithApproval(address(0xbb), address(tradeModule), manager);
    usdc.approve(address(cash), type(uint).max);
    usdc.mint(address(this), 2_000e18);
    cash.deposit(aliceAcc, 1_000e18);
    cash.deposit(bobAcc, 1_000e18);

    uint expiry = block.timestamp + 30 days;
    subId = future.setContract(uint64(expiry), uint64(expiry - 1 hours), PRICE);
  }

  function _managerData(uint observedAt) internal view returns (bytes memory) {
    bytes[] memory reports = new bytes[](2);
    reports[0] = _report(EURC, observedAt, 1.1e18);
    reports[1] = _report(USDC, observedAt, 1e18);
    IBaseManager.ManagerData[] memory data = new IBaseManager.ManagerData[](1);
    data[0] = IBaseManager.ManagerData({receiver: address(adapter), data: abi.encode(reports)});
    return abi.encode(data);
  }

  function _report(bytes32 feedId, uint observedAt, int price) internal pure returns (bytes memory) {
    StreamsIndexAdapter.ReportV3 memory r = StreamsIndexAdapter.ReportV3({
      feedId: feedId,
      validFromTimestamp: uint32(observedAt),
      observationsTimestamp: uint32(observedAt),
      nativeFee: 0,
      linkFee: 0,
      expiresAt: uint32(observedAt + 30 days),
      benchmarkPrice: int192(price),
      bid: int192(price),
      ask: int192(price)
    });
    bytes32[3] memory ctx;
    return abi.encode(ctx, abi.encode(r), new bytes32[](0), new bytes32[](0), bytes32(0));
  }

  function _transfer() internal view returns (ISubAccounts.AssetTransfer memory) {
    return ISubAccounts.AssetTransfer({
      fromAcc: bobAcc, toAcc: aliceAcc, asset: future, subId: subId, amount: 1e18, assetData: bytes32(PRICE)
    });
  }

  function _fill(bytes memory managerData) internal {
    tradeModule.trade(subAccounts, _transfer(), managerData);
  }

  /// The trap: reports given only to the manager arrive after the asset has already read the index.
  function testReportsGivenOnlyToTheManagerArriveTooLateForTheFill() public {
    vm.prank(address(tradeModule));
    vm.expectRevert(EurcIndexFeed.EIF_NoReport.selector);
    subAccounts.submitTransfer(_transfer(), _managerData(block.timestamp));
  }

  function testFillWithoutReportsRevertsOnTheIndex() public {
    vm.expectRevert(EurcIndexFeed.EIF_NoReport.selector);
    _fill("");
  }

  function testFillCarryingReportsSucceeds() public {
    uint callsBefore = verifier.calls();
    _fill(_managerData(block.timestamp));
    assertEq(verifier.calls() - callsBefore, 2, "the manager's second pass is skipped, not verified again");
    assertEq(subAccounts.getBalance(aliceAcc, future, subId), 1e18);
    (uint price,) = adapter.latest(EURC);
    assertEq(price, 1.1e18);
  }

  /// Someone posts a newer report first; the trade carrying the older one still goes through.
  function testFillCarryingAnOlderReportThanStoredStillSucceeds() public {
    bytes[] memory newer = new bytes[](2);
    newer[0] = _report(EURC, block.timestamp, 1.1e18);
    newer[1] = _report(USDC, block.timestamp, 1e18);
    adapter.postReports(newer);

    _fill(_managerData(block.timestamp - 5));
    assertEq(subAccounts.getBalance(aliceAcc, future, subId), 1e18);
  }

  function testFillAfterIndexGoesStaleReverts() public {
    _fill(_managerData(block.timestamp));
    vm.warp(block.timestamp + 61);
    vm.expectRevert();
    _fill("");
  }

  function testAdapterMustBeWhitelistedCallee() public {
    manager.setWhitelistedCallee(address(adapter), false);
    vm.expectRevert(IBaseManager.BM_UnauthorizedCall.selector);
    _fill(_managerData(block.timestamp));
  }
}
