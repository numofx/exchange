// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "../../src/SubAccounts.sol";
import "../../src/SecurityModule.sol";
import "../../src/assets/CashAsset.sol";
import "../../src/assets/PerpAsset.sol";
import "../../src/assets/InterestRateModel.sol";
import "../../src/liquidation/DutchAuction.sol";
import "../../src/risk-managers/StandardManager.sol";
import "../../src/risk-managers/SRMPortfolioViewer.sol";
import "../../src/feeds/LyraSpotFeed.sol";
import "../../src/feeds/LyraSpotDiffFeed.sol";
import "../../src/feeds/static/LyraStaticSpotFeed.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IBaseLyraFeed} from "../../src/interfaces/IBaseLyraFeed.sol";
import {IDataReceiver} from "../../src/interfaces/IDataReceiver.sol";

import {Config} from "../../scripts/config-mainnet.sol";

/**
 * Phase 0 of the USDC-settled cNGN perp: does the insolvency path work on a NEW stack?
 *
 * Deploys, onto a Base fork, the stack the perp would run on: a CashAsset backed by real Base
 * USDC with borrowing enabled, its own SRM, viewer, SecurityModule and DutchAuction, and a
 * PerpAsset priced in USD per NGN. It reuses the live SubAccounts, because Matching is bound to
 * it, and touches nothing else on chain: the legacy SRM and its unbacked CashAsset are never
 * called. Parameters come from config-mainnet.sol (NGN perp margin, auction, rate model).
 *
 * What must hold before this stack is worth deploying:
 *   1. a winner is paid in real USDC, not in cash that cannot be redeemed;
 *   2. a loss beyond the deposit lands as negative cash, and margin still binds;
 *   3. an insolvent account is closed by the auction and the SecurityModule pays the bidder;
 *   4. when the SecurityModule cannot cover it, the loss is socialized through the cash
 *      exchange rate and withdrawals still pay out, rather than the auction reverting.
 *
 * Requires BASE_RPC_URL, like every other fork test here.
 */
contract CngnPerpStackFork is Test {
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  /// USD per NGN, the perp's denomination: ~1,389 NGN per USD.
  uint96 constant INDEX_PRICE = 0.00072e18;

  // Derived, not a memorable constant: well-known keys like 0xC0FFEE carry EIP-7702 delegations
  // on Base, so SignatureChecker takes the ERC-1271 path for them and every signature fails.
  uint keeperPk = uint(keccak256("cngn-perp-stack-fork-keeper"));
  address keeper = vm.addr(keeperPk);

  address alice = address(0xa11ce);
  address bob = address(0xb0b);
  address charlie = address(0xc4a);

  SubAccounts subAccounts = SubAccounts(SUB_ACCOUNTS);
  CashAsset cash;
  InterestRateModel rateModel;
  SRMPortfolioViewer viewer;
  StandardManager srm;
  SecurityModule securityModule;
  DutchAuction auction;
  PerpAsset perp;
  LyraSpotFeed indexFeed;
  LyraSpotDiffFeed markFeed;
  LyraSpotDiffFeed impactAskFeed;
  LyraSpotDiffFeed impactBidFeed;
  LyraStaticSpotFeed stableFeed;

  uint aliceAcc;
  uint bobAcc;
  uint charlieAcc;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    _deployStack();
    _deployPerp();

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), srm);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), srm);
    charlieAcc = subAccounts.createAccountWithApproval(charlie, address(this), srm);
  }

  // --- the four properties ---------------------------------------------------------

  /// 1. A winner withdraws real USDC; the cash they were credited is backed.
  function testWinnerIsPaidInRealUsdc() public {
    _deposit(alice, aliceAcc, 3_000e6);
    _deposit(bob, bobAcc, 3_000e6);

    // Bob longs 10M NGN ($7,200 notional); alice takes the short.
    _tradePerp(aliceAcc, bobAcc, 10_000_000e18);

    // NGN strengthens 10%: bob is up $720.
    _setPrices(0.000792e18);
    _realize(bobAcc);
    _realize(aliceAcc);

    int bobCash = _cash(bobAcc);
    assertApproxEqAbs(bobCash, 3_720e18, 1e18, "bob's cash should carry the $720 gain");

    // Bob closes, then takes the whole balance, gain included, out as USDC.
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    uint before = IERC20Metadata(USDC).balanceOf(bob);
    vm.prank(bob);
    cash.withdraw(bobAcc, 3_719e6, bob);
    assertEq(IERC20Metadata(USDC).balanceOf(bob) - before, 3_719e6, "winner must receive real USDC");
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "cash must stay fully backed");
  }

  /// 2. A loss beyond the deposit lands as negative cash, and margin still binds.
  function testLossBeyondDepositSettlesNegativeAndMarginBinds() public {
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18); // alice long $7,200

    _setPrices(0.000432e18); // NGN -40%: alice loses $2,880 on $2,500
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), 0, "the loss must land as negative cash");

    // And nothing lets her take USDC out while under margin.
    vm.prank(alice);
    vm.expectRevert();
    cash.withdraw(aliceAcc, 1e6, alice);
  }

  /// The borrowing flag is not what makes 2 work: the SRM checks it only in `_assessRisk`, on
  /// risk-adding actions, so settlement records the same negative cash with it off. Pinned so
  /// nobody enables borrowing believing the insolvency path depends on it. (The auction tests
  /// below also pass with it off; what the legacy stack lacks is backed cash, not borrowing.)
  function testSettlementDoesNotDependOnBorrowing() public {
    srm.setBorrowingEnabled(false);
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);

    _setPrices(0.000432e18);
    _realize(aliceAcc);
    assertLt(_cash(aliceAcc), 0, "settlement must not be gated by the borrowing flag");
  }

  /// 3. Insolvent account: auction closes it and the SecurityModule pays the bidder.
  function testInsolventAuctionIsPaidBySecurityModule() public {
    _fundSecurityModule(5_000e6);
    _openInsolvent();

    uint smAcc = securityModule.accountId();
    int smCashBefore = _cash(smAcc);

    _runInsolventAuction();

    assertEq(_perpBalance(aliceAcc), 0, "alice's perp must be closed");
    assertEq(_perpBalance(charlieAcc), 10_000_000e18, "bidder must take the position");
    assertLt(_cash(smAcc), smCashBefore, "security module must have paid out");
    console2.log("security module paid (cash, 18dp):", uint(smCashBefore - _cash(smAcc)));
    assertGe(cash.getCashToStableExchangeRate(), 1e18, "a covered loss must not socialize");
    assertFalse(cash.temporaryWithdrawFeeEnabled(), "no withdraw fee when covered");
  }

  /// 4. SecurityModule short: the loss socializes through the exchange rate, withdrawals pay.
  function testUncoveredLossSocializesAndWithdrawalsStillPay() public {
    _fundSecurityModule(10e6); // $10: nowhere near the shortfall
    _openInsolvent();

    _runInsolventAuction();

    assertEq(_perpBalance(aliceAcc), 0, "alice's perp must be closed");
    assertLt(cash.getCashToStableExchangeRate(), 1e18, "shortfall must socialize");
    console2.log("cash-to-USDC rate after socializing (18dp):", cash.getCashToStableExchangeRate());
    assertTrue(cash.temporaryWithdrawFeeEnabled(), "withdraw fee must switch on");

    // Bob, the counterparty who was owed, can still take real USDC out.
    _realize(bobAcc);
    uint before = IERC20Metadata(USDC).balanceOf(bob);
    vm.prank(bob);
    cash.withdraw(bobAcc, 1_000e6, bob);
    assertEq(IERC20Metadata(USDC).balanceOf(bob) - before, 1_000e6, "withdrawal must still pay");
  }

  // --- scenario helpers ------------------------------------------------------------

  /// Alice longs 10M NGN on $2,500, just over the 33% IM, then NGN falls 40%.
  function _openInsolvent() internal {
    _deposit(alice, aliceAcc, 2_500e6);
    _deposit(bob, bobAcc, 10_000e6);
    _deposit(charlie, charlieAcc, 10_000e6);
    _tradePerp(bobAcc, aliceAcc, 10_000_000e18);
    assertGe(srm.getMargin(aliceAcc, true), 0, "alice opens within initial margin");

    // A $2,880 loss on $2,500 of equity: underwater.
    _setPrices(0.000432e18);
    (, int mtm) = srm.getMarginAndMarkToMarket(aliceAcc, false, 0);
    assertLt(mtm, 0, "alice must be insolvent, not just under margin");
  }

  function _runInsolventAuction() internal {
    auction.startAuction(aliceAcc, 0);
    // Underwater at the start, the auction opens straight in insolvency mode; one that is not
    // would have to run out its solvent phase and be converted.
    assertTrue(auction.getAuction(aliceAcc).insolvent, "auction must open insolvent");

    IDutchAuction.AuctionParams memory params = auction.getAuctionParams();
    vm.warp(block.timestamp + params.insolventAuctionLength);
    _setPrices(0.000432e18);
    assertLt(auction.getCurrentBidPrice(aliceAcc), 0, "an insolvent bid is paid, not charged");

    vm.prank(charlie);
    auction.bid(aliceAcc, charlieAcc, 1e18, 0, 0);
  }

  // --- deployment, mirroring deploy-core.s.sol with the live SubAccounts ------------

  function _deployStack() internal {
    (uint minRate, uint rateMultiplier, uint highRateMultiplier, uint optimalUtil) =
      Config.getDefaultInterestRateModel();
    rateModel = new InterestRateModel(minRate, rateMultiplier, highRateMultiplier, optimalUtil);
    cash = new CashAsset(subAccounts, IERC20Metadata(USDC), rateModel);
    viewer = new SRMPortfolioViewer(subAccounts, cash);
    srm = new StandardManager(subAccounts, cash, IDutchAuction(address(0)), viewer);
    securityModule = new SecurityModule(subAccounts, cash, srm);
    auction = new DutchAuction(subAccounts, securityModule, cash);
    srm.setLiquidation(auction);

    stableFeed = new LyraStaticSpotFeed();
    stableFeed.setSpot(1e18, 1e18);

    viewer.setStandardManager(srm);
    auction.setSMAccount(securityModule.accountId());
    auction.setWhitelistManager(address(srm), true);
    cash.setLiquidationModule(auction);
    cash.setSmFeeRecipient(securityModule.accountId());
    cash.setSmFee(Config.CASH_SM_FEE);
    auction.setAuctionParams(Config.getDefaultAuctionParam());
    securityModule.setWhitelistModule(address(auction), true);
    cash.setWhitelistManager(address(srm), true);

    srm.setMaxAccountSize(Config.MAX_ACCOUNT_SIZE_SRM);
    srm.setBorrowingEnabled(true);
    srm.setStableFeed(stableFeed);
    srm.setDepegParameters(Config.getSRMDepegParams());
  }

  function _deployPerp() internal {
    indexFeed = new LyraSpotFeed();
    markFeed = new LyraSpotDiffFeed(indexFeed);
    impactAskFeed = new LyraSpotDiffFeed(indexFeed);
    impactBidFeed = new LyraSpotDiffFeed(indexFeed);

    indexFeed.setHeartbeat(20 minutes);
    markFeed.setHeartbeat(Config.PERP_HEARTBEAT);
    impactAskFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    impactBidFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    // The mark may sit up to 50% from the index here so a 40% crash is not clipped; the
    // production cap is a phase 1 decision.
    markFeed.setSpotDiffCap(0.5e18);
    impactAskFeed.setSpotDiffCap(0.5e18);
    impactBidFeed.setSpotDiffCap(0.5e18);
    indexFeed.addSigner(keeper, true);
    markFeed.addSigner(keeper, true);
    impactAskFeed.addSigner(keeper, true);
    impactBidFeed.addSigner(keeper, true);

    perp = new PerpAsset(subAccounts);
    perp.setSpotFeed(indexFeed);
    perp.setPerpFeed(markFeed);
    perp.setImpactFeeds(impactAskFeed, impactBidFeed);
    (int staticRate, int rateCap, uint convergence) = Config.getPerpParams();
    perp.setStaticInterestRate(staticRate);
    perp.setRateBounds(rateCap);
    perp.setConvergencePeriod(convergence);
    perp.setWhitelistManager(address(srm), true);
    perp.setTotalPositionCap(srm, 1_000_000_000e18); // 1B NGN (~$720k); low-cap is phase 1

    uint marketId = srm.createMarket("NGN");
    srm.whitelistAsset(perp, marketId, IStandardManager.AssetType.Perpetual);
    srm.setOraclesForMarket(marketId, indexFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    (IStandardManager.PerpMarginRequirements memory perpReqs,, IStandardManager.OracleContingencyParams memory oc,) =
      Config.getSRMParams("NGN");
    srm.setPerpMarginRequirements(marketId, perpReqs.mmPerpReq, perpReqs.imPerpReq);
    srm.setOracleContingencyParams(marketId, oc);

    _setPrices(INDEX_PRICE);
  }

  // --- chain interaction -----------------------------------------------------------

  function _deposit(address user, uint acc, uint usdcAmount) internal {
    deal(USDC, user, IERC20Metadata(USDC).balanceOf(user) + usdcAmount);
    vm.startPrank(user);
    IERC20Metadata(USDC).approve(address(cash), usdcAmount);
    cash.deposit(acc, usdcAmount);
    vm.stopPrank();
  }

  function _fundSecurityModule(uint usdcAmount) internal {
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(address(securityModule), usdcAmount);
    securityModule.donate(usdcAmount);
  }

  /// `fromAcc` sends `amount` of perp to `toAcc` at the mark: positive makes `toAcc` long.
  function _tradePerp(uint fromAcc, uint toAcc, int amount) internal {
    ISubAccounts.AssetTransfer[] memory transfers = new ISubAccounts.AssetTransfer[](1);
    transfers[0] = ISubAccounts.AssetTransfer({
      fromAcc: fromAcc, toAcc: toAcc, asset: perp, subId: 0, amount: amount, assetData: bytes32(0)
    });
    subAccounts.submitTransfers(transfers, "");
  }

  /// Settles an account's perp PnL and funding into cash, as any adjustment would.
  function _realize(uint acc) internal {
    srm.settlePerpsWithIndex(acc);
  }

  /// Moves index, mark and both impact prices to `price` (no premium, so funding is static).
  function _setPrices(uint96 price) internal {
    vm.warp(block.timestamp + 1);
    _sign(indexFeed, abi.encode(price, uint64(1e18)));
    _sign(markFeed, abi.encode(int96(0), uint64(1e18)));
    _sign(impactAskFeed, abi.encode(int96(0), uint64(1e18)));
    _sign(impactBidFeed, abi.encode(int96(0), uint64(1e18)));
  }

  function _sign(BaseLyraFeed feed, bytes memory data) internal {
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: data,
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    bytes32 structHash =
      keccak256(abi.encode(feed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp));
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(keeperPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = keeper;
    IDataReceiver(address(feed)).acceptData(abi.encode(feedData));
  }

  function _cash(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }

  function _perpBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, perp, 0);
  }
}
