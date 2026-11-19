// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {Matching} from "src/Matching.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {BookTakeModule} from "src/modules/BookTakeModule.sol";
import {IBookTakeModule, IOnchainBookTake} from "src/interfaces/IBookTakeModule.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {DeployBookTakeModule} from "../../scripts/deploy-book-take-module.s.sol";

interface ICashDeposit {
  function deposit(uint recipientAccount, uint stableAmount) external;
}

/**
 * deploy-book-take-module.s.sol against Base: its preconditions, its exact deploy and postconditions, the vault batch
 * it emits (inert before it, live after it), then a signed take on each of the two books it allows. Pinned to a block
 * where both makers quote. Requires BASE_RPC_URL; skips without it.
 */
contract DeployBookTakeModuleForkTest is Test {
  uint constant FORK_BLOCK = 59_324_790;
  Matching constant matching = Matching(0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191);
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant EURC_BOOK = 0x83C5741a24d57189379E1215F7A22d9f048E89d5;
  address constant CNGN_BOOK = 0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4;
  address constant CASH = 0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272;
  address constant ENGINE = 0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  DeployBookTakeModule script;
  BookTakeModule module;
  ISubAccounts subAccounts;
  uint userPk = 0xB00C;
  address user;
  uint acc;
  uint nonce;

  function setUp() public {
    string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc, FORK_BLOCK);
    subAccounts = matching.subAccounts();
    script = new DeployBookTakeModule();
    script.loadAndCheck();
    module = script.deploy();

    user = vm.addr(userPk);
    deal(USDC, user, 1_000e6);
    vm.startPrank(user);
    acc = subAccounts.createAccount(user, IManager(ENGINE));
    IERC20(USDC).approve(CASH, 1_000e6);
    ICashDeposit(CASH).deposit(acc, 1_000e6);
    subAccounts.approve(address(matching), acc);
    matching.depositSubAccount(acc);
    vm.stopPrank();

    vm.prank(IOwnableLike(address(matching)).owner());
    matching.setTradeExecutor(address(this), true);
  }

  function _runBatch() internal {
    (address[] memory to, bytes[] memory data) = script.vaultActions(module);
    for (uint i; i < to.length; ++i) {
      vm.prank(VAULT);
      (bool ok, bytes memory ret) = to[i].call(data[i]);
      if (!ok) {
        assembly {
          revert(add(ret, 32), mload(ret))
        }
      }
    }
  }

  function _take(address book, uint limitPrice, bytes memory err) internal {
    IBookTakeModule.BookTakeData memory d = IBookTakeModule.BookTakeData({
      book: book,
      marketId: 1,
      isBuy: true,
      amount: 1e18,
      limitPrice: limitPrice,
      minFill: 1e18,
      maxFee: 5e18,
      deadline: uint64(block.timestamp + 60),
      maxLevels: 255,
      reduceOnly: false
    });
    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](1);
    actions[0] = IActionVerifier.Action({
      subaccountId: acc,
      nonce: ++nonce,
      module: IMatchingModule(address(module)),
      data: abi.encode(d),
      expiry: block.timestamp + 600,
      owner: user,
      signer: user
    });
    bytes[] memory sigs = new bytes[](1);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(userPk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(actions[0])));
    sigs[0] = bytes.concat(r, s, bytes1(v));
    if (err.length > 0) vm.expectRevert(err);
    matching.verifyAndMatch(actions, sigs, "");
  }

  function testThePostconditionsHold() public view {
    script.assertDeployment(module, address(script));
    assertEq(module.pendingOwner(), VAULT);
  }

  /// Inert until the batch: Matching refuses the module. After it, the vault owns the module and a take fills on each book.
  function testTheBatchTurnsItOnAndBothBooksFill() public {
    _take(CNGN_BOOK, 0.0007e18, abi.encodeWithSignature("M_OnlyAllowedModule()"));

    _runBatch();
    assertEq(module.owner(), VAULT);
    assertTrue(matching.allowedModules(address(module)));

    _take(CNGN_BOOK, 0.0007e18, "");
    _take(EURC_BOOK, 1.2e18, "");
    (address cngnFuture,, uint96 cngnSub,,,,,,,,,,) = _series(CNGN_BOOK);
    (address eurcFuture,, uint96 eurcSub,,,,,,,,,,) = _series(EURC_BOOK);
    assertEq(subAccounts.getBalance(acc, IAsset(cngnFuture), cngnSub), 1e18);
    assertEq(subAccounts.getBalance(acc, IAsset(eurcFuture), eurcSub), 1e18);
    assertEq(subAccounts.ownerOf(acc), address(matching));
  }

  function _series(address book)
    internal
    view
    returns (address, address, uint96, uint64, uint64, address, uint, uint, uint, uint32, uint32, uint16, bool)
  {
    IOnchainBookTake.MarketView memory m = IOnchainBookTake(book).markets(1);
    return (
      m.future,
      m.engine,
      m.subId,
      m.expiry,
      m.lastTradeTime,
      m.adapter,
      m.tickSize,
      m.lotSize,
      m.takerFeeRate,
      m.takeMaxAge,
      m.maxTtl,
      m.maxMakers,
      m.enabled
    );
  }
}

interface IOwnableLike {
  function owner() external view returns (address);
}
