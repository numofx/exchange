// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {Matching} from "src/Matching.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IBaseModule} from "src/interfaces/IBaseModule.sol";
import {IMatching} from "src/interfaces/IMatching.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";
import {IWrappedERC20Asset} from "v2-core/src/interfaces/IWrappedERC20Asset.sol";
import {IForwardFeed} from "v2-core/src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "v2-core/src/interfaces/IVolFeed.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";
import {MockERC20} from "v2-core/test/shared/mocks/MockERC20.sol";
import {MockFeeds} from "v2-core/test/shared/mocks/MockFeeds.sol";

import {
  TestStandardManagerBase
} from "v2-core/test/risk-managers/unit-tests/StandardManager/TestStandardManagerBase.t.sol";
import {MatchingHelpers} from "../shared/MatchingBase.t.sol";

/**
 * @title TradeModuleWrappedQuote
 *
 * @dev Covers a TradeModule whose `quoteAsset` is a WrappedERC20Asset instead of the CashAsset, so
 *      that BOTH legs of a USDC/cNGN spot fill are wrapped-token transfers and the settlement
 *      ledger is out of the trade path entirely.
 *
 * @dev The stack mirrors Base mainnet's shape rather than its addresses: one StandardManager, two
 *      base-only markets, a WrappedERC20Asset per leg, and a CashAsset that exists but must never
 *      move. `quoteAsset` (wrapped USDC) is the asset under test; `baseWrapped` (wrapped cNGN)
 *      stands in for what the live book already trades.
 *
 * @dev Three properties are asserted, in the order they matter:
 *
 *      1. STRUCTURAL BACKING. WrappedERC20Asset.handleAdjustment reverts on a negative final
 *         balance (WrappedERC20Asset.sol:122), so a subaccount cannot pay out quote it does not
 *         hold. Under a cash quote the same overdraw is caught only by the manager's
 *         SRM_NoNegativeCash policy check, which is a setting (`setBorrowingEnabled`) rather than
 *         an invariant. This is the whole point of the change.
 *
 *      2. THE FEE PATH IS THE BLOCKER. WrappedERC20Asset returns `needAllowance = true` on the
 *         CREDIT side too (WrappedERC20Asset.sol:124-125), where CashAsset returns it only on the
 *         debit side. The TradeModule owns the trading subaccounts while it executes, but never the
 *         fee recipient, so a non-zero fee spends an allowance the fee account has to have granted
 *         in advance. Maker and taker fees are hard-coded to "0" today
 *         (services/markets/internal/matching/executor.go:23,32), which makes this latent, not
 *         absent: the first non-zero fee reverts. Both halves are asserted below.
 *
 *      3. THE TWO MODULES CANNOT BE CONFUSED. `module` is a hashed field of the EIP-712 Action
 *         struct (ActionVerifier.sol:22,126) and Matching requires every action in a batch to name
 *         the same allowlisted module (Matching.sol:64,69).
 */
contract TradeModuleWrappedQuoteTest is TestStandardManagerBase, MatchingHelpers {
  // --- the two legs of the spot book ---------------------------------------------------------

  MockERC20 internal usdcToken;
  MockERC20 internal cngnToken;

  /// @dev stands in for 0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 (WRAPPED_USDC_DELIVERABLE)
  WrappedERC20Asset internal quoteWrapped;
  /// @dev stands in for 0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493 (WRAPPED_CNGN)
  WrappedERC20Asset internal baseWrapped;

  MockFeeds internal quoteFeed;
  MockFeeds internal baseFeed;

  uint internal quoteMarketId;
  uint internal baseMarketId;

  // --- the module under test, and the one it replaces ----------------------------------------

  /// @dev quoteAsset == quoteWrapped. The proposal.
  TradeModule internal wrappedQuoteModule;
  /// @dev quoteAsset == cash. What is deployed at 0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c.
  TradeModule internal cashQuoteModule;

  // --- actors ---------------------------------------------------------------------------------

  uint internal makerPk = 0xA11CE;
  address internal maker;
  uint internal makerAcc;

  uint internal takerPk = 0xB0B;
  address internal taker;
  uint internal takerAcc;

  /// @dev the fee recipient's owner. On Base the live module's feeRecipient is subaccount 1, whose
  ///      ownerOf() and manager() are both the SRM contract, which exposes no way to grant an
  ///      allowance — see testFeeRecipientOwnedByContract_CannotEverGrantAllowance.
  address internal feeOwner = address(0xFEE);
  uint internal feeAcc;

  uint internal constant EXPIRY = type(uint).max;

  /// @dev 1 cNGN costs 0.0007 USDC. Chosen so quote amounts are not round multiples of the size.
  int internal constant PRICE = 0.0007e18;
  uint internal constant SIZE = 1_000_000e18;
  /// @dev PRICE.multiplyDecimal(SIZE), i.e. what TradeModule._addAssetTransfers computes.
  uint internal constant NOTIONAL = 700e18;

  uint internal constant QUOTE_SEED = 10_000e18;
  uint internal constant BASE_SEED = 50_000_000e18;
  uint internal constant CASH_SEED = 1_000e18;

  function setUp() public override {
    super.setUp();

    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    vm.label(maker, "maker");
    vm.label(taker, "taker");

    _setUpSpotMarkets();
    _setUpMatching();
    _setUpAccounts();
  }

  // =============================================================================================
  //  setup
  // =============================================================================================

  /**
   * @dev Registers both legs as base-only markets on the SRM, the way
   *      scripts/deploy-wrapped-usdc-deliverable-asset.s.sol:31-37 and
   *      scripts/register-cngn-spot-srm.s.sol register them on Base.
   *
   * @dev The margin factors deliberately differ, matching live: baseMarginParams(1) is
   *      (0.98e18, 0.98e18) for wrapped USDC and (0, 0) for wrapped cNGN. Neither can make a margin
   *      check fail here — a portfolio of two non-negative base positions has a non-negative
   *      margin whatever the factors — but keeping them faithful means _getSpotPrice is exercised
   *      for BOTH markets on every fill, which is the liveness coupling the change introduces.
   */
  function _setUpSpotMarkets() internal {
    usdcToken = new MockERC20("USDC", "USDC");
    cngnToken = new MockERC20("cNGN", "cNGN");

    quoteWrapped = new WrappedERC20Asset(subAccounts, usdcToken);
    quoteWrapped.setWhitelistManager(address(manager), true);
    quoteWrapped.setTotalPositionCap(manager, 1e36);

    baseWrapped = new WrappedERC20Asset(subAccounts, cngnToken);
    baseWrapped.setWhitelistManager(address(manager), true);
    baseWrapped.setTotalPositionCap(manager, 1e36);

    quoteFeed = new MockFeeds();
    baseFeed = new MockFeeds();
    // USD-per-base, the SRM's Base convention. USDC is the numeraire; cNGN is priced in it.
    quoteFeed.setSpot(1e18, 1e18);
    baseFeed.setSpot(uint(PRICE), 1e18);

    quoteMarketId = manager.createMarket("WRAPPED_USDC_DELIVERABLE");
    manager.whitelistAsset(quoteWrapped, quoteMarketId, IStandardManager.AssetType.Base);
    manager.setOraclesForMarket(quoteMarketId, quoteFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    manager.setBaseAssetMarginFactor(quoteMarketId, 0.98e18, 0.98e18);

    baseMarketId = manager.createMarket("CNGN");
    manager.whitelistAsset(baseWrapped, baseMarketId, IStandardManager.AssetType.Base);
    manager.setOraclesForMarket(baseMarketId, baseFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    manager.setBaseAssetMarginFactor(baseMarketId, 0, 0);

    manager.setBorrowingEnabled(false);
  }

  function _setUpMatching() internal {
    matching = new Matching(subAccounts);
    domainSeparator = matching.domainSeparator();
    matching.setTradeExecutor(tradeExecutor, true);

    // feeRecipient is resolved before the modules are constructed: TradeModule takes it in the
    // constructor, and this test needs an account whose owner CAN grant an allowance.
    feeAcc = subAccounts.createAccount(feeOwner, IManager(address(manager)));

    wrappedQuoteModule = new TradeModule(IMatching(address(matching)), IAsset(address(quoteWrapped)), feeAcc);
    cashQuoteModule = new TradeModule(IMatching(address(matching)), IAsset(address(cash)), feeAcc);

    matching.setAllowedModule(address(wrappedQuoteModule), true);
    matching.setAllowedModule(address(cashQuoteModule), true);
  }

  function _setUpAccounts() internal {
    makerAcc = _openTradingAccount(maker);
    takerAcc = _openTradingAccount(taker);

    // Both sides hold both legs, so a fill moves balances in both directions and "unchanged"
    // assertions on the cash leg are meaningful rather than vacuously 0 == 0.
    _depositWrapped(quoteWrapped, usdcToken, makerAcc, QUOTE_SEED);
    _depositWrapped(quoteWrapped, usdcToken, takerAcc, QUOTE_SEED);
    _depositWrapped(baseWrapped, cngnToken, makerAcc, BASE_SEED);
    _depositWrapped(baseWrapped, cngnToken, takerAcc, BASE_SEED);

    _fundCash(makerAcc, CASH_SEED);
    _fundCash(takerAcc, CASH_SEED);

    // MockCash reproduces CashAsset.handleAdjustment's allowance rule exactly — allowance on the
    // debit side only, i.e. CashAsset's `return (finalBalance, adjustment.amount < 0)` against
    // MockAsset's `needPositiveAllowance = false; needNegativeAllowance = true`. The fee findings
    // below are a claim about the DIFFERENCE between the two assets, so that equivalence is what
    // testFeeBearingTradeUnderCashQuoteNeedsNoAllowance pins down behaviourally.
  }

  function _openTradingAccount(address owner) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(manager)));
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  function _depositWrapped(WrappedERC20Asset asset, MockERC20 token, uint accountId, uint amount) internal {
    token.mint(address(this), amount);
    token.approve(address(asset), amount);
    asset.deposit(accountId, amount);
  }

  // =============================================================================================
  //  trade construction
  // =============================================================================================

  struct Fill {
    uint takerAccount;
    uint makerAccount;
    bool takerIsBid;
    uint amount;
    int price;
    uint takerFee;
    uint makerFee;
  }

  /// @dev Builds the [takerAction, makerAction] pair TradeModule.executeAction expects, signs both
  ///      for `module`, and submits through Matching as the trade executor.
  function _submitFill(TradeModule module, Fill memory fill) internal {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(module, fill);
    _verifyAndMatch(actions, sigs, _encodeOrderData(fill));
  }

  /// @dev Same, but with everything signed and encoded BEFORE the expected revert is armed, so
  ///      vm.expectRevert lands on verifyAndMatch and not on a helper's view call.
  function _submitFillExpectingRevert(TradeModule module, Fill memory fill, bytes memory expectedError) internal {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(module, fill);
    bytes memory orderData = _encodeOrderData(fill);

    vm.prank(tradeExecutor);
    if (expectedError.length == 0) {
      vm.expectRevert();
    } else {
      vm.expectRevert(expectedError);
    }
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _buildFillActions(TradeModule module, Fill memory fill)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory sigs)
  {
    actions = new IActionVerifier.Action[](2);
    sigs = new bytes[](2);

    (actions[0], sigs[0]) = _createActionAndSign(
      fill.takerAccount,
      0,
      address(module),
      _encodeTradeData(fill.takerAccount, fill.takerIsBid, fill.price, int(fill.amount)),
      EXPIRY,
      taker,
      taker,
      takerPk
    );

    (actions[1], sigs[1]) = _createActionAndSign(
      fill.makerAccount,
      0,
      address(module),
      _encodeTradeData(fill.makerAccount, !fill.takerIsBid, fill.price, int(fill.amount)),
      EXPIRY,
      maker,
      maker,
      makerPk
    );
  }

  function _encodeTradeData(uint recipientId, bool isBid, int limitPrice, int desiredAmount)
    internal
    view
    returns (bytes memory)
  {
    return abi.encode(
      ITradeModule.TradeData({
        asset: address(baseWrapped),
        subId: 0,
        limitPrice: limitPrice,
        desiredAmount: desiredAmount,
        // worstFee is per-unit, and _fillLimitOrder compares fee.divideDecimal(amountFilled)
        // against it. type(uint).max would mask a fee bug, so allow exactly what the fills use.
        worstFee: 1e18,
        recipientId: recipientId,
        isBid: isBid
      })
    );
  }

  function _encodeOrderData(Fill memory fill) internal pure returns (bytes memory) {
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({
      filledAccount: fill.makerAccount, amountFilled: fill.amount, price: fill.price, fee: fill.makerFee
    });

    return abi.encode(
      ITradeModule.OrderData({
        takerAccount: fill.takerAccount, takerFee: fill.takerFee, fillDetails: fills, managerData: bytes("")
      })
    );
  }

  function _defaultFill() internal view returns (Fill memory) {
    return Fill({
      takerAccount: takerAcc,
      makerAccount: makerAcc,
      takerIsBid: true,
      amount: SIZE,
      price: PRICE,
      takerFee: 0,
      makerFee: 0
    });
  }

  function _bal(IAsset asset, uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, asset, 0);
  }

  // =============================================================================================
  //  1. round trip: both legs are wrapped, the settlement ledger does not move
  // =============================================================================================

  /**
   * @dev The taker buys SIZE cNGN at PRICE. Both subaccounts' wrapped balances must change by
   *      exactly the traded amounts, and neither CashAsset balance may move at all.
   */
  function testRoundTripMovesOnlyWrappedBalances() public {
    int takerQuoteBefore = _bal(quoteWrapped, takerAcc);
    int makerQuoteBefore = _bal(quoteWrapped, makerAcc);
    int takerBaseBefore = _bal(baseWrapped, takerAcc);
    int makerBaseBefore = _bal(baseWrapped, makerAcc);
    int takerCashBefore = _bal(IAsset(address(cash)), takerAcc);
    int makerCashBefore = _bal(IAsset(address(cash)), makerAcc);

    _submitFill(wrappedQuoteModule, _defaultFill());

    // quote leg: buyer pays exactly the notional, seller receives exactly the notional
    assertEq(_bal(quoteWrapped, takerAcc), takerQuoteBefore - int(NOTIONAL), "taker quote");
    assertEq(_bal(quoteWrapped, makerAcc), makerQuoteBefore + int(NOTIONAL), "maker quote");

    // base leg: buyer receives exactly the size, seller delivers exactly the size
    assertEq(_bal(baseWrapped, takerAcc), takerBaseBefore + int(SIZE), "taker base");
    assertEq(_bal(baseWrapped, makerAcc), makerBaseBefore - int(SIZE), "maker base");

    // the settlement ledger is not in the trade path
    assertEq(_bal(IAsset(address(cash)), takerAcc), takerCashBefore, "taker cash must not move");
    assertEq(_bal(IAsset(address(cash)), makerAcc), makerCashBefore, "maker cash must not move");
    assertEq(_bal(IAsset(address(cash)), feeAcc), 0, "fee account cash must not move");

    // and nothing was created or destroyed: a transfer is conservative on both legs
    assertEq(
      _bal(quoteWrapped, takerAcc) + _bal(quoteWrapped, makerAcc),
      takerQuoteBefore + makerQuoteBefore,
      "quote leg must be conservative"
    );
    assertEq(
      _bal(baseWrapped, takerAcc) + _bal(baseWrapped, makerAcc),
      takerBaseBefore + makerBaseBefore,
      "base leg must be conservative"
    );
  }

  /// @dev The same fill in the other direction, so neither side's role is load-bearing.
  function testRoundTripSellSide() public {
    int takerQuoteBefore = _bal(quoteWrapped, takerAcc);
    int takerBaseBefore = _bal(baseWrapped, takerAcc);

    Fill memory fill = _defaultFill();
    fill.takerIsBid = false;
    _submitFill(wrappedQuoteModule, fill);

    assertEq(_bal(quoteWrapped, takerAcc), takerQuoteBefore + int(NOTIONAL), "taker receives quote");
    assertEq(_bal(baseWrapped, takerAcc), takerBaseBefore - int(SIZE), "taker delivers base");
    assertEq(_bal(IAsset(address(cash)), takerAcc), int(CASH_SEED), "taker cash must not move");
  }

  /**
   * @dev The property the change exists for. A wrapped quote asset cannot go negative
   *      (WrappedERC20Asset.sol:122), so the venue cannot hand out a USDC claim it is not holding
   *      the USDC for — regardless of manager configuration.
   */
  function testWrappedQuoteCannotBeOverdrawn() public {
    // ask for more quote than the taker holds: QUOTE_SEED is 10_000e18, this needs 14_000e18
    Fill memory fill = _defaultFill();
    fill.amount = SIZE * 20;

    _submitFillExpectingRevert(
      wrappedQuoteModule, fill, abi.encodeWithSelector(IWrappedERC20Asset.WERC_CannotBeNegative.selector)
    );
  }

  /**
   * @dev The contrast, and the reason "1:1 backed" is a stronger claim than "borrowing is off".
   *      Under a cash quote the identical overdraw is stopped by the MANAGER's policy, not by the
   *      asset: two owner-only settings on the SRM — `setBorrowingEnabled(true)` and a non-zero
   *      margin factor on the asset being bought — let the same fill through and mint a quote
   *      claim with no USDC behind it. Both are single transactions from the vault key.
   *
   * @dev No combination of settings can do this to the wrapped quote: WERC_CannotBeNegative is in
   *      the asset's own adjustment hook, below the manager, and has no setter.
   */
  function testCashQuoteOverdrawIsOnlyAPolicyCheck() public {
    Fill memory fill = _defaultFill();
    fill.amount = SIZE * 20;

    _submitFillExpectingRevert(
      cashQuoteModule, fill, abi.encodeWithSelector(IStandardManager.SRM_NoNegativeCash.selector)
    );

    // same fill, same accounts, same module — only the manager's configuration changes
    manager.setBorrowingEnabled(true);
    manager.setBaseAssetMarginFactor(baseMarketId, 1e18, 1e18);

    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(cashQuoteModule, fill);
    _verifyAndMatch(actions, sigs, _encodeOrderData(fill));

    assertLt(_bal(IAsset(address(cash)), takerAcc), 0, "cash quote went negative once borrowing was enabled");
  }

  /// @dev And the same two settings do NOT unlock the wrapped quote: the asset still refuses.
  function testWrappedQuoteOverdrawSurvivesAPermissiveManager() public {
    manager.setBorrowingEnabled(true);
    manager.setBaseAssetMarginFactor(baseMarketId, 1e18, 1e18);

    Fill memory fill = _defaultFill();
    fill.amount = SIZE * 20;

    _submitFillExpectingRevert(
      wrappedQuoteModule, fill, abi.encodeWithSelector(IWrappedERC20Asset.WERC_CannotBeNegative.selector)
    );
  }

  // =============================================================================================
  //  2. fee-bearing trades
  // =============================================================================================

  /**
   * @dev THE FINDING. A non-zero fee credits the fee recipient with the wrapped quote asset.
   *      WrappedERC20Asset returns needAllowance = true on that credit
   *      (WrappedERC20Asset.sol:124-125); SubAccounts then requires the caller — the TradeModule,
   *      which owns the two TRADING accounts but not the fee account — to spend an allowance the
   *      fee account has never granted.
   *
   * @dev Maker and taker fees are "0" today (executor.go:23,32), so this reverts on the first
   *      trade after fees are switched on and not before. That is why it is tested here and not
   *      left to production.
   */
  function testFeeBearingTradeRevertsWithoutFeeRecipientAllowance() public {
    Fill memory fill = _defaultFill();
    fill.takerFee = 1e18;
    fill.makerFee = 0.5e18;

    _submitFillExpectingRevert(
      wrappedQuoteModule,
      fill,
      abi.encodeWithSelector(
        IAllowances.NotEnoughSubIdOrAssetAllowances.selector, address(wrappedQuoteModule), feeAcc, int(0.5e18), 0, 0
      )
    );
  }

  /**
   * @dev THE FIX. The fee account's owner grants the module a standing positive allowance on the
   *      wrapped quote asset, once. Allowances are decremented on every spend
   *      (Allowances.sol:142-149), so the grant is type(uint).max rather than a budgeted figure —
   *      a finite grant is a scheduled outage.
   */
  function testFeeBearingTradeSucceedsWithFeeRecipientAllowance() public {
    _grantFeeAllowance(wrappedQuoteModule, quoteWrapped);

    Fill memory fill = _defaultFill();
    fill.takerFee = 1e18;
    fill.makerFee = 0.5e18;

    int takerQuoteBefore = _bal(quoteWrapped, takerAcc);
    int makerQuoteBefore = _bal(quoteWrapped, makerAcc);

    _submitFill(wrappedQuoteModule, fill);

    // taker pays notional + its own fee; maker receives notional less its own fee
    assertEq(_bal(quoteWrapped, takerAcc), takerQuoteBefore - int(NOTIONAL) - int(1e18), "taker quote net of fee");
    assertEq(_bal(quoteWrapped, makerAcc), makerQuoteBefore + int(NOTIONAL) - int(0.5e18), "maker quote net of fee");

    // fees land on the fee account in the wrapped asset, not in cash
    assertEq(_bal(quoteWrapped, feeAcc), int(1.5e18), "fees collected in wrapped quote");
    assertEq(_bal(IAsset(address(cash)), feeAcc), 0, "no cash fee");
  }

  /**
   * @dev The same fee under the CASH-quoted module needs no grant at all. This is the difference
   *      that makes the fee path a migration item rather than a no-op: whoever ports the module
   *      inherits an allowance to keep alive.
   */
  function testFeeBearingTradeUnderCashQuoteNeedsNoAllowance() public {
    Fill memory fill = _defaultFill();
    fill.takerFee = 1e18;
    fill.makerFee = 0.5e18;

    _submitFill(cashQuoteModule, fill);

    assertEq(_bal(IAsset(address(cash)), feeAcc), int(1.5e18), "cash fees need no allowance");
  }

  /**
   * @dev On Base the live module's feeRecipient is subaccount 1, whose ownerOf() and manager() are
   *      both the SRM contract (verified against mainnet). SubAccounts.setAssetAllowances is
   *      onlyOwnerOrManagerOrERC721Approved, and StandardManager exposes no call that would reach
   *      it — so an SRM-owned fee account can NEVER grant the allowance the fix needs. The new
   *      module must therefore be constructed with a different feeRecipient; it cannot reuse
   *      subaccount 1.
   */
  function testFeeRecipientOwnedByContract_CannotEverGrantAllowance() public {
    uint contractOwnedFeeAcc = subAccounts.createAccount(address(manager), IManager(address(manager)));

    TradeModule strandedModule =
      new TradeModule(IMatching(address(matching)), IAsset(address(quoteWrapped)), contractOwnedFeeAcc);
    matching.setAllowedModule(address(strandedModule), true);

    // nobody but the SRM itself may grant, and the SRM has no function that does
    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(address(quoteWrapped)), positive: type(uint).max, negative: 0});

    vm.prank(feeOwner);
    vm.expectRevert();
    subAccounts.setAssetAllowances(contractOwnedFeeAcc, address(strandedModule), grant);

    // and so the fee-bearing fill is unfixable on this module
    Fill memory fill = _defaultFill();
    fill.takerFee = 1e18;

    _submitFillExpectingRevert(strandedModule, fill, bytes(""));
  }

  function _grantFeeAllowance(TradeModule module, WrappedERC20Asset asset) internal {
    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(address(asset)), positive: type(uint).max, negative: 0});

    vm.prank(feeOwner);
    subAccounts.setAssetAllowances(feeAcc, address(module), grant);
  }

  // =============================================================================================
  //  3. the two modules cannot be confused
  // =============================================================================================

  /**
   * @dev An order signed for the wrapped-quote module is not executable on the cash-quote module.
   *      `module` is the third field of ACTION_TYPEHASH (ActionVerifier.sol:22) and is hashed into
   *      the digest (ActionVerifier.sol:126), so rewriting it invalidates the signature. This is
   *      what stops a matcher — or anything upstream of it — from routing a fill to the wrong
   *      settlement rail during a two-module cutover.
   */
  function testOrderSignedForWrappedQuoteCannotExecuteOnCashQuoteModule() public {
    Fill memory fill = _defaultFill();
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(wrappedQuoteModule, fill);

    // swap the module out, keep the signatures
    actions[0].module = IMatchingModule(address(cashQuoteModule));
    actions[1].module = IMatchingModule(address(cashQuoteModule));

    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    _verifyAndMatch(actions, sigs, _encodeOrderData(fill));
  }

  /// @dev And the reverse, so neither direction relies on an accident of ordering.
  function testOrderSignedForCashQuoteCannotExecuteOnWrappedQuoteModule() public {
    Fill memory fill = _defaultFill();
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(cashQuoteModule, fill);

    actions[0].module = IMatchingModule(address(wrappedQuoteModule));
    actions[1].module = IMatchingModule(address(wrappedQuoteModule));

    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    _verifyAndMatch(actions, sigs, _encodeOrderData(fill));
  }

  /**
   * @dev A cross-module PAIR — an old-module maker resting against a new-module taker — is
   *      rejected by Matching itself (Matching.sol:69), before any signature is checked. Both
   *      signatures here are individually valid for their own module.
   */
  function testCrossModulePairIsRejectedByMatching() public {
    Fill memory fill = _defaultFill();

    (IActionVerifier.Action[] memory wrappedActions, bytes[] memory wrappedSigs) =
      _buildFillActions(wrappedQuoteModule, fill);
    (IActionVerifier.Action[] memory cashActions, bytes[] memory cashSigs) = _buildFillActions(cashQuoteModule, fill);

    IActionVerifier.Action[] memory mixed = new IActionVerifier.Action[](2);
    bytes[] memory sigs = new bytes[](2);
    mixed[0] = wrappedActions[0];
    sigs[0] = wrappedSigs[0];
    mixed[1] = cashActions[1];
    sigs[1] = cashSigs[1];

    vm.expectRevert(IMatching.M_MismatchedModule.selector);
    _verifyAndMatch(mixed, sigs, _encodeOrderData(fill));
  }

  /// @dev A module that has not been allowlisted cannot be reached at all, even with valid
  ///      signatures — so the new module is inert until Matching.setAllowedModule is called on it.
  function testUnallowlistedModuleIsUnreachable() public {
    TradeModule shadow = new TradeModule(IMatching(address(matching)), IAsset(address(quoteWrapped)), feeAcc);

    Fill memory fill = _defaultFill();
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildFillActions(shadow, fill);

    vm.expectRevert(IMatching.M_OnlyAllowedModule.selector);
    _verifyAndMatch(actions, sigs, _encodeOrderData(fill));
  }

  /**
   * @dev The one confusion the CONTRACTS do not prevent: `filled`/`seenNonces` are per-module
   *      storage (TradeModule.sol:39,45), so the same owner+nonce can be spent once on each
   *      module. Two same-nonce orders that would be one fill on one module become two fills
   *      across two. Nothing on-chain deduplicates them, which is why the markets service has to
   *      pin a single module address per market rather than accept whatever an order names.
   */
  function testSameNonceIsSpendableOnceOnEachModule() public {
    _grantFeeAllowance(wrappedQuoteModule, quoteWrapped);

    Fill memory fill = _defaultFill();
    fill.amount = SIZE / 2;

    int takerBaseBefore = _bal(baseWrapped, takerAcc);

    // nonce 0 on the wrapped-quote module
    _submitFill(wrappedQuoteModule, fill);
    // the SAME nonce 0, re-signed for the cash-quote module, fills again
    _submitFill(cashQuoteModule, fill);

    assertEq(_bal(baseWrapped, takerAcc), takerBaseBefore + int(SIZE), "one nonce, two fills");
    assertEq(wrappedQuoteModule.filled(taker, 0), SIZE / 2, "wrapped module counted its own fill only");
    assertEq(cashQuoteModule.filled(taker, 0), SIZE / 2, "cash module counted its own fill only");
  }
}
