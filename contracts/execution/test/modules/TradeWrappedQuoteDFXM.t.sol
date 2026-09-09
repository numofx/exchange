// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {TestDeliverableFXManagerBase} from
  "v2-core/test/risk-managers/unit-tests/DeliverableFXManager/TestDeliverableFXManagerBase.t.sol";

import {Matching} from "src/Matching.sol";
import {IMatching} from "src/interfaces/IMatching.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";

import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TradeWrappedQuoteDFXMTest
 *
 * @dev The USDC/cNGN spot book is live under `DeliverableFXManager`, not the StandardManager --
 *      the SRM migration batch is still unsigned (contracts/risk-core/DEPLOYED_ADDRESSES.md).
 *      So the wrapped-quote TradeModule has to work under DFXM too, and this pins both that it
 *      does and the one behavioural change it introduces: spot fills now consume the very same
 *      wrapped-USDC balance that backs a deliverable future's physical delivery, which the cash
 *      quote leg never touched.
 */
contract TradeWrappedQuoteDFXMTest is TestDeliverableFXManagerBase {
  Matching matching;
  TradeModule wrappedQuoteTrade;

  address tradeExecutor = address(0xaaaa);
  bytes32 domainSeparator;

  uint camPk = 0xBEEF;
  address cam = vm.addr(0xBEEF);
  uint camAcc;

  uint dougPk = 0xEEEE;
  address doug = vm.addr(0xEEEE);
  uint dougAcc;

  address feeOwner = address(0xFEE0);
  uint feeAcc;

  int constant PRICE = 0.00075e18; // USDC per cNGN
  uint constant USDC_DEPOSIT = 100_000e18;
  uint constant CNGN_DEPOSIT = 200_000_000e18;

  function setUp() public override {
    super.setUp();

    matching = new Matching(subAccounts);
    feeAcc = subAccounts.createAccount(feeOwner, manager);
    wrappedQuoteTrade = new TradeModule(matching, IAsset(address(usdcDeliveryAsset)), feeAcc);
    matching.setAllowedModule(address(wrappedQuoteTrade), true);
    matching.setTradeExecutor(tradeExecutor, true);
    domainSeparator = matching.domainSeparator();

    // Accounts are created and funded here but deliberately NOT deposited into Matching yet:
    // a test that needs to open a future position first must do so while it still holds the
    // subaccount approval. `_enterMatching()` hands them over.
    camAcc = subAccounts.createAccountWithApproval(cam, address(this), manager);
    dougAcc = subAccounts.createAccountWithApproval(doug, address(this), manager);

    _depositWrapped(usdc, usdcDeliveryAsset, camAcc, USDC_DEPOSIT);
    _depositWrapped(cngn, cngnAsset, dougAcc, CNGN_DEPOSIT);

    IAllowances.AssetAllowance[] memory allowances = new IAllowances.AssetAllowance[](1);
    allowances[0] =
      IAllowances.AssetAllowance({asset: IAsset(address(usdcDeliveryAsset)), positive: type(uint).max, negative: 0});
    vm.prank(feeOwner);
    subAccounts.setAssetAllowances(feeAcc, address(wrappedQuoteTrade), allowances);
  }

  /// @dev the live manager accepts a spot fill whose quote leg is the wrapped USDC delivery asset
  function testSpotTradeSettlesInWrappedUsdcUnderDeliverableFXManager() public {
    uint amount = 1_000_000e18;
    uint quoteAmount = uint(PRICE) * amount / 1e18;

    _trade(amount, PRICE, 0, 0);

    assertEq(subAccounts.getBalance(camAcc, usdcDeliveryAsset, 0), int(USDC_DEPOSIT) - int(quoteAmount));
    assertEq(subAccounts.getBalance(camAcc, cngnAsset, 0), int(amount));
    assertEq(subAccounts.getBalance(dougAcc, usdcDeliveryAsset, 0), int(quoteAmount));
    assertEq(subAccounts.getBalance(dougAcc, cngnAsset, 0), int(CNGN_DEPOSIT) - int(amount));

    // the settlement ledger is untouched on both sides
    assertEq(_getCashBalance(camAcc), 0);
    assertEq(_getCashBalance(dougAcc), 0);
  }

  /// @dev fees are charged in the quote asset, so they land as wrapped USDC on the fee subaccount
  function testFeeBearingSpotTradeUnderDeliverableFXManager() public {
    _depositWrapped(usdc, usdcDeliveryAsset, dougAcc, USDC_DEPOSIT);

    uint amount = 1_000_000e18;
    uint quoteAmount = uint(PRICE) * amount / 1e18;

    _trade(amount, PRICE, 0.5e18, 0.25e18);

    assertEq(subAccounts.getBalance(feeAcc, usdcDeliveryAsset, 0), int(0.75e18));
    assertEq(_getCashBalance(feeAcc), 0);
    assertEq(subAccounts.getBalance(camAcc, usdcDeliveryAsset, 0), int(USDC_DEPOSIT) - int(quoteAmount) - int(0.5e18));
  }

  /**
   * @dev THE COUPLING TO CALL OUT AT REVIEW.
   *
   * DeliverableFXManager reserves wrapped USDC to back a short future's physical delivery. Once the
   * series is past `lastTradeTime` the manager demands the account still HOLD that USDC
   * (`_getDeliveryReadiness`), so a spot buy that spends it is rejected. Under the cash-quoted
   * module the spot leg moved CASH, which delivery readiness ignores entirely -- the same trade
   * would have settled and the delivery obligation would only have failed later, at delivery.
   *
   * Making the quote leg the delivery asset is what creates this link. It is the desired direction
   * (you cannot sell USDC you have already promised to deliver) but it is a NEW way for a spot
   * order to be rejected, and only for accounts that also hold a deliverable future in its
   * delivery window.
   */
  function testSpotBuyCannotSpendUsdcReservedForFutureDeliveryInDeliveryWindow() public {
    // cam goes short one contract: they owe 10,000 USDC (contractSizeBase) at delivery
    _openFuturePosition(camAcc, dougAcc, 1e18);
    assertGt(manager.getDeliveryReadiness(camAcc).reservedBase, 0);
    _enterMatching();

    // enter the delivery window, where the reservation becomes binding
    vm.warp(fxLastTradeTime + 1);

    // cam holds 100,000 USDC; try to spend 97,500 of it on cNGN, leaving less than the reservation
    uint amount = 130_000_000e18; // * 0.00075 = 97,500 USDC
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildActions(amount, PRICE);

    vm.prank(tradeExecutor);
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    matching.verifyAndMatch(actions, sigs, _orderData(amount, PRICE, 0, 0));
  }

  /// @dev the same trade settles OUTSIDE the delivery window -- the reservation is not yet binding,
  ///      so day-to-day spot flow for accounts with open futures is unaffected
  function testSpotBuySpendingReservedUsdcIsAllowedBeforeDeliveryWindow() public {
    _openFuturePosition(camAcc, dougAcc, 1e18);
    assertLt(block.timestamp, fxLastTradeTime);

    _trade(130_000_000e18, PRICE, 0, 0);
    assertEq(subAccounts.getBalance(camAcc, cngnAsset, 0), int(130_000_000e18));
  }

  /// @dev ...and a spot buy that leaves the reservation intact settles inside the window too
  function testSpotBuyWithinFreeUsdcStillSettlesWithAnOpenFuture() public {
    _openFuturePosition(camAcc, dougAcc, 1e18);
    _enterMatching();
    vm.warp(fxLastTradeTime + 1);

    uint amount = 1_000_000e18; // 750 USDC, far inside the free balance
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildActions(amount, PRICE);
    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, _orderData(amount, PRICE, 0, 0));

    assertEq(subAccounts.getBalance(camAcc, cngnAsset, 0), int(amount));
  }

  ////////////////
  //  Helpers   //
  ////////////////

  /// @dev hand both subaccounts to Matching; must run after any direct-transfer setup
  function _enterMatching() internal {
    if (subAccounts.ownerOf(camAcc) == address(matching)) return;
    vm.startPrank(cam);
    subAccounts.approve(address(matching), camAcc);
    matching.depositSubAccount(camAcc);
    vm.stopPrank();
    vm.startPrank(doug);
    subAccounts.approve(address(matching), dougAcc);
    matching.depositSubAccount(dougAcc);
    vm.stopPrank();
  }

  function _trade(uint amount, int price, uint takerFee, uint makerFee) internal {
    _enterMatching();
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildActions(amount, price);
    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, _orderData(amount, price, takerFee, makerFee));
  }

  function _buildActions(uint amount, int price)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory sigs)
  {
    actions = new IActionVerifier.Action[](2);
    sigs = new bytes[](2);

    bytes memory takerData = abi.encode(
      ITradeModule.TradeData({
        asset: address(cngnAsset),
        subId: 0,
        limitPrice: price,
        desiredAmount: int(amount),
        worstFee: 1e18,
        recipientId: camAcc,
        isBid: true
      })
    );
    bytes memory makerData = abi.encode(
      ITradeModule.TradeData({
        asset: address(cngnAsset),
        subId: 0,
        limitPrice: price,
        desiredAmount: int(amount),
        worstFee: 1e18,
        recipientId: dougAcc,
        isBid: false
      })
    );

    (actions[0], sigs[0]) = _signed(camAcc, 1, takerData, cam, camPk);
    (actions[1], sigs[1]) = _signed(dougAcc, 1, makerData, doug, dougPk);
  }

  function _orderData(uint amount, int price, uint takerFee, uint makerFee) internal view returns (bytes memory) {
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: dougAcc, amountFilled: amount, price: price, fee: makerFee});
    return abi.encode(
      ITradeModule.OrderData({takerAccount: camAcc, takerFee: takerFee, fillDetails: fills, managerData: bytes("")})
    );
  }

  function _signed(uint accId, uint nonce, bytes memory data, address owner, uint pk)
    internal
    view
    returns (IActionVerifier.Action memory action, bytes memory sig)
  {
    action = IActionVerifier.Action({
      subaccountId: accId,
      nonce: nonce,
      module: IMatchingModule(address(wrappedQuoteTrade)),
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
