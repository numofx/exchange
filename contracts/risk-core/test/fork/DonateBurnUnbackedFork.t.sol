// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface ICashLike {
  function donateBalance(uint accountId, uint amount) external returns (uint burntAmount);
  function totalSupply() external view returns (uint);
  function totalBorrow() external view returns (uint);
  function netSettledCash() external view returns (int);
  function accruedSmFees() external view returns (uint);
}

interface IERC20Like {
  function balanceOf(address) external view returns (uint);
}

interface ISubAccountsLike {
  function ownerOf(uint) external view returns (address);
  function getBalance(uint accountId, address asset, uint subId) external view returns (int);
}

/**
 * Does donateBalance(14, type(uint).max) retire the printed cash?
 *
 * CashAsset measures insolvency as _getTotalCash() - stableBalance, where
 *
 *     _getTotalCash() = totalSupply + accruedSmFees - totalBorrow - netSettledCash
 *
 * netSettledCash is SUBTRACTED. Manager-printed cash is recorded there precisely so the contract
 * does not treat it as cash requiring backing, so it is excluded from the very quantity
 * donateBalance burns against.
 */
contract DonateBurnUnbackedFork is Test {
  address constant CASH = 0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant SUB_ACCOUNTS = 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843;
  uint constant ACCT = 14;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
  }

  function testDonateMaxFromTheAccountOwner() public {
    address owner = ISubAccountsLike(SUB_ACCOUNTS).ownerOf(ACCT);
    int before = ISubAccountsLike(SUB_ACCOUNTS).getBalance(ACCT, CASH, 0);

    emit log_named_address("account 14 owner", owner);
    emit log_named_int("cash balance before", before);
    emit log_named_uint("totalSupply    ", ICashLike(CASH).totalSupply());
    emit log_named_int("netSettledCash ", ICashLike(CASH).netSettledCash());
    emit log_named_uint("USDC held      ", IERC20Like(USDC).balanceOf(CASH));

    vm.prank(owner);
    uint burnt = ICashLike(CASH).donateBalance(ACCT, type(uint).max);

    emit log_named_uint("burntAmount", burnt);
    emit log_named_int("cash balance after", ISubAccountsLike(SUB_ACCOUNTS).getBalance(ACCT, CASH, 0));

    // The invariant PR #33 checks, restated as CashAsset itself defines backing.
    uint held18 = IERC20Like(USDC).balanceOf(CASH) * 1e12;
    uint required = ICashLike(CASH).totalSupply() - ICashLike(CASH).totalBorrow();
    emit log_named_uint("USDC held (18dp)", held18);
    emit log_named_uint("totalSupply - totalBorrow", required);
    emit log_named_string(
      "held >= totalSupply - totalBorrow ?", held18 >= required ? "YES" : "NO"
    );
  }
}
