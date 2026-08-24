// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import "lyra-utils/encoding/OptionEncoding.sol";

import "../shared/IntegrationTestBase.t.sol";

/**
 * @dev the USDC/cNGN spot venue trades a WrappedERC20Asset against internal cash under the SRM,
 *      with the base asset's margin factor set to 0. These tests pin down what that config buys:
 *      cash is the only thing that can fund a buy, and the wrapped asset cannot go short.
 *      "wbtc" here stands in for wrapped cNGN — same asset contract, same SRM base-asset path.
 */
contract INTEGRATION_SRM_BaseAsset is IntegrationTestBase {
  using DecimalMath for uint;

  uint constant SPOT = 25000e18;

  function setUp() public {
    _setupIntegrationTestComplete();

    // add cash into the system
    _depositCash(alice, aliceAcc, DEFAULT_DEPOSIT);

    _setSpotPrice("wbtc", uint96(SPOT), 1e18);
    _depositBase("wbtc", bob, bobAcc, 1e18);
  }

  // example of using the test setup
  function testCanBorrowAgainstBase() public {
    srm.setBorrowingEnabled(true);
    srm.setBaseAssetMarginFactor(markets["wbtc"].id, 0.5e18, 1e18);

    _withdrawCash(bob, bobAcc, DEFAULT_DEPOSIT);

    assertEq(getCashBalance(bobAcc), -int(DEFAULT_DEPOSIT));
  }

  /// @dev margin factor 0 blocks the borrow that 0.5e18 allows, even with borrowing enabled globally
  function testZeroMarginFactorBlocksBorrowAgainstBase() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    vm.startPrank(bob);
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    cash.withdraw(bobAcc, DEFAULT_DEPOSIT / 1e12, bob);
    vm.stopPrank();
  }

  /// @dev buy leg: cash out, base in. Funded by cash on hand, so it settles.
  function testFundedSpotBuySettles() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    // alice pays 2500 cash for 0.1 wbtc
    _submitTrade(bobAcc, markets["wbtc"].base, 0, 0.1e18, aliceAcc, cash, 0, 2500e18);

    assertEq(getCashBalance(aliceAcc), int(DEFAULT_DEPOSIT) - 2500e18);
    assertEq(getCashBalance(bobAcc), 2500e18);
    assertEq(_baseBalance(aliceAcc), 0.1e18);
    assertEq(_baseBalance(bobAcc), 0.9e18);
  }

  /// @dev buy leg beyond cash on hand: the base being bought gives no margin credit, so it reverts
  function testUnfundedSpotBuyReverts() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    // alice holds 5000 cash and tries to pay 7500 for 0.3 wbtc
    vm.expectRevert(IStandardManager.SRM_PortfolioBelowMargin.selector);
    _submitTrade(bobAcc, markets["wbtc"].base, 0, 0.3e18, aliceAcc, cash, 0, 7500e18);
  }

  /// @dev with borrowing disabled the same trade is stopped one step earlier, by the cash rail itself
  function testUnfundedSpotBuyRevertsWithBorrowingDisabled() public {
    srm.setBorrowingEnabled(false);
    _setZeroMarginFactor();

    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _submitTrade(bobAcc, markets["wbtc"].base, 0, 0.3e18, aliceAcc, cash, 0, 7500e18);
  }

  /// @dev sell leg: base out, cash in. Works from a cash-free account — zero margin credit is not a lock-up.
  function testSellingBaseFromCashFreeAccountSettles() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    assertEq(getCashBalance(bobAcc), 0);

    // bob sells 0.1 wbtc to alice for 2500 cash
    _submitTrade(bobAcc, markets["wbtc"].base, 0, 0.1e18, aliceAcc, cash, 0, 2500e18);

    assertEq(_baseBalance(bobAcc), 0.9e18);
    assertEq(getCashBalance(bobAcc), 2500e18);
  }

  /// @dev sell leg beyond inventory: the wrapped asset itself refuses to go negative, so there is no short side
  function testSellingMoreBaseThanHeldReverts() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    // bob holds 1 wbtc and tries to sell 2
    vm.expectRevert(IWrappedERC20Asset.WERC_CannotBeNegative.selector);
    _submitTrade(bobAcc, markets["wbtc"].base, 0, 2e18, aliceAcc, cash, 0, 50000e18);
  }

  /// @dev withdrawing the base is also gated by cash only, so a cash-free holder can always exit
  function testCanWithdrawBaseWithNoCash() public {
    srm.setBorrowingEnabled(true);
    _setZeroMarginFactor();

    vm.startPrank(bob);
    markets["wbtc"].base.withdraw(bobAcc, 1e18, bob);
    vm.stopPrank();

    assertEq(_baseBalance(bobAcc), 0);
  }

  function _setZeroMarginFactor() internal {
    srm.setBaseAssetMarginFactor(markets["wbtc"].id, 0, 0);
  }

  function _baseBalance(uint acc) internal view returns (int) {
    return subAccounts.getBalance(acc, markets["wbtc"].base, 0);
  }
}
