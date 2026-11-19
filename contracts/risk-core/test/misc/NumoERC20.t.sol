// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "openzeppelin/access/Ownable.sol";

import {NumoERC20, Ownable} from "../../src/l2/NumoERC20.sol";

contract UNIT_NumoERC20_Test is Test {
  NumoERC20 public usdc;

  function setUp() public {
    usdc = new NumoERC20("USDC", "USDC", 6);
  }

  function testConfigureMinter() public {
    usdc.configureMinter(address(this), true);
    assertTrue(usdc.minters(address(this)));
    usdc.configureMinter(address(this), false);
    assertFalse(usdc.minters(address(this)));
  }

  function testMintAndBurn() public {
    usdc.configureMinter(address(this), true);
    usdc.mint(address(this), 100);
    assertEq(usdc.balanceOf(address(this)), 100);

    usdc.burn(address(this), 50);
    assertEq(usdc.balanceOf(address(this)), 50);
  }

  function testCanOnlyConfigureMinterByOwner() public {
    vm.prank(address(0xaa));
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xaa)));
    usdc.configureMinter(address(this), true);
  }

  function testCanOnlyMintByMinter() public {
    vm.prank(address(0xaa));
    vm.expectRevert(NumoERC20.OnlyMinter.selector);
    usdc.mint(address(this), 100);
  }

  function testDecimals() public {
    assertEq(usdc.decimals(), 6);
  }
}
