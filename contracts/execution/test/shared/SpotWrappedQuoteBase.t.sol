// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {Matching} from "src/Matching.sol";
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
import {IForwardFeed} from "v2-core/src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "v2-core/src/interfaces/IVolFeed.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";

import {StandardManager} from "v2-core/src/risk-managers/StandardManager.sol";
import {SRMPortfolioViewer} from "v2-core/src/risk-managers/SRMPortfolioViewer.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";

import {MockERC20} from "v2-core/test/shared/mocks/MockERC20.sol";
import {MockCash} from "v2-core/test/shared/mocks/MockCash.sol";
import {MockFeeds} from "v2-core/test/shared/mocks/MockFeeds.sol";
import {MockDutchAuction} from "v2-core/test/risk-managers/mocks/MockDutchAuction.sol";

import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

/**
 * @dev Reproduces the Base-mainnet USDC/cNGN spot shape in miniature:
 *
 *   - StandardManager (SRM), borrowing disabled, exactly as on mainnet
 *   - a CashAsset ledger, whose allowance semantics (positive credits need no allowance)
 *     match the real CashAsset.handleAdjustment -> `needAllowance = amount < 0`
 *   - WRAPPED_USDC_DELIVERABLE: WrappedERC20Asset over 6dp USDC, SRM market 1,
 *     marginFactor 0.98 / IMScale 0.98 (contracts/risk-core/deployments/8453/WRAPPED_USDC_DELIVERABLE.json)
 *   - WRAPPED_CNGN: WrappedERC20Asset over 6dp cNGN, SRM market 2, marginFactor 0
 *     (CNGN_SPOT_SRM_VAULT_ACTIONS.json: `srm.setBaseAssetMarginFactor(2, 0)`)
 *   - Matching plus TWO TradeModules: the legacy cash-quoted one that is live today, and the
 *     wrapped-USDC-quoted one under test.
 */
contract SpotWrappedQuoteBase is Test {
  // ---------------------------------------------------------------------------------------
  // actors
  // ---------------------------------------------------------------------------------------

  address public tradeExecutor = address(0xEE);

  uint public camPk = 0xBEEF;
  address public cam;
  uint public camAcc;

  uint public dougPk = 0xEEEE;
  address public doug;
  uint public dougAcc;

  /// @dev owner of the fee-recipient subaccount. Deliberately NOT the Matching contract: a
  ///      Matching-held subaccount has no way to call setAssetAllowances, so it can never grant
  ///      the positive allowance a wrapped-asset fee credit requires.
  address public feeOwner = address(0xFEE);
  uint public feeAcc;

  // ---------------------------------------------------------------------------------------
  // core
  // ---------------------------------------------------------------------------------------

  SubAccounts public subAccounts;
  StandardManager public srm;
  SRMPortfolioViewer public viewer;
  MockDutchAuction public auction;

  MockERC20 public cashToken;
  MockCash public cash;

  MockERC20 public usdc;
  MockERC20 public cngn;
  WrappedERC20Asset public wrappedUsdc;
  WrappedERC20Asset public wrappedCngn;

  MockFeeds public stableFeed;
  MockFeeds public usdcFeed;
  MockFeeds public cngnFeed;

  uint public usdcMarketId;
  uint public cngnMarketId;

  Matching public matching;
  /// @dev the module under test: quoteAsset == wrappedUsdc
  TradeModule public wrappedQuoteTrade;
  /// @dev the module live on Base today: quoteAsset == cash
  TradeModule public cashQuoteTrade;

  bytes32 public domainSeparator;

  /// @dev USDC per cNGN, 18dp. Mainnet CNGN_SPOT_STATIC_FEEDS.json usdcPerCngn = 743376685636834.
  int public constant CNGN_PRICE = 743376685636834;

  function setUp() public virtual {
    cam = vm.addr(camPk);
    doug = vm.addr(dougPk);
    vm.label(cam, "cam");
    vm.label(doug, "doug");
    vm.label(feeOwner, "feeOwner");

    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    // ---- cash ledger -------------------------------------------------------------------
    cashToken = new MockERC20("USDC-cash", "USDC-cash");
    cash = new MockCash(cashToken, subAccounts);

    // ---- manager -----------------------------------------------------------------------
    auction = new MockDutchAuction();
    viewer = new SRMPortfolioViewer(subAccounts, cash);
    srm = new StandardManager(subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), viewer);
    viewer.setStandardManager(srm);

    stableFeed = new MockFeeds();
    stableFeed.setSpot(1e18, 1e18);
    srm.setStableFeed(stableFeed);
    srm.setDepegParameters(IStandardManager.DepegParams(0.98e18, 1.3e18));
    // mainnet: srm.setBorrowingEnabled(false). This is the default, asserted in the tests.

    // ---- WRAPPED_USDC_DELIVERABLE (market 1) --------------------------------------------
    usdc = new MockERC20("USDC", "USDC");
    usdc.setDecimals(6);
    wrappedUsdc = new WrappedERC20Asset(subAccounts, usdc);
    wrappedUsdc.setWhitelistManager(address(srm), true);
    wrappedUsdc.setTotalPositionCap(srm, 1e36);

    usdcFeed = new MockFeeds();
    usdcFeed.setSpot(1e18, 1e18);

    usdcMarketId = srm.createMarket("WRAPPED_USDC_DELIVERABLE");
    srm.whitelistAsset(wrappedUsdc, usdcMarketId, IStandardManager.AssetType.Base);
    srm.setOraclesForMarket(usdcMarketId, usdcFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    srm.setBaseAssetMarginFactor(usdcMarketId, 0.98e18, 0.98e18);

    // ---- WRAPPED_CNGN (market 2) ---------------------------------------------------------
    cngn = new MockERC20("cNGN", "cNGN");
    cngn.setDecimals(6);
    wrappedCngn = new WrappedERC20Asset(subAccounts, cngn);
    wrappedCngn.setWhitelistManager(address(srm), true);
    wrappedCngn.setTotalPositionCap(srm, 1e36);

    cngnFeed = new MockFeeds();
    cngnFeed.setSpot(uint(CNGN_PRICE), 1e18);

    cngnMarketId = srm.createMarket("CNGN");
    srm.whitelistAsset(wrappedCngn, cngnMarketId, IStandardManager.AssetType.Base);
    srm.setOraclesForMarket(cngnMarketId, cngnFeed, IForwardFeed(address(0)), IVolFeed(address(0)));
    srm.setBaseAssetMarginFactor(cngnMarketId, 0, 1e18);

    // ---- matching + modules ---------------------------------------------------------------
    matching = new Matching(subAccounts);
    domainSeparator = matching.domainSeparator();
    matching.setTradeExecutor(tradeExecutor, true);

    _setupAccounts();

    wrappedQuoteTrade = new TradeModule(matching, IAsset(address(wrappedUsdc)), feeAcc);
    cashQuoteTrade = new TradeModule(matching, IAsset(address(cash)), feeAcc);
    matching.setAllowedModule(address(wrappedQuoteTrade), true);
    matching.setAllowedModule(address(cashQuoteTrade), true);

    vm.label(address(wrappedQuoteTrade), "wrappedQuoteTrade");
    vm.label(address(cashQuoteTrade), "cashQuoteTrade");
  }

  // ---------------------------------------------------------------------------------------
  // setup helpers
  // ---------------------------------------------------------------------------------------

  function _setupAccounts() internal {
    camAcc = subAccounts.createAccount(cam, IManager(address(srm)));
    dougAcc = subAccounts.createAccount(doug, IManager(address(srm)));
    feeAcc = subAccounts.createAccount(feeOwner, IManager(address(srm)));

    _depositSubAccount(cam, camAcc);
    _depositSubAccount(doug, dougAcc);
    // feeAcc is intentionally left outside Matching.
  }

  function _depositSubAccount(address owner, uint accountId) internal {
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  /// @dev mint the underlying and deposit it through the wrapper. `nativeAmount` is in the
  ///      token's own decimals (6 for both USDC and cNGN).
  function _depositWrapped(MockERC20 token, WrappedERC20Asset wrapper, uint accountId, uint nativeAmount) internal {
    token.mint(address(this), nativeAmount);
    token.approve(address(wrapper), nativeAmount);
    wrapper.deposit(accountId, nativeAmount);
  }

  function _depositCash(uint accountId, uint amount18) internal {
    cashToken.mint(address(this), amount18);
    cashToken.approve(address(cash), amount18);
    cash.deposit(accountId, amount18);
  }

  /// @dev the one-time grant the wrapped-quote module needs before it can credit a fee.
  ///      Mirrors the operational step in the deploy script's vault-actions output.
  function _grantFeeAllowance(IAsset asset, address module, uint amount) internal {
    IAllowances.AssetAllowance[] memory allowances = new IAllowances.AssetAllowance[](1);
    allowances[0] = IAllowances.AssetAllowance({asset: asset, positive: amount, negative: 0});
    vm.prank(feeOwner);
    subAccounts.setAssetAllowances(feeAcc, module, allowances);
  }

  // ---------------------------------------------------------------------------------------
  // action helpers
  // ---------------------------------------------------------------------------------------

  function _signAction(bytes32 actionHash, uint signerPk) internal view returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, MessageHashUtils.toTypedDataHash(domainSeparator, actionHash));
    return bytes.concat(r, s, bytes1(v));
  }

  function _createUnsignedAction(uint accountId, uint nonce, address module, bytes memory data, address owner)
    internal
    view
    returns (IActionVerifier.Action memory action)
  {
    action = IActionVerifier.Action({
      subaccountId: accountId,
      nonce: nonce,
      module: IMatchingModule(module),
      data: data,
      expiry: block.timestamp + 1 days,
      owner: owner,
      signer: owner
    });
  }

  function _createActionAndSign(uint accountId, uint nonce, address module, bytes memory data, address owner, uint pk)
    internal
    view
    returns (IActionVerifier.Action memory action, bytes memory signature)
  {
    action = _createUnsignedAction(accountId, nonce, module, data, owner);
    signature = _signAction(matching.getActionHash(action), pk);
  }

  /// @dev one taker order and one maker order for `amount` of wrapped cNGN at `price`.
  ///      `takerIsBid` true means the taker is buying cNGN and paying the quote asset.
  function _spotActions(address module, bool takerIsBid, uint amount, int price, uint takerWorstFee, uint makerWorstFee)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory signatures)
  {
    return _spotActions(module, takerIsBid, amount, price, takerWorstFee, makerWorstFee, 1);
  }

  function _spotActions(
    address module,
    bool takerIsBid,
    uint amount,
    int price,
    uint takerWorstFee,
    uint makerWorstFee,
    uint nonce
  ) internal view returns (IActionVerifier.Action[] memory actions, bytes[] memory signatures) {
    actions = new IActionVerifier.Action[](2);
    signatures = new bytes[](2);

    ITradeModule.TradeData memory takerData = ITradeModule.TradeData({
      asset: address(wrappedCngn),
      subId: 0,
      limitPrice: price,
      desiredAmount: int(amount),
      worstFee: takerWorstFee,
      recipientId: camAcc,
      isBid: takerIsBid
    });
    ITradeModule.TradeData memory makerData = ITradeModule.TradeData({
      asset: address(wrappedCngn),
      subId: 0,
      limitPrice: price,
      desiredAmount: int(amount),
      worstFee: makerWorstFee,
      recipientId: dougAcc,
      isBid: !takerIsBid
    });

    (actions[0], signatures[0]) = _createActionAndSign(camAcc, nonce, module, abi.encode(takerData), cam, camPk);
    (actions[1], signatures[1]) = _createActionAndSign(dougAcc, nonce, module, abi.encode(makerData), doug, dougPk);
  }

  function _orderData(uint amount, int price, uint takerFee, uint makerFee) internal view returns (bytes memory) {
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: dougAcc, amountFilled: amount, price: price, fee: makerFee});
    return abi.encode(
      ITradeModule.OrderData({takerAccount: camAcc, takerFee: takerFee, fillDetails: fills, managerData: bytes("")})
    );
  }

  function _verifyAndMatch(IActionVerifier.Action[] memory actions, bytes[] memory signatures, bytes memory actionData)
    internal
  {
    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, signatures, actionData);
  }

  // ---------------------------------------------------------------------------------------
  // assertions
  // ---------------------------------------------------------------------------------------

  function _bal(uint accountId, IAsset asset) internal view returns (int) {
    return subAccounts.getBalance(accountId, asset, 0);
  }

  function test() external {
    // skip coverage
  }
}
