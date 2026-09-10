// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface ICashLike {
  function owner() external view returns (address);
  function setWhitelistManager(address manager, bool whitelisted) external;
  function whitelistedManager(address) external view returns (bool);
  function withdraw(uint accountId, uint amount, address recipient) external;
  function deposit(uint recipientAccount, uint amount) external;
  function donateBalance(uint accountId, uint amount) external returns (uint);
}

interface IERC20Like {
  function approve(address, uint) external returns (bool);
  function balanceOf(address) external view returns (uint);
}

interface ISubAccountsLike {
  function ownerOf(uint) external view returns (address);
  function getBalance(uint accountId, address asset, uint subId) external view returns (int);

  struct AssetBalance {
    address asset;
    uint subId;
    int balance;
  }

  function getAccountBalances(uint accountId) external view returns (AssetBalance[] memory);
}

/**
 * The single vault action that stops the settled cash on subaccount 14 being withdrawn against:
 *
 *     cash.setWhitelistManager(DeliverableFXManager, false)
 *
 * CashAsset.handleAdjustment calls _checkManager(manager), so every cash movement on a
 * DFXM-managed account reverts MW_UnknownManager.
 *
 * Why it matters: CashAsset is shared across managers with no per-manager segregation, so USDC
 * deposited for SRM or market-maker use lands in the same contract subaccount 14 can draw on.
 * Only 2.000001 USDC sits there today, which is the sole reason nothing has moved.
 */
contract FreezeDFXMCashFork is Test {
  address constant CASH = 0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  address constant DFXM = 0xcE01f3D74400caE39bd7608cd2d286C2e3874d49;
  address constant SRM = 0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b;

  uint constant ACCT = 14;
  uint constant SRM_ACCT = 16;

  bytes constant ACTION =
    hex"e64cc9da000000000000000000000000ce01f3d74400cae39bd7608cd2d286c2e3874d490000000000000000000000000000000000000000000000000000000000000000";

  /// Last block before the freeze itself landed (tx 0x13e15eca..., block 51109818).
  uint constant PRE_FREEZE_BLOCK = 51109817;

  function setUp() public {
    // Pinned. These tests are about what the action DOES, which can only be observed from the
    // world it acted on: at head DFXM is already de-whitelisted, so "without the freeze" has no
    // meaning and applying it again is a no-op. testTheFreezeHasLandedOnChain below is the
    // head-forked half, asserting the result rather than the transition.
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), PRE_FREEZE_BLOCK);
  }

  /// The post-state, at head. Pairs with the pinned tests above: they show what the action did,
  /// this shows that it is in force. If someone re-whitelists DFXM, this goes red.
  function testTheFreezeHasLandedOnChain() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    assertFalse(ICashLike(CASH).whitelistedManager(DFXM), "DFXM must be de-whitelisted at head");
    assertTrue(ICashLike(CASH).whitelistedManager(SRM), "SRM must remain whitelisted");

    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    deal(USDC, CASH, 5_000e6);
    vm.prank(owner);
    vm.expectRevert(); // MW_UnknownManager
    ICashLike(CASH).withdraw(ACCT, 5_000e6, owner);
  }

  function _freeze() internal {
    vm.prank(ICashLike(CASH).owner());
    (bool ok,) = CASH.call(ACTION);
    require(ok, "freeze action reverted");
  }

  /// The premise. Without the freeze, any USDC that arrives is withdrawable against account 14.
  function testWithoutTheFreezeAnyDepositedUsdcIsWithdrawable() public {
    deal(USDC, CASH, 5_000e6);
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    uint before = IERC20Like(USDC).balanceOf(owner);

    vm.prank(owner);
    ICashLike(CASH).withdraw(ACCT, 5_000e6, owner);

    assertEq(IERC20Like(USDC).balanceOf(owner) - before, 5_000e6, "settled cash drew real deposits");
  }

  function testTheFreezeStopsIt() public {
    _freeze();
    deal(USDC, CASH, 5_000e6);
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    vm.prank(owner);
    vm.expectRevert(); // MW_UnknownManager
    ICashLike(CASH).withdraw(ACCT, 5_000e6, owner);
  }

  function testTheFreezeLeavesTheSrmCashPathWorking() public {
    _freeze();
    assertTrue(ICashLike(CASH).whitelistedManager(SRM), "SRM must stay whitelisted");
    assertFalse(ICashLike(CASH).whitelistedManager(DFXM), "DFXM must be de-whitelisted");

    deal(USDC, address(this), 10e6);
    IERC20Like(USDC).approve(CASH, type(uint).max);
    int before = ISubAccountsLike(SUB_ACCOUNTS).getBalance(SRM_ACCT, CASH, 0);
    ICashLike(CASH).deposit(SRM_ACCT, 10e6);
    assertEq(
      ISubAccountsLike(SUB_ACCOUNTS).getBalance(SRM_ACCT, CASH, 0) - before, 10e18, "SRM deposits must still settle"
    );
  }

  /// The freeze blocks the repair as well as the drain: donateBalance routes through
  /// handleAdjustment -> _checkManager, and updateSettledCash checks msg.sender the same way.
  /// So a burn, if one is ever found, needs re-whitelist -> burn -> re-freeze.
  function testTheFreezeAlsoBlocksAnyFutureBurnUntilReversed() public {
    _freeze();
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    vm.prank(owner);
    vm.expectRevert();
    ICashLike(CASH).donateBalance(ACCT, type(uint).max);
  }

  /// ...and it is reversible by the same owner call, which is what makes signing it tonight
  /// safe rather than final.
  function testTheFreezeIsReversible() public {
    _freeze();
    assertFalse(ICashLike(CASH).whitelistedManager(DFXM));

    vm.prank(ICashLike(CASH).owner());
    ICashLike(CASH).setWhitelistManager(DFXM, true);
    assertTrue(ICashLike(CASH).whitelistedManager(DFXM), "the vault can re-enable DFXM");

    // and once re-enabled the (zero-burning) donate path is reachable again
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    vm.prank(owner);
    assertEq(ICashLike(CASH).donateBalance(ACCT, type(uint).max), 0, "donate still burns nothing");
  }

  /// Account 14 holds cash and nothing else. That is why no DFXM settlement path can retire the
  /// balance: updateSettledCash has exactly one caller, BaseManager._applyCashDelta, which is
  /// internal and only reached by settling a POSITION. No position, no cash delta, no burn.
  function testAccountFourteenHoldsOnlyCashSoNoSettlementCanRetireIt() public view {
    ISubAccountsLike.AssetBalance[] memory held = ISubAccountsLike(SUB_ACCOUNTS).getAccountBalances(ACCT);
    assertEq(held.length, 1, "account 14 must hold exactly one asset");
    assertEq(held[0].asset, CASH, "and it must be the cash asset");
    assertGt(held[0].balance, 0, "with a positive balance");
  }
}
