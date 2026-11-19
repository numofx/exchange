// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {BookCustodian, ICustodianAsset} from "../../src/periphery/BookCustodian.sol";
import {DeployBookCustodian} from "../../scripts/deploy-book-custodian.s.sol";

/**
 * deploy-book-custodian.s.sol's exact sequence at head: the preconditions it checks hold on chain, the deployment
 * passes its own assertions, and the deployed custodian opens, funds and returns an account under engine v2.
 * At head because it checks what is deployed now. Requires BASE_RPC_URL.
 */
contract DeployBookCustodianFork is Test {
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  function testTheScriptDeploysAWorkingCustodian() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    DeployBookCustodian script = new DeployBookCustodian();
    script.loadAndCheck();
    BookCustodian c = script.deploy();
    script.assertDeployment(c);

    (BookCustodian.Kind[] memory kinds, address[] memory targets) = script.initialAllowlist();
    assertEq(kinds.length, 5, "engine, two books, two assets");
    assertEq(c.owner(), VAULT);

    address wallet = makeAddr("deploy check wallet");
    deal(USDC, wallet, 100e6);
    vm.startPrank(wallet);
    uint id = c.openAccount(wallet, IManager(targets[0]));
    IERC20(USDC).approve(address(c), 100e6);
    c.deposit(id, ICustodianAsset(address(c.cash())), 100e6);
    c.withdraw(id, ICustodianAsset(address(c.cash())), 40e6);
    c.exit(id);
    vm.stopPrank();
    ISubAccounts sa = c.subAccounts();
    assertEq(sa.ownerOf(id), wallet);
    assertEq(sa.getBalance(id, c.cash(), 0), 60e18);
    assertEq(IERC20(USDC).balanceOf(wallet), 40e6);
  }
}
