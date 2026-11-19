// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {
  BookCustodian,
  ICustodianAsset,
  ICustodianBook,
  IBookCustodianModule
} from "../../src/periphery/BookCustodian.sol";

interface IMatchingAccounts {
  function subAccounts() external view returns (ISubAccounts);
  function depositSubAccount(uint accountId) external;
  function requestWithdrawAccount(uint accountId) external;
  function completeWithdrawAccount(uint accountId) external;
}

/// @dev A book the owner was tricked into allowing: it tries to walk off with an account it is approved on.
contract ThievingBook {
  ISubAccounts immutable subAccounts;
  uint public victim;

  constructor(ISubAccounts s) {
    subAccounts = s;
  }

  function setVictim(uint v) external {
    victim = v;
  }

  function take(ICustodianBook.TakeOrder calldata o, bytes calldata) external returns (uint, uint) {
    // another account the custodian holds, if one is named; else the taker itself
    uint target = victim == 0 ? o.takerAccountId : victim;
    subAccounts.transferFrom(msg.sender, address(this), target);
    return (0, 0);
  }
}

contract ThievingModule is IBookCustodianModule {
  ISubAccounts immutable subAccounts;

  constructor(ISubAccounts s) {
    subAccounts = s;
  }

  function onAct(uint accountId, address, bytes calldata data) external {
    uint target = data.length == 0 ? accountId : abi.decode(data, (uint));
    subAccounts.transferFrom(msg.sender, address(this), target);
  }
}

/// @dev A module that does nothing harmful: records what it was given.
contract RecordingModule is IBookCustodianModule {
  uint public lastAccount;
  address public lastWallet;
  bytes public lastData;

  function onAct(uint accountId, address wallet, bytes calldata data) external {
    lastAccount = accountId;
    lastWallet = wallet;
    lastData = data;
  }
}

/// @dev A smart wallet: valid signatures are its owner key's.
contract SmartWallet is IERC1271 {
  address immutable signer;

  constructor(address s) {
    signer = s;
  }

  function isValidSignature(bytes32 digest, bytes memory sig) external view returns (bytes4) {
    return ECDSA.recover(digest, sig) == signer ? IERC1271.isValidSignature.selector : bytes4(0);
  }
}

/**
 * BookCustodian (docs/book-custodian-spec.md) on Base against the live SubAccounts, MarginEngine v2, cash, the cNGN
 * OnchainBook (cNGN-30NOV26, market 1, maker #60 quoting) and Matching. Pinned where the maker quotes, as
 * BookTakeModuleForkTest is (2026-11-19 02:28:53 UTC). Each guarantee in the spec is a test here.
 */
contract BookCustodianFork is Test {
  uint constant FORK_BLOCK = 59_324_790;

  IMatchingAccounts constant MATCHING = IMatchingAccounts(0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191);
  address constant BOOK = 0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4;
  address constant EURC_BOOK = 0x83C5741a24d57189379E1215F7A22d9f048E89d5;
  ICustodianAsset constant CASH = ICustodianAsset(0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272);
  IManager constant ENGINE = IManager(0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950);
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  IAsset constant FUTURE = IAsset(0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75);
  uint constant SUB_ID = 1796047200;
  uint constant CONTRACT = 1e18;
  uint constant BUY_LIMIT = 0.0007e18;
  uint constant SELL_LIMIT = 0.0006e18;

  BookCustodian custodian;
  ISubAccounts subAccounts;
  address vault = address(0xA11CE);
  // Keys hashed from labels: short keys map to addresses that carry code on Base (EIP-7702 delegations), and code
  // turns every signature check into EIP-1271.
  address relayer = makeAddr("custodian relayer");
  uint walletPk = uint(keccak256("custodian wallet"));
  uint keyPk = uint(keccak256("custodian trading key"));
  uint otherPk = uint(keccak256("custodian other wallet"));
  address wallet;
  address key;
  address other;
  uint acc;
  uint nonce;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    subAccounts = MATCHING.subAccounts();
    wallet = vm.addr(walletPk);
    key = vm.addr(keyPk);
    other = vm.addr(otherPk);

    BookCustodian.Kind[] memory kinds = new BookCustodian.Kind[](3);
    address[] memory targets = new address[](3);
    (kinds[0], targets[0]) = (BookCustodian.Kind.Manager, address(ENGINE));
    (kinds[1], targets[1]) = (BookCustodian.Kind.Asset, address(CASH));
    (kinds[2], targets[2]) = (BookCustodian.Kind.Book, BOOK);
    custodian = new BookCustodian(subAccounts, vault, kinds, targets);

    acc = _openFunded(wallet, walletPk, 1_000e6);
  }

  ///////////////
  // Helpers   //
  ///////////////

  function _sign(uint pk, bytes32 structHash) internal view returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(custodian.domainSeparator(), structHash));
    return bytes.concat(r, s, bytes1(v));
  }

  /// A gasless start: the relayer opens the account and deposits with the wallet's USDC permit.
  function _openFunded(address w, uint pk, uint usdc) internal returns (uint id) {
    deal(USDC, w, usdc);
    vm.startPrank(relayer);
    id = custodian.openAccount(w, ENGINE);
    (uint8 v, bytes32 r, bytes32 s) = _permit(w, pk, usdc);
    custodian.depositWithPermit(id, CASH, usdc, block.timestamp + 600, v, r, s);
    vm.stopPrank();
  }

  function _permit(address owner_, uint pk, uint value) internal view returns (uint8, bytes32, bytes32) {
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        owner_,
        address(custodian),
        value,
        IERC20Permit(USDC).nonces(owner_),
        block.timestamp + 600
      )
    );
    return vm.sign(pk, MessageHashUtils.toTypedDataHash(IERC20Permit(USDC).DOMAIN_SEPARATOR(), structHash));
  }

  function _order(uint id, address book, bool isBuy, uint amount, bool reduceOnly)
    internal
    returns (BookCustodian.Take memory)
  {
    return BookCustodian.Take({
      accountId: id,
      book: book,
      marketId: 1,
      isBuy: isBuy,
      amount: amount,
      limitPrice: isBuy ? BUY_LIMIT : SELL_LIMIT,
      minFill: amount,
      maxFee: 2e18,
      deadline: uint64(block.timestamp + 60),
      maxLevels: 255,
      reduceOnly: reduceOnly,
      nonce: ++nonce
    });
  }

  function _takeHash(BookCustodian.Take memory t) internal view returns (bytes32) {
    return keccak256(abi.encode(custodian.TAKE_TYPEHASH(), t));
  }

  function _take(BookCustodian.Take memory t, uint pk) internal returns (uint filled) {
    vm.prank(relayer);
    (filled,) = custodian.take(t, _sign(pk, _takeHash(t)));
  }

  function _position(uint id) internal view returns (int) {
    return subAccounts.getBalance(id, FUTURE, SUB_ID);
  }

  function _cash(uint id) internal view returns (int) {
    return subAccounts.getBalance(id, IAsset(address(CASH)), 0);
  }

  function _setKey(uint64 validUntil) internal {
    vm.prank(wallet);
    custodian.setTradingKey(key, validUntil);
  }

  ////////////////////////////
  // Accounts and deposits  //
  ////////////////////////////

  function testGaslessOpenAndPermitDeposit() public view {
    assertEq(custodian.accountOwner(acc), wallet);
    assertEq(subAccounts.ownerOf(acc), address(custodian));
    assertEq(_cash(acc), 1_000e18);
    assertEq(IERC20(USDC).balanceOf(address(custodian)), 0, "the custodian keeps no tokens");
  }

  /// A relayer pairing the wallet's permit with an asset nobody allowed (one that would keep the tokens) is refused.
  function testADepositAssetNotAllowedIsRefused() public {
    deal(USDC, wallet, 10e6);
    (uint8 v, bytes32 r, bytes32 s) = _permit(wallet, walletPk, 10e6);
    vm.prank(relayer);
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.depositWithPermit(acc, ICustodianAsset(address(0xBAD)), 10e6, block.timestamp + 600, v, r, s);
  }

  function testAnAccountUnderAManagerNotAllowedIsRefused() public {
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.openAccount(wallet, IManager(address(0x1234)));

    vm.startPrank(wallet);
    uint own = subAccounts.createAccount(wallet, IManager(address(0x1234)));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    subAccounts.safeTransferFrom(wallet, address(custodian), own);
    vm.stopPrank();
  }

  function testOnlySubAccountsMayRecordADeposit() public {
    vm.expectRevert(BookCustodian.BC_NotSubAccounts.selector);
    custodian.onERC721Received(address(this), other, acc, "");
  }

  /////////////
  // Trading //
  /////////////

  /// A signed take fills; the account stays here; the book keeps no approval of any kind afterwards.
  function testAWalletSignedTakeFills() public {
    int cashBefore = _cash(acc);
    assertEq(_take(_order(acc, BOOK, true, CONTRACT, false), walletPk), CONTRACT);
    assertEq(_position(acc), int(CONTRACT));
    assertGt(cashBefore - _cash(acc), 1e18, "paid at least the fee");
    assertEq(subAccounts.ownerOf(acc), address(custodian));
    assertEq(subAccounts.getApproved(acc), address(0), "no approval left on the account");
    assertFalse(subAccounts.isApprovedForAll(address(custodian), BOOK), "no standing approval");
  }

  function testATradingKeyTakesUntilItExpiresOrIsRevoked() public {
    _setKey(uint64(block.timestamp + 1 days));
    assertEq(_take(_order(acc, BOOK, true, CONTRACT, false), keyPk), CONTRACT);

    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(keyPk, _takeHash(t));
    vm.prank(wallet);
    custodian.setTradingKey(address(0), 0);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig);

    _setKey(uint64(block.timestamp + 10));
    t = _order(acc, BOOK, true, CONTRACT, false);
    t.deadline = uint64(block.timestamp + 600);
    sig = _sign(keyPk, _takeHash(t));
    vm.warp(block.timestamp + 11);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig);
  }

  function testASignatureIsUsedOnce() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    custodian.take(t, sig);
    vm.expectRevert(BookCustodian.BC_NonceUsed.selector);
    custodian.take(t, sig);
  }

  function testACancelledNonceCannotBeUsed() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.prank(wallet);
    custodian.cancelNonce(t.nonce);
    vm.expectRevert(BookCustodian.BC_NonceUsed.selector);
    custodian.take(t, sig);
  }

  /// A signature for the wallet's account cannot trade another wallet's account, nor can another wallet's key.
  function testASignatureActsOnlyOnItsOwnAccount() public {
    uint otherAcc = _openFunded(other, otherPk, 1_000e6);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    t.accountId = otherAcc;
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig);

    // the wallet's own key, on the other wallet's account
    _setKey(uint64(block.timestamp + 1 days));
    t = _order(otherAcc, BOOK, true, CONTRACT, false);
    sig = _sign(keyPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig);
  }

  function testAnExpiredTakeIsRefused() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.warp(t.deadline + 1);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.take(t, sig);
  }

  function testReduceOnlyClosesNoMoreThanThePosition() public {
    _take(_order(acc, BOOK, true, CONTRACT, false), walletPk);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, true);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_NotReducing.selector);
    custodian.take(t, sig);

    assertEq(_take(_order(acc, BOOK, false, 3 * CONTRACT, true), walletPk), CONTRACT, "cut to the position");
    assertEq(_position(acc), 0);
  }

  function testPauseStopsTakesOnly() public {
    vm.prank(vault);
    custodian.setPaused(true);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_Paused.selector);
    custodian.take(t, sig);

    vm.startPrank(wallet);
    custodian.withdraw(acc, CASH, 10e6);
    custodian.setTradingKey(key, uint64(block.timestamp + 1));
    custodian.exit(acc);
    vm.stopPrank();
    assertEq(subAccounts.ownerOf(acc), wallet);
  }

  /// An EIP-1271 smart wallet signs a take.
  function testASmartWalletSigns() public {
    SmartWallet sw = new SmartWallet(vm.addr(otherPk));
    deal(USDC, address(sw), 1_000e6);
    vm.startPrank(address(sw));
    uint id = custodian.openAccount(address(sw), ENGINE);
    IERC20(USDC).approve(address(custodian), 1_000e6);
    custodian.deposit(id, CASH, 1_000e6);
    vm.stopPrank();
    assertEq(_take(_order(id, BOOK, true, CONTRACT, false), otherPk), CONTRACT);
  }

  //////////////////////////
  // Books and the delay  //
  //////////////////////////

  function testABookIsUsableOnly48HoursAfterQueueing() public {
    BookCustodian.Take memory t = _order(acc, EURC_BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.take(t, sig);

    vm.startPrank(vault);
    vm.expectRevert(BookCustodian.BC_NotQueued.selector);
    custodian.enable(BookCustodian.Kind.Book, EURC_BOOK);
    custodian.queue(BookCustodian.Kind.Book, EURC_BOOK);
    vm.warp(block.timestamp + 48 hours - 1);
    vm.expectRevert(BookCustodian.BC_TooEarly.selector);
    custodian.enable(BookCustodian.Kind.Book, EURC_BOOK);
    vm.warp(block.timestamp + 1);
    custodian.enable(BookCustodian.Kind.Book, EURC_BOOK);
    vm.stopPrank();
    assertTrue(custodian.allowed(BookCustodian.Kind.Book, EURC_BOOK));
    assertFalse(subAccounts.isApprovedForAll(address(custodian), EURC_BOOK), "allowing approves nothing");
  }

  function testOnlyTheOwnerQueuesAndDisallowingIsImmediate() public {
    vm.expectRevert();
    custodian.queue(BookCustodian.Kind.Book, EURC_BOOK);
    vm.prank(vault);
    custodian.disallow(BookCustodian.Kind.Book, BOOK);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.take(t, sig);
  }

  /// Even an allowed malicious book cannot keep the account it was approved on, nor touch any other.
  function testAnAllowedThievingBookCannotTakeAnAccount() public {
    ThievingBook thief = new ThievingBook(subAccounts);
    vm.startPrank(vault);
    custodian.queue(BookCustodian.Kind.Book, address(thief));
    vm.warp(block.timestamp + 48 hours);
    custodian.enable(BookCustodian.Kind.Book, address(thief));
    vm.stopPrank();

    BookCustodian.Take memory t = _order(acc, address(thief), true, CONTRACT, false);
    t.deadline = uint64(block.timestamp + 60);
    bytes memory sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(BookCustodian.BC_AccountLeft.selector);
    custodian.take(t, sig);

    uint otherAcc = _openFunded(other, otherPk, 1_000e6);
    thief.setVictim(otherAcc);
    t = _order(acc, address(thief), true, CONTRACT, false);
    t.deadline = uint64(block.timestamp + 60);
    sig = _sign(walletPk, _takeHash(t));
    vm.expectRevert(); // SubAccounts: the thief is approved on `acc` only
    custodian.take(t, sig);
    assertEq(subAccounts.ownerOf(acc), address(custodian));
    assertEq(subAccounts.ownerOf(otherAcc), address(custodian));
  }

  //////////////
  // Modules  //
  //////////////

  function _allowModule(address m) internal {
    vm.startPrank(vault);
    custodian.queue(BookCustodian.Kind.Module, m);
    vm.warp(block.timestamp + 48 hours);
    custodian.enable(BookCustodian.Kind.Module, m);
    vm.stopPrank();
  }

  function _actSig(uint pk, uint id, address m, bytes memory data, uint n, uint64 deadline)
    internal
    view
    returns (bytes memory)
  {
    return _sign(pk, keccak256(abi.encode(custodian.ACT_TYPEHASH(), id, m, keccak256(data), n, deadline)));
  }

  function testAModuleActsOnTheSignedAccountOnly() public {
    RecordingModule m = new RecordingModule();
    _allowModule(address(m));
    _setKey(uint64(block.timestamp + 1 days));
    uint64 deadline = uint64(block.timestamp + 60);
    custodian.act(acc, m, hex"c0ffee", 1, deadline, _actSig(keyPk, acc, address(m), hex"c0ffee", 1, deadline));
    assertEq(m.lastAccount(), acc);
    assertEq(m.lastWallet(), wallet);
    assertEq(subAccounts.getApproved(acc), address(0));

    // different data than signed
    bytes memory sig = _actSig(keyPk, acc, address(m), hex"c0ffee", 2, deadline);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.act(acc, m, hex"beef", 2, deadline, sig);
  }

  function testAQueuedModuleHasNoPowerAndAThievingOneCannotKeepTheAccount() public {
    ThievingModule thief = new ThievingModule(subAccounts);
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, acc, address(thief), "", 1, deadline);
    vm.prank(vault);
    custodian.queue(BookCustodian.Kind.Module, address(thief));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.act(acc, thief, "", 1, deadline, sig);

    vm.warp(block.timestamp + 48 hours);
    vm.prank(vault);
    custodian.enable(BookCustodian.Kind.Module, address(thief));
    deadline = uint64(block.timestamp + 60);
    sig = _actSig(walletPk, acc, address(thief), "", 2, deadline);
    vm.expectRevert(BookCustodian.BC_AccountLeft.selector);
    custodian.act(acc, thief, "", 2, deadline, sig);
    assertEq(subAccounts.ownerOf(acc), address(custodian));
  }

  /////////////
  // Leaving //
  /////////////

  function testOnlyTheWalletWithdrawsAndOnlyToItself() public {
    vm.prank(other);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.withdraw(acc, CASH, 10e6);
    vm.prank(vault);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.withdraw(acc, CASH, 10e6);

    uint before = IERC20(USDC).balanceOf(wallet);
    vm.prank(wallet);
    custodian.withdraw(acc, CASH, 10e6);
    assertEq(IERC20(USDC).balanceOf(wallet), before + 10e6);

    // relayed with the wallet's signature: still to the wallet
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig =
      _sign(walletPk, keccak256(abi.encode(custodian.WITHDRAW_TYPEHASH(), acc, address(CASH), 5e6, 7, deadline)));
    vm.prank(relayer);
    custodian.withdrawFor(acc, CASH, 5e6, 7, deadline, sig);
    assertEq(IERC20(USDC).balanceOf(wallet), before + 15e6);
    assertEq(IERC20(USDC).balanceOf(relayer), 0);
  }

  /// A trading key can trade and nothing else: no withdrawal, no exit, no key change.
  function testATradingKeyCannotWithdrawExitOrDelegate() public {
    _setKey(uint64(block.timestamp + 1 days));
    uint64 deadline = uint64(block.timestamp + 60);

    bytes memory sig =
      _sign(keyPk, keccak256(abi.encode(custodian.WITHDRAW_TYPEHASH(), acc, address(CASH), 5e6, 1, deadline)));
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.withdrawFor(acc, CASH, 5e6, 1, deadline, sig);

    sig = _sign(keyPk, keccak256(abi.encode(custodian.EXIT_TYPEHASH(), acc, 2, deadline)));
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.exitFor(acc, 2, deadline, sig);

    sig = _sign(
      keyPk,
      keccak256(abi.encode(custodian.SET_TRADING_KEY_TYPEHASH(), wallet, other, uint64(type(uint64).max), 3, deadline))
    );
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.setTradingKeyFor(wallet, other, type(uint64).max, 3, deadline, sig);

    vm.prank(key);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.withdraw(acc, CASH, 5e6);
    vm.prank(key);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.exit(acc);
  }

  /// Exit with an open position, while paused, with the book and manager disallowed: the account and everything in it
  /// go to the wallet, and nobody else can do it.
  function testExitAlwaysWorks() public {
    _take(_order(acc, BOOK, true, CONTRACT, false), walletPk);
    int cash = _cash(acc);

    vm.startPrank(vault);
    custodian.setPaused(true);
    custodian.disallow(BookCustodian.Kind.Book, BOOK);
    custodian.disallow(BookCustodian.Kind.Manager, address(ENGINE));
    custodian.disallow(BookCustodian.Kind.Asset, address(CASH));
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.exit(acc);
    vm.stopPrank();

    vm.prank(relayer);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.exit(acc);

    vm.prank(wallet);
    custodian.exit(acc);
    assertEq(subAccounts.ownerOf(acc), wallet);
    assertEq(_position(acc), int(CONTRACT));
    assertEq(_cash(acc), cash);
    assertEq(custodian.accountOwner(acc), address(0));
  }

  function testARelayedExitNeedsTheWalletsSignature() public {
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _sign(walletPk, keccak256(abi.encode(custodian.EXIT_TYPEHASH(), acc, 9, deadline)));
    vm.prank(relayer);
    custodian.exitFor(acc, 9, deadline, sig);
    assertEq(subAccounts.ownerOf(acc), wallet);
  }

  function testActionsPauseAndRelayedCallsExpire() public {
    RecordingModule m = new RecordingModule();
    _allowModule(address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, acc, address(m), "", 1, deadline);
    vm.prank(vault);
    custodian.setPaused(true);
    vm.expectRevert(BookCustodian.BC_Paused.selector);
    custodian.act(acc, m, "", 1, deadline, sig);
    vm.prank(vault);
    custodian.setPaused(false);

    bytes memory w =
      _sign(walletPk, keccak256(abi.encode(custodian.WITHDRAW_TYPEHASH(), acc, address(CASH), 5e6, 2, deadline)));
    bytes memory e = _sign(walletPk, keccak256(abi.encode(custodian.EXIT_TYPEHASH(), acc, 3, deadline)));
    bytes memory k = _sign(
      walletPk, keccak256(abi.encode(custodian.SET_TRADING_KEY_TYPEHASH(), wallet, key, uint64(1e10), 4, deadline))
    );
    vm.warp(deadline + 1);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.act(acc, m, "", 1, deadline, sig);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.withdrawFor(acc, CASH, 5e6, 2, deadline, w);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.exitFor(acc, 3, deadline, e);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.setTradingKeyFor(wallet, key, 1e10, 4, deadline, k);
  }

  /// Guarantee 3 (no admin path to balances) as a test: the contract's whole external surface, pinned. A new function
  /// fails this until it is reviewed against the spec and added here. Owner-only today: queue, cancelQueued, enable,
  /// disallow, setPaused and Ownable2Step's own; none of them moves an account, a balance or a position.
  function testTheExternalSurfaceIsExactlyTheReviewedOne() public view {
    string[] memory got =
      vm.parseJsonKeys(vm.readFile("out/BookCustodian.sol/BookCustodian.json"), ".methodIdentifiers");
    string[39] memory want = [
      "ACT_TYPEHASH()",
      "DELAY()",
      "EXIT_TYPEHASH()",
      "SET_TRADING_KEY_TYPEHASH()",
      "TAKE_TYPEHASH()",
      "WITHDRAW_TYPEHASH()",
      "acceptOwnership()",
      "accountOwner(uint256)",
      "act(uint256,address,bytes,uint256,uint64,bytes)",
      "allowed(uint8,address)",
      "cancelNonce(uint256)",
      "cancelQueued(uint8,address)",
      "deposit(uint256,address,uint256)",
      "depositWithPermit(uint256,address,uint256,uint256,uint8,bytes32,bytes32)",
      "disallow(uint8,address)",
      "domainSeparator()",
      "eip712Domain()",
      "enable(uint8,address)",
      "eta(uint8,address)",
      "exit(uint256)",
      "exitFor(uint256,uint256,uint64,bytes)",
      "nonceUsed(address,uint256)",
      "onERC721Received(address,address,uint256,bytes)",
      "openAccount(address,address)",
      "owner()",
      "paused()",
      "pendingOwner()",
      "queue(uint8,address)",
      "renounceOwnership()",
      "setPaused(bool)",
      "setTradingKey(address,uint64)",
      "setTradingKeyFor(address,address,uint64,uint256,uint64,bytes)",
      "subAccounts()",
      "take((uint256,address,uint256,bool,uint256,uint256,uint256,uint256,uint64,uint16,bool,uint256),bytes)",
      "takeDigest((uint256,address,uint256,bool,uint256,uint256,uint256,uint256,uint64,uint16,bool,uint256))",
      "tradingKey(address)",
      "transferOwnership(address)",
      "withdraw(uint256,address,uint256)",
      "withdrawFor(uint256,address,uint256,uint256,uint64,bytes)"
    ];
    assertEq(got.length, want.length, "functions added or removed: review against docs/book-custodian-spec.md");
    for (uint i; i < want.length; ++i) {
      assertEq(got[i], want[i]);
    }
  }

  ///////////////
  // Migration //
  ///////////////

  /// A Matching account with a position moves in with its position: Matching's own exit, then one transfer in.
  function testMigrationFromMatchingKeepsThePosition() public {
    // a venue account today: under the engine, funded, in Matching, with a position (traded here directly first)
    vm.prank(wallet);
    custodian.exit(acc);
    vm.startPrank(wallet);
    subAccounts.approve(address(MATCHING), acc);
    MATCHING.depositSubAccount(acc);
    vm.stopPrank();
    assertEq(subAccounts.ownerOf(acc), address(MATCHING));

    vm.prank(wallet);
    MATCHING.requestWithdrawAccount(acc);
    vm.warp(block.timestamp + 30 minutes);
    vm.prank(relayer);
    MATCHING.completeWithdrawAccount(acc);
    assertEq(subAccounts.ownerOf(acc), wallet);

    vm.prank(wallet);
    subAccounts.safeTransferFrom(wallet, address(custodian), acc);
    assertEq(custodian.accountOwner(acc), wallet);

    // the book's index must be fresh for a take: move back to the pinned time for the trade
    vm.warp(block.timestamp - 30 minutes);
    assertEq(_take(_order(acc, BOOK, true, CONTRACT, false), walletPk), CONTRACT);
    assertEq(_position(acc), int(CONTRACT));
  }
}
