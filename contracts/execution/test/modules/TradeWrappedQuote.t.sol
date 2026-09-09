// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {SpotWrappedQuoteBase} from "test/shared/SpotWrappedQuoteBase.t.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatching} from "src/interfaces/IMatching.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {ITradeModule} from "src/modules/TradeModule.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";

/**
 * @dev The USDC leg of USDC/cNGN, quoted in the wrapped USDC asset instead of the cash ledger.
 *
 * Every trade below moves two WrappedERC20Asset balances and nothing else, which is the point:
 * a wrapped balance is redeemable 1:1 for the ERC20 the wrapper holds, so the book is
 * structurally backed on both legs rather than on one leg plus a settlement ledger.
 */
contract TradeWrappedQuoteTest is SpotWrappedQuoteBase {
  /// 1,000,000 cNGN, in the wrapper's internal 18dp
  uint internal constant TRADE_AMOUNT = 1_000_000e18;
  /// TRADE_AMOUNT * CNGN_PRICE / 1e18
  int internal constant TRADE_NOTIONAL = 743376685636834000000;

  function setUp() public override {
    super.setUp();

    // cam buys cNGN with wrapped USDC; doug sells cNGN for wrapped USDC.
    _depositWrapped(usdc, wrappedUsdc, camAcc, 1000e6);
    _depositWrapped(cngn, wrappedCngn, dougAcc, 1_000_000e6);

    // Cash on both sides, so "cash did not move" is an assertion about a non-zero balance
    // rather than about an empty one.
    _depositCash(camAcc, 5000e18);
    _depositCash(dougAcc, 5000e18);
  }

  function testSetup() public view {
    assertEq(address(wrappedQuoteTrade.quoteAsset()), address(wrappedUsdc));
    assertEq(address(cashQuoteTrade.quoteAsset()), address(cash));
    // mainnet posture: srm.setBorrowingEnabled(false)
    assertEq(srm.borrowingEnabled(), false);

    assertEq(_bal(camAcc, IAsset(address(wrappedUsdc))), 1000e18);
    assertEq(_bal(dougAcc, IAsset(address(wrappedCngn))), 1_000_000e18);
  }

  //////////////////////////////////////////////////////////////////////////////////////////
  // 1. Round trip: both legs are wrapped-token transfers, the cash ledger is untouched.
  //////////////////////////////////////////////////////////////////////////////////////////

  function testRoundTripMovesOnlyWrappedBalances() public {
    int camUsdcBefore = _bal(camAcc, IAsset(address(wrappedUsdc)));
    int camCngnBefore = _bal(camAcc, IAsset(address(wrappedCngn)));
    int dougUsdcBefore = _bal(dougAcc, IAsset(address(wrappedUsdc)));
    int dougCngnBefore = _bal(dougAcc, IAsset(address(wrappedCngn)));
    int camCashBefore = _bal(camAcc, IAsset(address(cash)));
    int dougCashBefore = _bal(dougAcc, IAsset(address(cash)));
    int feeCashBefore = _bal(feeAcc, IAsset(address(cash)));

    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));

    // cam paid exactly the notional in wrapped USDC and received exactly the cNGN
    assertEq(_bal(camAcc, IAsset(address(wrappedUsdc))) - camUsdcBefore, -TRADE_NOTIONAL);
    assertEq(_bal(camAcc, IAsset(address(wrappedCngn))) - camCngnBefore, int(TRADE_AMOUNT));

    // doug is the exact mirror image
    assertEq(_bal(dougAcc, IAsset(address(wrappedUsdc))) - dougUsdcBefore, TRADE_NOTIONAL);
    assertEq(_bal(dougAcc, IAsset(address(wrappedCngn))) - dougCngnBefore, -int(TRADE_AMOUNT));

    // the cash ledger did not move at all
    assertEq(_bal(camAcc, IAsset(address(cash))), camCashBefore);
    assertEq(_bal(dougAcc, IAsset(address(cash))), dougCashBefore);
    assertEq(_bal(feeAcc, IAsset(address(cash))), feeCashBefore);

    // and the wrapper still holds one ERC20 unit for every unit of internal balance:
    // 1000e6 USDC in, nothing withdrawn, so the two accounts' 18dp balances sum back to it.
    assertEq(
      _bal(camAcc, IAsset(address(wrappedUsdc))) + _bal(dougAcc, IAsset(address(wrappedUsdc))), int(1000e18)
    );
    assertEq(int(usdc.balanceOf(address(wrappedUsdc))), int(1000e6));
  }

  function testRoundTripSellSide() public {
    // Same fill, taker on the ask: cam sells the cNGN back to doug.
    testRoundTripMovesOnlyWrappedBalances();

    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), false, TRADE_AMOUNT, CNGN_PRICE, 0, 0, 2);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));

    // fully unwound: everyone is back where they started
    assertEq(_bal(camAcc, IAsset(address(wrappedUsdc))), 1000e18);
    assertEq(_bal(camAcc, IAsset(address(wrappedCngn))), 0);
    assertEq(_bal(dougAcc, IAsset(address(wrappedUsdc))), 0);
    assertEq(_bal(dougAcc, IAsset(address(wrappedCngn))), 1_000_000e18);
    assertEq(_bal(camAcc, IAsset(address(cash))), 5000e18);
    assertEq(_bal(dougAcc, IAsset(address(cash))), 5000e18);
  }

  //////////////////////////////////////////////////////////////////////////////////////////
  // 2. Fees. A wrapped-asset credit needs a positive allowance; a cash credit does not.
  //////////////////////////////////////////////////////////////////////////////////////////

  /**
   * WrappedERC20Asset.handleAdjustment returns `needAllowance = true` unconditionally
   * (contracts/risk-core/src/assets/WrappedERC20Asset.sol:125), while CashAsset returns
   * `adjustment.amount < 0` (CashAsset.sol:392). SubAccounts spends allowance on the CREDIT
   * side too (SubAccounts.sol:401-403) whenever the caller is not owner-or-approved, and
   * Matching only hands the module the subaccounts named in the actions
   * (Matching.sol:89-97) -- never the fee recipient. So a wrapped-quoted fee reverts until
   * the fee-recipient owner grants the module a positive allowance.
   */
  function testFeeRevertsWithoutPositiveAllowanceOnFeeRecipient() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 1e15, 1e15);

    // the maker fee is the first fee leg in the batch, so it is the one that reverts
    vm.expectRevert(
      abi.encodeWithSelector(
        IAllowances.NotEnoughSubIdOrAssetAllowances.selector,
        address(wrappedQuoteTrade),
        feeAcc,
        int(0.5e18),
        uint(0),
        uint(0)
      )
    );
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 1e18, 0.5e18));
  }

  function testFeeBearingTrade() public {
    _grantFeeAllowance(IAsset(address(wrappedUsdc)), address(wrappedQuoteTrade), 10e18);

    int camUsdcBefore = _bal(camAcc, IAsset(address(wrappedUsdc)));
    int dougUsdcBefore = _bal(dougAcc, IAsset(address(wrappedUsdc)));

    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 1e15, 1e15);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 1e18, 0.5e18));

    // taker pays notional + its own fee
    assertEq(_bal(camAcc, IAsset(address(wrappedUsdc))) - camUsdcBefore, -(TRADE_NOTIONAL + 1e18));
    // maker receives notional less its own fee
    assertEq(_bal(dougAcc, IAsset(address(wrappedUsdc))) - dougUsdcBefore, TRADE_NOTIONAL - 0.5e18);

    // both fees land on the fee recipient as wrapped USDC, not as cash
    assertEq(_bal(feeAcc, IAsset(address(wrappedUsdc))), 1.5e18);
    assertEq(_bal(feeAcc, IAsset(address(cash))), 0);

    // allowance was consumed by exactly the fees taken
    assertEq(
      subAccounts.positiveAssetAllowance(feeAcc, feeOwner, IAsset(address(wrappedUsdc)), address(wrappedQuoteTrade)),
      10e18 - 1.5e18
    );

    // conservation: nothing was minted, the notional plus fees just moved between three accounts
    assertEq(
      _bal(camAcc, IAsset(address(wrappedUsdc))) + _bal(dougAcc, IAsset(address(wrappedUsdc)))
        + _bal(feeAcc, IAsset(address(wrappedUsdc))),
      int(1000e18)
    );
  }

  function testZeroFeeNeedsNoAllowance() public view {
    // documents why testRoundTripMovesOnlyWrappedBalances passes with no allowance at all:
    // WrappedERC20Asset short-circuits a zero adjustment before asking for one.
    assertEq(
      subAccounts.positiveAssetAllowance(feeAcc, feeOwner, IAsset(address(wrappedUsdc)), address(wrappedQuoteTrade)),
      0
    );
  }

  //////////////////////////////////////////////////////////////////////////////////////////
  // 3. The matcher cannot confuse the cash-quoted module with the wrapped-quoted one.
  //////////////////////////////////////////////////////////////////////////////////////////

  /**
   * `module` is a field of the EIP-712 Action struct hash
   * (ActionVerifier.sol:21-23 and :120-133), so a signature is bound to exactly one module
   * address. Re-pointing a signed action at the other module fails signature recovery.
   */
  function testSignatureIsBoundToOneModule() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(cashQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);

    // repoint both legs at the wrapped-quote module without re-signing
    actions[0].module = IMatchingModule(address(wrappedQuoteTrade));
    actions[1].module = IMatchingModule(address(wrappedQuoteTrade));

    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));
  }

  function testSignatureIsBoundToOneModuleReverse() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);

    actions[0].module = IMatchingModule(address(cashQuoteTrade));
    actions[1].module = IMatchingModule(address(cashQuoteTrade));

    vm.expectRevert(IActionVerifier.OV_InvalidSignature.selector);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));
  }

  /// @dev A taker signed for one module cannot be crossed against a maker signed for the other:
  ///      Matching.verifyAndMatch rejects the batch before any module runs (Matching.sol:69).
  function testCannotCrossOrdersAcrossModules() public {
    (IActionVerifier.Action[] memory wrappedActions, bytes[] memory wrappedSigs) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);
    (IActionVerifier.Action[] memory cashActions, bytes[] memory cashSigs) =
      _spotActions(address(cashQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);

    IActionVerifier.Action[] memory mixed = new IActionVerifier.Action[](2);
    bytes[] memory sigs = new bytes[](2);
    mixed[0] = wrappedActions[0];
    sigs[0] = wrappedSigs[0];
    mixed[1] = cashActions[1];
    sigs[1] = cashSigs[1];

    vm.expectRevert(IMatching.M_MismatchedModule.selector);
    _verifyAndMatch(mixed, sigs, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));
  }

  /// @dev Positive control for the two above: the same economic order signed for the LEGACY
  ///      module settles on the cash rail and leaves the wrapped USDC balances alone. The two
  ///      modules are separate rails, not two names for one.
  function testLegacyModuleStillSettlesInCashAndLeavesWrappedUsdcAlone() public {
    int camUsdcBefore = _bal(camAcc, IAsset(address(wrappedUsdc)));
    int dougUsdcBefore = _bal(dougAcc, IAsset(address(wrappedUsdc)));

    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(cashQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));

    // cash moved
    assertEq(_bal(camAcc, IAsset(address(cash))), 5000e18 - TRADE_NOTIONAL);
    assertEq(_bal(dougAcc, IAsset(address(cash))), 5000e18 + TRADE_NOTIONAL);
    // wrapped USDC did not
    assertEq(_bal(camAcc, IAsset(address(wrappedUsdc))), camUsdcBefore);
    assertEq(_bal(dougAcc, IAsset(address(wrappedUsdc))), dougUsdcBefore);
    // and the cNGN leg still delivered
    assertEq(_bal(camAcc, IAsset(address(wrappedCngn))), int(TRADE_AMOUNT));
  }

  /// @dev Nonce state is per-module storage, so a nonce burned on one module says nothing about
  ///      the other. A matcher that assumed a single global module would double-fill here.
  function testNonceStateIsPerModule() public {
    (IActionVerifier.Action[] memory actions, bytes[] memory signatures) =
      _spotActions(address(wrappedQuoteTrade), true, TRADE_AMOUNT, CNGN_PRICE, 0, 0);
    _verifyAndMatch(actions, signatures, _orderData(TRADE_AMOUNT, CNGN_PRICE, 0, 0));

    assertEq(wrappedQuoteTrade.filled(cam, 1), TRADE_AMOUNT);
    assertEq(cashQuoteTrade.filled(cam, 1), 0);
    assertEq(wrappedQuoteTrade.seenNonces(cam, 1) == bytes32(0), false);
    assertEq(cashQuoteTrade.seenNonces(cam, 1), bytes32(0));
  }
}
