// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {Matching} from "src/Matching.sol";
import {IMatching} from "src/interfaces/IMatching.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";

import {SubAccounts} from "v2-core/src/SubAccounts.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ICashAsset} from "v2-core/src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "v2-core/src/interfaces/IDutchAuction.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";
import {ISpotFeed} from "v2-core/src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "v2-core/src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "v2-core/src/interfaces/IVolFeed.sol";
import {IWrappedERC20Asset} from "v2-core/src/interfaces/IWrappedERC20Asset.sol";

import {StandardManager} from "v2-core/src/risk-managers/StandardManager.sol";
import {SRMPortfolioViewer} from "v2-core/src/risk-managers/SRMPortfolioViewer.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";

import {MockERC20} from "v2-core/test/shared/mocks/MockERC20.sol";
import {MockCash} from "v2-core/test/shared/mocks/MockCash.sol";
import {MockFeeds} from "v2-core/test/shared/mocks/MockFeeds.sol";
import {MockDutchAuction} from "v2-core/test/risk-managers/mocks/MockDutchAuction.sol";

import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TradeWrappedQuoteTest
 *
 * @dev Verifies the "structurally 1:1 backed" spot book: a TradeModule whose `quoteAsset` is a
 *      WrappedERC20Asset (wrapped USDC) rather than the CashAsset, so BOTH legs of a spot fill are
 *      transfers of tokens actually held by the protocol and the cash settlement ledger is never
 *      touched.
 *
 *      Mirrors the Base-mainnet topology: 6-decimal USDC and cNGN, each wrapped by a
 *      WrappedERC20Asset (18dp internal accounting), traded under one StandardManager where wrapped
 *      USDC is market 1's Base asset (marginFactor 0.98, backed by the global stable feed) and
 *      wrapped cNGN is market 2's Base asset (marginFactor 0).
 */
contract TradeWrappedQuoteTest is Test {
  // --- infra ---
  SubAccounts subAccounts;
  StandardManager manager;
  SRMPortfolioViewer viewer;
  MockDutchAuction auction;

  // --- assets ---
  MockERC20 usdc; // 6dp underlying
  MockERC20 cngn; // 6dp underlying
  MockCash cash; // the settlement ledger we are trying to keep OUT of the trade path
  WrappedERC20Asset wrappedUsdc; // the new quoteAsset
  WrappedERC20Asset wrappedCngn; // the traded (base) asset

  MockFeeds usdcFeed;
  MockFeeds cngnFeed;
  MockFeeds stableFeed;

  uint usdcMarketId;
  uint cngnMarketId;

  // --- matching ---
  Matching matching;
  TradeModule wrappedQuoteTrade; // quoteAsset == wrappedUsdc  (the new module)
  TradeModule cashQuoteTrade; // quoteAsset == cash        (the module in production today)

  address tradeExecutor = address(0xaaaa);
  bytes32 domainSeparator;

  // --- actors ---
  uint camPk = 0xBEEF;
  address cam = vm.addr(0xBEEF);
  uint camAcc;

  uint dougPk = 0xEEEE;
  address doug = vm.addr(0xEEEE);
  uint dougAcc;

  /// @dev fee recipient owned by an EOA, so it can grant the module an allowance
  address feeOwner = address(0xFEE0);
  uint feeAcc;

  /// @dev fee recipient that can NOT grant an allowance (models SecurityModule-owned subaccount 1)
  uint unreachableFeeAcc;

  // 1 cNGN ~= 0.000743376685636834 USDC on mainnet; use a round number here.
  int constant PRICE = 0.00075e18;
  uint constant USDC_DEPOSIT = 10_000e18; // 18dp, as seen inside SubAccounts
  uint constant CNGN_DEPOSIT = 20_000_000e18;

  function setUp() public {
    subAccounts = new SubAccounts("Numo Margin Accounts", "NumoMarginNFTs");

    usdc = new MockERC20("USDC", "USDC");
    usdc.setDecimals(6);
    cngn = new MockERC20("cNGN", "cNGN");
    cngn.setDecimals(6);

    cash = new MockCash(usdc, subAccounts);
    auction = new MockDutchAuction();

    viewer = new SRMPortfolioViewer(subAccounts, cash);
    manager = new StandardManager(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), viewer);
    viewer.setStandardManager(manager);

    wrappedUsdc = new WrappedERC20Asset(subAccounts, usdc);
    wrappedCngn = new WrappedERC20Asset(subAccounts, cngn);
    wrappedUsdc.setWhitelistManager(address(manager), true);
    wrappedCngn.setWhitelistManager(address(manager), true);
    wrappedUsdc.setTotalPositionCap(manager, type(uint).max);
    wrappedCngn.setTotalPositionCap(manager, type(uint).max);

    usdcFeed = new MockFeeds();
    cngnFeed = new MockFeeds();
    stableFeed = new MockFeeds();
    usdcFeed.setSpot(1e18, 1e18);
    cngnFeed.setSpot(uint(PRICE), 1e18);
    stableFeed.setSpot(1e18, 1e18);

    // Mirror mainnet: wrapped USDC is market 1 (marginFactor 0.98), wrapped cNGN is market 2
    // (marginFactor 0, where the SRM check reduces to "no negative balances").
    usdcMarketId = manager.createMarket("WRAPPED_USDC");
    manager.whitelistAsset(wrappedUsdc, usdcMarketId, IStandardManager.AssetType.Base);
    manager.setOraclesForMarket(usdcMarketId, usdcFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    manager.setBaseAssetMarginFactor(usdcMarketId, 0.98e18, 0.98e18);

    cngnMarketId = manager.createMarket("WRAPPED_CNGN");
    manager.whitelistAsset(wrappedCngn, cngnMarketId, IStandardManager.AssetType.Base);
    manager.setOraclesForMarket(cngnMarketId, cngnFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    manager.setBaseAssetMarginFactor(cngnMarketId, 0, 0);

    manager.setStableFeed(stableFeed);
    manager.setDepegParameters(IStandardManager.DepegParams(0.98e18, 1.3e18));

    // --- matching + both modules ---
    matching = new Matching(subAccounts);

    feeAcc = subAccounts.createAccount(feeOwner, IManager(address(manager)));
    unreachableFeeAcc = subAccounts.createAccount(address(this), IManager(address(manager)));

    wrappedQuoteTrade = new TradeModule(matching, IAsset(address(wrappedUsdc)), feeAcc);
    cashQuoteTrade = new TradeModule(matching, IAsset(address(cash)), feeAcc);
    matching.setAllowedModule(address(wrappedQuoteTrade), true);
    matching.setAllowedModule(address(cashQuoteTrade), true);
    matching.setTradeExecutor(tradeExecutor, true);
    domainSeparator = matching.domainSeparator();

    // --- accounts ---
    camAcc = _openAccount(cam);
    dougAcc = _openAccount(doug);

    _depositWrapped(wrappedUsdc, usdc, camAcc, USDC_DEPOSIT);
    _depositWrapped(wrappedCngn, cngn, dougAcc, CNGN_DEPOSIT);

    // The fee recipient must let the module CREDIT it: WrappedERC20Asset.handleAdjustment always
    // returns needAllowance = true, unlike CashAsset which only demands allowance on debits.
    _grantFeeAllowance(feeAcc, feeOwner, address(wrappedQuoteTrade));
  }

  //////////////////////////////////////////////////////////////
  //  1. Round trip: only the wrapped legs move, cash is inert //
  //////////////////////////////////////////////////////////////

  function testWrappedQuoteRoundTripMovesOnlyWrappedBalances() public {
    uint amount = 1_000_000e18; // 1,000,000 cNGN
    uint quoteAmount = uint(PRICE) * amount / 1e18; // 750 USDC

    int camUsdcBefore = subAccounts.getBalance(camAcc, wrappedUsdc, 0);
    int camCngnBefore = subAccounts.getBalance(camAcc, wrappedCngn, 0);
    int dougUsdcBefore = subAccounts.getBalance(dougAcc, wrappedUsdc, 0);
    int dougCngnBefore = subAccounts.getBalance(dougAcc, wrappedCngn, 0);

    _trade(wrappedQuoteTrade, amount, PRICE, 0, 0);

    // cam (taker, bid) paid exactly `quoteAmount` wrapped USDC and received exactly `amount` cNGN
    assertEq(subAccounts.getBalance(camAcc, wrappedUsdc, 0), camUsdcBefore - int(quoteAmount));
    assertEq(subAccounts.getBalance(camAcc, wrappedCngn, 0), camCngnBefore + int(amount));

    // doug (maker, ask) received exactly `quoteAmount` wrapped USDC and gave up exactly `amount` cNGN
    assertEq(subAccounts.getBalance(dougAcc, wrappedUsdc, 0), dougUsdcBefore + int(quoteAmount));
    assertEq(subAccounts.getBalance(dougAcc, wrappedCngn, 0), dougCngnBefore - int(amount));

    // conservation: nothing was minted or burned on either leg
    assertEq(
      subAccounts.getBalance(camAcc, wrappedUsdc, 0) + subAccounts.getBalance(dougAcc, wrappedUsdc, 0),
      camUsdcBefore + dougUsdcBefore
    );
    assertEq(
      subAccounts.getBalance(camAcc, wrappedCngn, 0) + subAccounts.getBalance(dougAcc, wrappedCngn, 0),
      camCngnBefore + dougCngnBefore
    );

    // the settlement ledger was never touched
    assertEq(subAccounts.getBalance(camAcc, cash, 0), 0);
    assertEq(subAccounts.getBalance(dougAcc, cash, 0), 0);
    assertEq(subAccounts.getBalance(feeAcc, cash, 0), 0);

    // every wrapped-USDC unit inside SubAccounts is backed 1:1 by a real USDC token held by the asset
    _assertFullyBacked();
  }

  /// @dev the same trade, but the taker is the seller, so the quote leg moves the other way
  function testWrappedQuoteRoundTripTakerIsSeller() public {
    // give cam some cNGN to sell and doug some USDC to pay with
    _depositWrapped(wrappedCngn, cngn, camAcc, CNGN_DEPOSIT);
    _depositWrapped(wrappedUsdc, usdc, dougAcc, USDC_DEPOSIT);

    uint amount = 1_000_000e18;
    uint quoteAmount = uint(PRICE) * amount / 1e18;

    int camUsdcBefore = subAccounts.getBalance(camAcc, wrappedUsdc, 0);
    int dougUsdcBefore = subAccounts.getBalance(dougAcc, wrappedUsdc, 0);

    _tradeWithSides(wrappedQuoteTrade, amount, PRICE, 0, 0, false);

    assertEq(subAccounts.getBalance(camAcc, wrappedUsdc, 0), camUsdcBefore + int(quoteAmount));
    assertEq(subAccounts.getBalance(dougAcc, wrappedUsdc, 0), dougUsdcBefore - int(quoteAmount));
    assertEq(subAccounts.getBalance(camAcc, cash, 0), 0);
    assertEq(subAccounts.getBalance(dougAcc, cash, 0), 0);
    _assertFullyBacked();
  }

  /////////////////////////////////
  //  2. Fee-bearing trade       //
  /////////////////////////////////

  function testWrappedQuoteFeeBearingTradeCreditsFeeRecipientInWrappedUsdc() public {
    // doug needs quote to pay a maker fee out of, on top of what the fill pays him
    _depositWrapped(wrappedUsdc, usdc, dougAcc, USDC_DEPOSIT);

    uint amount = 1_000_000e18;
    uint quoteAmount = uint(PRICE) * amount / 1e18;
    uint takerFee = 0.5e18;
    uint makerFee = 0.25e18;

    int camUsdcBefore = subAccounts.getBalance(camAcc, wrappedUsdc, 0);
    int dougUsdcBefore = subAccounts.getBalance(dougAcc, wrappedUsdc, 0);

    _trade(wrappedQuoteTrade, amount, PRICE, takerFee, makerFee);

    // fees are paid in the quote asset, i.e. wrapped USDC, and land on the fee subaccount
    assertEq(subAccounts.getBalance(feeAcc, wrappedUsdc, 0), int(takerFee + makerFee));
    assertEq(subAccounts.getBalance(feeAcc, cash, 0), 0);

    assertEq(subAccounts.getBalance(camAcc, wrappedUsdc, 0), camUsdcBefore - int(quoteAmount) - int(takerFee));
    assertEq(subAccounts.getBalance(dougAcc, wrappedUsdc, 0), dougUsdcBefore + int(quoteAmount) - int(makerFee));

    _assertFullyBacked();
  }

  /**
   * @dev THE OPERATIONAL BLOCKER, pinned as a test.
   *
   * CashAsset.handleAdjustment returns `needAllowance = adjustment.amount < 0`, so crediting the fee
   * recipient with cash needs no allowance. WrappedERC20Asset.handleAdjustment returns
   * `needAllowance = true` unconditionally, so crediting it with a wrapped asset does. The fee
   * subaccount is not one of the signed actions, so the module does not own it and cannot bypass the
   * allowance. Production's fee recipient is subaccount 1, owned by the SecurityModule contract,
   * which exposes no way to call setAssetAllowances or approve -- so a non-zero fee would revert the
   * whole batch. Fees are hardcoded to "0" offchain today, which is why this is latent.
   */
  function testWrappedQuoteNonZeroFeeRevertsWithoutFeeRecipientAllowance() public {
    wrappedQuoteTrade.setFeeRecipient(unreachableFeeAcc);

    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActionsWithSides(address(wrappedQuoteTrade), 1_000_000e18, PRICE, 1_000_000e18, true);
    bytes memory order = _orderData(1_000_000e18, PRICE, 0.5e18, 0);

    vm.prank(tradeExecutor);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAllowances.NotEnoughSubIdOrAssetAllowances.selector,
        address(wrappedQuoteTrade),
        unreachableFeeAcc,
        int(0.5e18),
        0,
        0
      )
    );
    matching.verifyAndMatch(actions, sigs, order);
  }

  /// @dev ...and a ZERO fee still settles against that same unreachable recipient, which is exactly
  ///      why the current production configuration works and why the risk is easy to miss.
  function testWrappedQuoteZeroFeeSettlesAgainstAllowancelessFeeRecipient() public {
    wrappedQuoteTrade.setFeeRecipient(unreachableFeeAcc);
    _trade(wrappedQuoteTrade, 1_000_000e18, PRICE, 0, 0);
    assertEq(subAccounts.getBalance(unreachableFeeAcc, wrappedUsdc, 0), 0);
  }

  ////////////////////////////////////////////////
  //  3. The two modules cannot be confused     //
  ////////////////////////////////////////////////

  /**
   * @dev The EIP-712 action hash commits to `address(module)`
   *      (ActionVerifier.ACTION_TYPEHASH), so an order signed for the cash-quoted module is not a
   *      valid order for the wrapped-quote module. A matcher that routed an order to the wrong
   *      module gets a signature failure, not a fill against the wrong ledger.
   */
  function testOrderSignedForCashModuleIsRejectedByWrappedModule() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActions(address(cashQuoteTrade), 1_000_000e18, PRICE, 1e18);

    // re-point the actions at the wrapped-quote module, keeping the signatures made for the cash one
    actions[0].module = IMatchingModule(address(wrappedQuoteTrade));
    actions[1].module = IMatchingModule(address(wrappedQuoteTrade));

    vm.prank(tradeExecutor);
    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    matching.verifyAndMatch(actions, sigs, _orderData(1_000_000e18, PRICE, 0, 0));
  }

  /// @dev and the reverse direction fails the same way
  function testOrderSignedForWrappedModuleIsRejectedByCashModule() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActions(address(wrappedQuoteTrade), 1_000_000e18, PRICE, 1e18);

    actions[0].module = IMatchingModule(address(cashQuoteTrade));
    actions[1].module = IMatchingModule(address(cashQuoteTrade));

    vm.prank(tradeExecutor);
    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    matching.verifyAndMatch(actions, sigs, _orderData(1_000_000e18, PRICE, 0, 0));
  }

  /// @dev a batch that mixes the two modules is rejected before any signature is even checked
  function testMixedModuleBatchIsRejected() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActions(address(wrappedQuoteTrade), 1_000_000e18, PRICE, 1e18);
    actions[1].module = IMatchingModule(address(cashQuoteTrade));

    vm.prank(tradeExecutor);
    vm.expectRevert(IMatching.M_MismatchedModule.selector);
    matching.verifyAndMatch(actions, sigs, _orderData(1_000_000e18, PRICE, 0, 0));
  }

  /// @dev the same nonce is independent state in each module, so a fill on one does not consume the
  ///      other's fill budget. Two correctly-signed orders can therefore each fill in full -- the
  ///      offchain matcher, not the chain, is what must not offer the same size on two books.
  function testFilledAmountIsPerModuleNotShared() public {
    _depositWrapped(wrappedUsdc, usdc, camAcc, USDC_DEPOSIT);

    _trade(wrappedQuoteTrade, 1_000_000e18, PRICE, 0, 0);

    assertEq(wrappedQuoteTrade.filled(cam, 1), 1_000_000e18);
    assertEq(cashQuoteTrade.filled(cam, 1), 0);
  }

  ///////////////////////////////////////////////
  //  4. The book is structurally 1:1 backed   //
  ///////////////////////////////////////////////

  /// @dev a buyer cannot overdraw the quote leg: there is no borrow, unlike CashAsset
  function testBuyerCannotOverdrawTheWrappedQuoteLeg() public {
    // cam holds 10,000 USDC; try to buy 20,000,000 cNGN = 15,000 USDC
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActionsWithSides(address(wrappedQuoteTrade), 20_000_000e18, PRICE, 20_000_000e18, true);
    bytes memory order = _orderData(20_000_000e18, PRICE, 0, 0);

    vm.prank(tradeExecutor);
    vm.expectRevert(IWrappedERC20Asset.WERC_CannotBeNegative.selector);
    matching.verifyAndMatch(actions, sigs, order);
  }

  /// @dev by contrast, the cash-quoted module lets the same account go negative on the quote leg,
  ///      which is the unbacked exposure this change removes. Borrowing is disabled on the SRM, so
  ///      the manager rejects it -- but the rejection is a risk-parameter decision, not a structural
  ///      one: flip `setBorrowingEnabled(true)` and the same trade creates an unbacked USDC short.
  function testCashQuotedModuleWouldTakeTheQuoteLegNegative() public {
    matching.setAllowedModule(address(cashQuoteTrade), true);

    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActions(address(cashQuoteTrade), 1_000_000e18, PRICE, 1e18);

    vm.prank(tradeExecutor);
    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    matching.verifyAndMatch(actions, sigs, _orderData(1_000_000e18, PRICE, 0, 0));
  }

  //////////////////////
  //     Helpers      //
  //////////////////////

  function _assertFullyBacked() internal view {
    // sum of every wrapped-USDC subaccount balance == USDC the asset contract actually custodies
    int total = subAccounts.getBalance(camAcc, wrappedUsdc, 0) + subAccounts.getBalance(dougAcc, wrappedUsdc, 0)
      + subAccounts.getBalance(feeAcc, wrappedUsdc, 0) + subAccounts.getBalance(unreachableFeeAcc, wrappedUsdc, 0);
    // 18dp inside SubAccounts, 6dp on the token
    assertEq(uint(total) / 1e12, usdc.balanceOf(address(wrappedUsdc)));

    int totalCngn = subAccounts.getBalance(camAcc, wrappedCngn, 0) + subAccounts.getBalance(dougAcc, wrappedCngn, 0)
      + subAccounts.getBalance(feeAcc, wrappedCngn, 0);
    assertEq(uint(totalCngn) / 1e12, cngn.balanceOf(address(wrappedCngn)));
  }

  function _openAccount(address owner) internal returns (uint accId) {
    accId = subAccounts.createAccount(owner, IManager(address(manager)));
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accId);
    matching.depositSubAccount(accId);
    vm.stopPrank();
  }

  function _depositWrapped(WrappedERC20Asset wrapped, MockERC20 token, uint accId, uint amount18) internal {
    uint native = amount18 / 1e12; // 18dp -> 6dp
    token.mint(address(this), native);
    token.approve(address(wrapped), native);
    wrapped.deposit(accId, native);
  }

  function _grantFeeAllowance(uint accId, address owner, address delegate) internal {
    IAllowances.AssetAllowance[] memory allowances = new IAllowances.AssetAllowance[](2);
    allowances[0] =
      IAllowances.AssetAllowance({asset: IAsset(address(wrappedUsdc)), positive: type(uint).max, negative: 0});
    allowances[1] =
      IAllowances.AssetAllowance({asset: IAsset(address(wrappedCngn)), positive: type(uint).max, negative: 0});
    vm.prank(owner);
    subAccounts.setAssetAllowances(accId, delegate, allowances);
  }

  /// @dev cam is the taker and bids; doug is the maker and asks
  function _trade(TradeModule module, uint amount, int price, uint takerFee, uint makerFee) internal {
    _tradeWithSides(module, amount, price, takerFee, makerFee, true);
  }

  function _tradeWithSides(TradeModule module, uint amount, int price, uint takerFee, uint makerFee, bool takerIsBid)
    internal
  {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) =
      _buildActionsWithSides(address(module), amount, price, amount, takerIsBid);
    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, _orderData(amount, price, takerFee, makerFee));
  }

  function _buildActions(address module, uint amount, int price, uint /*worstFee*/)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory sigs)
  {
    return _buildActionsWithSides(module, amount, price, amount, true);
  }

  function _buildActionsWithSides(address module, uint /*amount*/, int price, uint desired, bool takerIsBid)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory sigs)
  {
    actions = new IActionVerifier.Action[](2);
    sigs = new bytes[](2);

    bytes memory takerData = abi.encode(
      ITradeModule.TradeData({
        asset: address(wrappedCngn),
        subId: 0,
        limitPrice: price,
        desiredAmount: int(desired),
        worstFee: 1e18,
        recipientId: camAcc,
        isBid: takerIsBid
      })
    );
    bytes memory makerData = abi.encode(
      ITradeModule.TradeData({
        asset: address(wrappedCngn),
        subId: 0,
        limitPrice: price,
        desiredAmount: int(desired),
        worstFee: 1e18,
        recipientId: dougAcc,
        isBid: !takerIsBid
      })
    );

    (actions[0], sigs[0]) = _signed(camAcc, 1, module, takerData, cam, camPk);
    (actions[1], sigs[1]) = _signed(dougAcc, 1, module, makerData, doug, dougPk);
  }

  function _orderData(uint amount, int price, uint takerFee, uint makerFee) internal view returns (bytes memory) {
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: dougAcc, amountFilled: amount, price: price, fee: makerFee});
    return abi.encode(
      ITradeModule.OrderData({takerAccount: camAcc, takerFee: takerFee, fillDetails: fills, managerData: bytes("")})
    );
  }

  function _signed(uint accId, uint nonce, address module, bytes memory data, address owner, uint pk)
    internal
    view
    returns (IActionVerifier.Action memory action, bytes memory sig)
  {
    action = IActionVerifier.Action({
      subaccountId: accId,
      nonce: nonce,
      module: IMatchingModule(module),
      data: data,
      expiry: block.timestamp + 1 days,
      owner: owner,
      signer: owner
    });
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(domainSeparator, matching.getActionHash(action)));
    sig = bytes.concat(r, s, bytes1(v));
  }
}
