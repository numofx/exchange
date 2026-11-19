// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {Matching} from "src/Matching.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {IBaseModule} from "src/interfaces/IBaseModule.sol";
import {BookTakeModule} from "src/modules/BookTakeModule.sol";
import {IBookTakeModule} from "src/interfaces/IBookTakeModule.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";

interface IOwnable {
  function owner() external view returns (address);
}

interface ICashDeposit {
  function deposit(uint recipientAccount, uint stableAmount) external;
}

/**
 * BookTakeModule through the live Matching on Base, against the live cNGN OnchainBook (cNGN-30NOV26, market 1) and
 * its maker #60: a user's account held by Matching takes with a signature alone, the executor submitting it. Pinned
 * to a block where the maker quotes (2026-11-19 02:28:53 UTC). Requires BASE_RPC_URL; skips without it.
 */
contract BookTakeModuleForkTest is Test {
  uint constant FORK_BLOCK = 59_324_790;

  Matching constant matching = Matching(0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191);
  address constant BOOK = 0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4;
  address constant OTHER_BOOK = 0x83C5741a24d57189379E1215F7A22d9f048E89d5; // EURC-30NOV26's, not allowed here
  address constant CASH = 0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272;
  address constant ENGINE = 0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  IAsset constant FUTURE = IAsset(0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75);
  uint constant SUB_ID = 1796047200;
  uint constant CONTRACT = 1e18;

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
    user = vm.addr(userPk);

    module = new BookTakeModule(matching);
    module.setBookAllowed(BOOK, true);
    vm.startPrank(IOwnable(address(matching)).owner());
    matching.setAllowedModule(address(module), true);
    matching.setTradeExecutor(address(this), true);
    vm.stopPrank();

    // A user's account as the venue holds it: under the MarginEngine, 1,000 USDC, deposited into Matching.
    deal(USDC, user, 1_000e6);
    vm.startPrank(user);
    acc = subAccounts.createAccount(user, IManager(ENGINE));
    IERC20(USDC).approve(CASH, 1_000e6);
    ICashDeposit(CASH).deposit(acc, 1_000e6);
    subAccounts.approve(address(matching), acc);
    matching.depositSubAccount(acc);
    vm.stopPrank();
  }

  function _take(address book, bool isBuy, uint amount, uint limitPrice, uint maxFee, bool reduceOnly, bytes4 err)
    internal
  {
    IBookTakeModule.BookTakeData memory data = IBookTakeModule.BookTakeData({
      book: book,
      marketId: 1,
      isBuy: isBuy,
      amount: amount,
      limitPrice: limitPrice,
      minFill: amount,
      maxFee: maxFee,
      deadline: uint64(block.timestamp + 60),
      maxLevels: 255,
      reduceOnly: reduceOnly
    });
    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](1);
    actions[0] = IActionVerifier.Action({
      subaccountId: acc,
      nonce: ++nonce,
      module: IMatchingModule(address(module)),
      data: abi.encode(data),
      expiry: block.timestamp + 600,
      owner: user,
      signer: user
    });
    bytes[] memory signatures = new bytes[](1);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(userPk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(actions[0])));
    signatures[0] = bytes.concat(r, s, bytes1(v));
    if (err != bytes4(0)) vm.expectRevert(err);
    matching.verifyAndMatch(actions, signatures, "");
  }

  function _position() internal view returns (int) {
    return subAccounts.getBalance(acc, FUTURE, SUB_ID);
  }

  function _cash() internal view returns (int) {
    return subAccounts.getBalance(acc, IAsset(CASH), 0);
  }

  /// One contract bought with a signature: the position lands, the fee is paid in cash, Matching holds the account again.
  function testASignedTakeFillsAndReturnsTheAccount() public {
    int cashBefore = _cash();
    _take(BOOK, true, CONTRACT, 0.0007e18, 2e18, false, bytes4(0));
    assertEq(_position(), int(CONTRACT));
    // The fee (15 bps of ~688 USDC, ~1.03), plus the fill's variation margin against the mark, settled at once.
    int paid = cashBefore - _cash();
    assertGt(paid, 1e18, "at least the fee");
    assertLt(paid, 10e18, "the fee and the gap to the mark, nothing like a contract's notional");
    assertEq(subAccounts.ownerOf(acc), address(matching));
    assertEq(matching.subAccountToOwner(acc), user);
  }

  function testABookNotAllowedIsRefused() public {
    _take(OTHER_BOOK, true, CONTRACT, 2e18, 2e18, false, IBookTakeModule.BTM_BookNotAllowed.selector);
  }

  /// reduceOnly cuts a close to the position, and refuses one on the position's own side.
  function testReduceOnlyClosesNoMoreThanThePosition() public {
    _take(BOOK, true, CONTRACT, 0.0007e18, 2e18, false, bytes4(0));
    _take(BOOK, true, CONTRACT, 0.0007e18, 2e18, true, IBookTakeModule.BTM_NotReducing.selector);
    _take(BOOK, false, 3 * CONTRACT, 0.00067e18, 2e18, true, bytes4(0));
    assertEq(_position(), 0, "sold one contract, not three");
  }

  function testReduceOnlyNeedsAPosition() public {
    _take(BOOK, false, CONTRACT, 0.00067e18, 2e18, true, IBookTakeModule.BTM_NotReducing.selector);
  }

  /// A signed take runs once: the same nonce again is refused.
  function testANonceCannotBeReplayed() public {
    _take(BOOK, true, CONTRACT, 0.0007e18, 2e18, false, bytes4(0));
    nonce--;
    _take(BOOK, true, CONTRACT, 0.0007e18, 2e18, false, IBaseModule.BM_NonceAlreadyUsed.selector);
  }

  /// The signed fee bound holds: a take that would charge more reverts, and nothing moves.
  function testTheMaxFeeBinds() public {
    _take(BOOK, true, CONTRACT, 0.0007e18, 0.5e18, false, bytes4(keccak256("OB_FeeTooHigh()")));
    assertEq(_position(), 0);
  }

  /// Only the owner allows a book.
  function testOnlyTheOwnerAllowsABook() public {
    vm.prank(user);
    vm.expectRevert();
    module.setBookAllowed(OTHER_BOOK, true);
  }
}
