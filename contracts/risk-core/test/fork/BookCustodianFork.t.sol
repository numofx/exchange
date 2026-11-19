// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IAllowances} from "../../src/interfaces/IAllowances.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IFutureAssetV3} from "../../src/interfaces/IFutureAssetV3.sol";
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

/// @dev A book the owner was tricked into allowing: it tries to walk off with an account.
contract ThievingBook {
  ISubAccounts immutable subAccounts;

  constructor(ISubAccounts s) {
    subAccounts = s;
  }

  function markets(uint) external pure returns (ICustodianBook.MarketView memory m) {}

  function take(ICustodianBook.TakeOrder calldata o, bytes calldata) external returns (uint, uint) {
    subAccounts.transferFrom(msg.sender, address(this), o.takerAccountId);
    return (0, 0);
  }
}

/// @dev Records what it was given during `take`.
contract MeasuringBook {
  ISubAccounts immutable subAccounts;
  IAsset immutable cash;
  IAsset immutable future;
  uint96 immutable subId;
  uint immutable lot;
  uint public positive;
  uint public negative;
  uint public cashNegative;
  uint public reportsLength;

  constructor(ISubAccounts s, IAsset c, IAsset f, uint96 id, uint l) {
    subAccounts = s;
    cash = c;
    future = f;
    subId = id;
    lot = l;
  }

  function markets(uint) external view returns (ICustodianBook.MarketView memory m) {
    m.future = address(future);
    m.subId = subId;
    m.lotSize = lot;
  }

  function take(ICustodianBook.TakeOrder calldata o, bytes calldata reports) external returns (uint, uint) {
    IAllowances a = IAllowances(address(subAccounts));
    positive = a.positiveSubIdAllowance(o.takerAccountId, msg.sender, future, subId, address(this));
    negative = a.negativeSubIdAllowance(o.takerAccountId, msg.sender, future, subId, address(this));
    cashNegative = a.negativeSubIdAllowance(o.takerAccountId, msg.sender, cash, 0, address(this));
    reportsLength = reports.length;
    return (0, 0);
  }
}

/// @dev A manager (which SubAccounts authorizes to move its accounts) that is also a book.
contract ManagerBook {
  ISubAccounts immutable subAccounts;

  constructor(ISubAccounts s) {
    subAccounts = s;
  }

  function handleAdjustment(uint, uint, address, ISubAccounts.AssetDelta[] memory, bytes memory) external {}

  function markets(uint) external pure returns (ICustodianBook.MarketView memory m) {}

  function take(ICustodianBook.TakeOrder calldata o, bytes calldata) external returns (uint, uint) {
    subAccounts.transferFrom(msg.sender, address(this), o.takerAccountId);
    return (0, 0);
  }
}

/// @dev Review F1, book path: a book that tries to leave itself a standing allowance on the taker's account.
contract AllowancePlantingBook {
  ISubAccounts immutable subAccounts;
  IAsset immutable cash;
  address immutable beneficiary;

  constructor(ISubAccounts s, IAsset c, address b) {
    subAccounts = s;
    cash = c;
    beneficiary = b;
  }

  function markets(uint) external pure returns (ICustodianBook.MarketView memory m) {}

  function take(ICustodianBook.TakeOrder calldata o, bytes calldata) external returns (uint, uint) {
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](1);
    a[0] = IAllowances.AssetAllowance({asset: cash, positive: type(uint).max, negative: type(uint).max});
    subAccounts.setAssetAllowances(o.takerAccountId, beneficiary, a);
    return (0, 0);
  }
}

/// @dev Review F1, module path.
contract AllowancePlantingModule is IBookCustodianModule {
  ISubAccounts immutable subAccounts;
  IAsset immutable cash;
  address immutable beneficiary;

  constructor(ISubAccounts s, IAsset c, address b) {
    subAccounts = s;
    cash = c;
    beneficiary = b;
  }

  function onAct(uint accountId, address, address, bytes calldata) external {
    IAllowances.AssetAllowance[] memory a = new IAllowances.AssetAllowance[](1);
    a[0] = IAllowances.AssetAllowance({asset: cash, positive: type(uint).max, negative: type(uint).max});
    subAccounts.setAssetAllowances(accountId, beneficiary, a);
  }
}

contract ThievingModule is IBookCustodianModule {
  ISubAccounts immutable subAccounts;

  constructor(ISubAccounts s) {
    subAccounts = s;
  }

  function onAct(uint accountId, address, address, bytes calldata) external {
    subAccounts.transferFrom(msg.sender, address(this), accountId);
  }
}

/// @dev Review F2: an "internal transfer" module. It moves cash from the account to an account named in `data`, as far
///      as its grant allows. Now it is told the signer, and a key reaches it only if it is also a KeyModule.
contract CashMoveModule is IBookCustodianModule {
  ISubAccounts immutable subAccounts;
  IAsset immutable cash;
  address public lastSigner;

  constructor(ISubAccounts s, IAsset c) {
    subAccounts = s;
    cash = c;
  }

  function onAct(uint accountId, address, address signer, bytes calldata data) external {
    lastSigner = signer;
    if (data.length == 0) return;
    (uint to, int amount) = abi.decode(data, (uint, int));
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({fromAcc: accountId, toAcc: to, asset: cash, subId: 0, amount: amount, assetData: 0}),
      ""
    );
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

contract NoCalls {}

/**
 * BookCustodian (docs/book-custodian-spec.md) on Base against the live SubAccounts, MarginEngine v2, cash, the cNGN
 * OnchainBook (cNGN-30NOV26, market 1, maker #60 quoting) and Matching. Pinned where the maker quotes, as
 * BookTakeModuleForkTest is (2026-11-19 02:28:53 UTC). Each guarantee in the spec is a test here, and so is each
 * finding of the 2026-11-19 review (testReview*), which all failed against the first version.
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
  uint constant LOT = 1e15; // the cNGN book's market 1
  uint constant BUY_LIMIT = 0.0007e18;
  uint constant SELL_LIMIT = 0.0006e18;

  BookCustodian custodian;
  ISubAccounts subAccounts;
  IAllowances allowances;
  address vault = address(0xA11CE);
  // Keys hashed from labels: short keys map to addresses that carry code on Base (EIP-7702 delegations), and code
  // turns every signature check into EIP-1271.
  address relayer = makeAddr("custodian relayer");
  address attacker = makeAddr("custodian attacker");
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
    allowances = IAllowances(address(subAccounts));
    wallet = vm.addr(walletPk);
    key = vm.addr(keyPk);
    other = vm.addr(otherPk);

    BookCustodian.Kind[] memory kinds = new BookCustodian.Kind[](3);
    address[] memory targets = new address[](3);
    (kinds[0], targets[0]) = (BookCustodian.Kind.Manager, address(ENGINE));
    (kinds[1], targets[1]) = (BookCustodian.Kind.Asset, address(CASH));
    (kinds[2], targets[2]) = (BookCustodian.Kind.Book, BOOK);
    custodian = new BookCustodian(subAccounts, IAsset(address(CASH)), vault, kinds, targets);

    acc = _openFunded(wallet, walletPk, 1_000e6);
  }

  /////////////
  // Helpers //
  /////////////

  function _signDigest(uint pk, bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return bytes.concat(r, s, bytes1(v));
  }

  function _sign(uint pk, bytes32 structHash) internal view returns (bytes memory) {
    return _signDigest(pk, MessageHashUtils.toTypedDataHash(custodian.domainSeparator(), structHash));
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

  function _takeSig(uint pk, BookCustodian.Take memory t) internal view returns (bytes memory) {
    return _signDigest(pk, custodian.takeDigest(t));
  }

  function _take(BookCustodian.Take memory t, uint pk) internal returns (uint filled) {
    bytes memory sig = _takeSig(pk, t);
    vm.prank(relayer);
    (filled,) = custodian.take(t, sig, "");
  }

  function _noGrants() internal pure returns (BookCustodian.Grant[] memory) {
    return new BookCustodian.Grant[](0);
  }

  function _cashGrant(uint negative) internal pure returns (BookCustodian.Grant[] memory g) {
    g = new BookCustodian.Grant[](1);
    g[0] = BookCustodian.Grant({asset: address(CASH), subId: 0, positive: 0, negative: negative});
  }

  function _x(
    uint id,
    address m,
    bytes memory data,
    BookCustodian.Grant[] memory grants,
    bool persist,
    uint n,
    uint64 deadline
  ) internal pure returns (BookCustodian.Action memory) {
    return BookCustodian.Action({
      accountId: id, module: m, data: data, grants: grants, persist: persist, nonce: n, deadline: deadline
    });
  }

  function _actSig(uint pk, BookCustodian.Action memory x) internal view returns (bytes memory) {
    return _signDigest(pk, custodian.actDigest(x));
  }

  function _position(uint id) internal view returns (int) {
    return subAccounts.getBalance(id, FUTURE, SUB_ID);
  }

  function _cash(uint id) internal view returns (int) {
    return subAccounts.getBalance(id, IAsset(address(CASH)), 0);
  }

  function _cashAllowance(uint id, address delegate) internal view returns (uint) {
    return allowances.negativeSubIdAllowance(id, address(custodian), IAsset(address(CASH)), 0, delegate)
      + allowances.negativeAssetAllowance(id, address(custodian), IAsset(address(CASH)), delegate);
  }

  function _setKey(uint64 validUntil) internal {
    vm.prank(wallet);
    custodian.setTradingKey(key, validUntil);
  }

  function _allow(BookCustodian.Kind kind, address target) internal {
    vm.startPrank(vault);
    custodian.queue(kind, target);
    vm.warp(block.timestamp + 48 hours);
    custodian.enable(kind, target);
    vm.stopPrank();
  }

  function _attackerAccount() internal returns (uint id) {
    vm.prank(attacker);
    id = subAccounts.createAccount(attacker, ENGINE);
  }

  /// attacker moves cash out of `from` with no signature and no custodian call
  function _drain(uint from, uint to, int amount) internal {
    vm.prank(attacker);
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: from, toAcc: to, asset: IAsset(address(CASH)), subId: 0, amount: amount, assetData: bytes32(0)
      }),
      ""
    );
  }

  ///////////////////////////
  // Accounts and deposits //
  ///////////////////////////

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

  /// Review F3: nobody but the wallet pulls a standing approval; a front-run permit (exact allowance) still works.
  function testReviewAStandingApprovalIsPulledOnlyByTheWallet() public {
    deal(USDC, wallet, 5_000e6);
    vm.prank(wallet);
    IERC20(USDC).approve(address(custodian), type(uint).max);

    vm.startPrank(attacker);
    uint fresh = custodian.openAccount(wallet, ENGINE);
    vm.expectRevert(BookCustodian.BC_PermitFailed.selector);
    custodian.depositWithPermit(fresh, CASH, 5_000e6, 0, 0, bytes32(0), bytes32(0));
    vm.stopPrank();
    assertEq(IERC20(USDC).balanceOf(wallet), 5_000e6);

    // the wallet itself may use its approval through the same function
    vm.prank(wallet);
    custodian.depositWithPermit(fresh, CASH, 1_000e6, 0, 0, bytes32(0), bytes32(0));
    assertEq(_cash(fresh), 1_000e18);

    // a permit someone front-ran leaves exactly its amount approved: the relayer's call still lands
    vm.prank(wallet);
    IERC20(USDC).approve(address(custodian), 0);
    (uint8 v, bytes32 r, bytes32 s) = _permit(wallet, walletPk, 700e6);
    IERC20Permit(USDC).permit(wallet, address(custodian), 700e6, block.timestamp + 600, v, r, s);
    vm.prank(relayer);
    custodian.depositWithPermit(fresh, CASH, 700e6, block.timestamp + 600, v, r, s);
    assertEq(_cash(fresh), 1_700e18);
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
    custodian.onERC721Received(other, other, acc, "");
  }

  /// Review F4: an account must be sent in by its owner, so it is never recorded to an address that cannot exit.
  function testReviewOnlyTheOwnerSendsAnAccountIn() public {
    address noCalls = address(new NoCalls());
    vm.prank(attacker);
    uint id = subAccounts.createAccountWithApproval(noCalls, attacker, ENGINE);
    vm.prank(attacker);
    vm.expectRevert(BookCustodian.BC_NotOwnerSending.selector);
    subAccounts.safeTransferFrom(noCalls, address(custodian), id);
  }

  /////////////
  // Trading //
  /////////////

  /// A signed take fills; the account stays here; the book keeps no approval and no allowance afterwards.
  function testAWalletSignedTakeFills() public {
    int cashBefore = _cash(acc);
    assertEq(_take(_order(acc, BOOK, true, CONTRACT, false), walletPk), CONTRACT);
    assertEq(_position(acc), int(CONTRACT));
    assertGt(cashBefore - _cash(acc), 1e18, "paid at least the fee");
    assertEq(subAccounts.ownerOf(acc), address(custodian));
    assertEq(subAccounts.getApproved(acc), address(0), "never approved");
    assertFalse(subAccounts.isApprovedForAll(address(custodian), BOOK), "no standing approval");
    assertEq(allowances.positiveSubIdAllowance(acc, address(custodian), FUTURE, SUB_ID, BOOK), 0, "position zeroed");
    assertEq(_cashAllowance(acc, BOOK), 0, "fee allowance zeroed");
  }

  function testASellTakeFillsAndLeavesNoAllowance() public {
    assertEq(_take(_order(acc, BOOK, false, CONTRACT, false), walletPk), CONTRACT);
    assertEq(_position(acc), -int(CONTRACT));
    assertEq(allowances.negativeSubIdAllowance(acc, address(custodian), FUTURE, SUB_ID, BOOK), 0);
    assertEq(_cashAllowance(acc, BOOK), 0);
  }

  /// The book is given exactly the signed order, as allowances, for the call only, and the relayer's reports.
  function testTheBookIsGivenExactlyTheOrder() public {
    MeasuringBook b = new MeasuringBook(subAccounts, IAsset(address(CASH)), FUTURE, uint96(SUB_ID), LOT);
    _allow(BookCustodian.Kind.Book, address(b));
    BookCustodian.Take memory t = _order(acc, address(b), false, 3 * CONTRACT, false);
    t.maxFee = 7e18;
    bytes memory sig = _takeSig(walletPk, t);
    custodian.take(t, sig, hex"0102");
    assertEq(b.positive(), 0);
    assertEq(b.negative(), 3 * CONTRACT, "a sell: the size, negative");
    assertEq(b.cashNegative(), 7e18, "the signed maxFee");
    assertEq(b.reportsLength(), 2);

    t = _order(acc, address(b), true, 2 * CONTRACT, false);
    sig = _takeSig(walletPk, t);
    custodian.take(t, sig, "");
    assertEq(b.positive(), 2 * CONTRACT, "a buy: the size, positive");
    assertEq(b.negative(), 0);
    assertEq(allowances.negativeSubIdAllowance(acc, address(custodian), FUTURE, SUB_ID, address(b)), 0);
    assertEq(_cashAllowance(acc, address(b)), 0);
  }

  function testATradingKeyTakesUntilItExpiresOrIsRevoked() public {
    _setKey(uint64(block.timestamp + 1 days));
    assertEq(_take(_order(acc, BOOK, true, CONTRACT, false), keyPk), CONTRACT);

    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(keyPk, t);
    vm.prank(wallet);
    custodian.setTradingKey(address(0), 0);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig, "");

    _setKey(uint64(block.timestamp + 10));
    t = _order(acc, BOOK, true, CONTRACT, false);
    t.deadline = uint64(block.timestamp + 600);
    sig = _takeSig(keyPk, t);
    vm.warp(block.timestamp + 11);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig, "");
  }

  function testASignatureIsUsedOnce() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    custodian.take(t, sig, "");
    vm.expectRevert(BookCustodian.BC_NonceUsed.selector);
    custodian.take(t, sig, "");
  }

  function testACancelledNonceCannotBeUsed() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.prank(wallet);
    custodian.cancelNonce(t.nonce);
    vm.expectRevert(BookCustodian.BC_NonceUsed.selector);
    custodian.take(t, sig, "");
  }

  /// A signature for the wallet's account cannot trade another wallet's account, nor can another wallet's key.
  function testASignatureActsOnlyOnItsOwnAccount() public {
    uint otherAcc = _openFunded(other, otherPk, 1_000e6);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    t.accountId = otherAcc;
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig, "");

    _setKey(uint64(block.timestamp + 1 days));
    t = _order(otherAcc, BOOK, true, CONTRACT, false);
    sig = _takeSig(keyPk, t);
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.take(t, sig, "");
  }

  function testAnExpiredTakeIsRefused() public {
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.warp(t.deadline + 1);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.take(t, sig, "");
  }

  function testReduceOnlyClosesNoMoreThanThePosition() public {
    _take(_order(acc, BOOK, true, CONTRACT, false), walletPk);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, true);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(BookCustodian.BC_NotReducing.selector);
    custodian.take(t, sig, "");

    assertEq(_take(_order(acc, BOOK, false, 3 * CONTRACT, true), walletPk), CONTRACT, "cut to the position");
    assertEq(_position(acc), 0);
  }

  /// Review F6: a position that is not whole lots (as a partial liquidation can leave) closes to its whole lots.
  function testReviewReduceOnlyCutsToWholeLots() public {
    // the wallet's own two accounts: one sells the other 1 contract and half a lot, at the index
    vm.startPrank(wallet);
    uint a = subAccounts.createAccount(wallet, ENGINE);
    uint b = subAccounts.createAccount(wallet, ENGINE);
    deal(USDC, wallet, 2_000e6);
    IERC20(USDC).approve(address(CASH), 2_000e6);
    CASH.deposit(a, 1_000e6);
    CASH.deposit(b, 1_000e6);
    (uint price,) = IFutureAssetV3(address(FUTURE)).indexFeed().getSpot();
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: a, toAcc: b, asset: FUTURE, subId: SUB_ID, amount: int(CONTRACT + LOT / 2), assetData: bytes32(price)
      }),
      ""
    );
    subAccounts.safeTransferFrom(wallet, address(custodian), b);
    vm.stopPrank();

    // a reduce-only sell of everything, all or nothing: one whole contract fills, the half lot stays
    assertEq(_take(_order(b, BOOK, false, 5 * CONTRACT, true), walletPk), CONTRACT);
    assertEq(_position(b), int(LOT / 2));
  }

  function testPauseStopsTakesOnly() public {
    vm.prank(vault);
    custodian.setPaused(true);
    BookCustodian.Take memory t = _order(acc, BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(BookCustodian.BC_Paused.selector);
    custodian.take(t, sig, "");

    vm.startPrank(wallet);
    custodian.withdraw(acc, CASH, 10e6);
    custodian.setTradingKey(key, uint64(block.timestamp + 1));
    custodian.clearGrants(acc);
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

  /////////////////////////
  // Books and the delay //
  /////////////////////////

  function testABookIsUsableOnly48HoursAfterQueueing() public {
    BookCustodian.Take memory t = _order(acc, EURC_BOOK, true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.take(t, sig, "");

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
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.take(t, sig, "");
  }

  /// Even an allowed malicious book cannot move the account: it is never approved on it.
  function testAnAllowedThievingBookCannotTakeTheAccount() public {
    ThievingBook thief = new ThievingBook(subAccounts);
    _allow(BookCustodian.Kind.Book, address(thief));
    BookCustodian.Take memory t = _order(acc, address(thief), true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(thief), acc));
    custodian.take(t, sig, "");
    assertEq(subAccounts.ownerOf(acc), address(custodian));
  }

  /// The one party SubAccounts lets move an account without approval is its manager: if an allowed manager that is
  /// also an allowed book moves it during a take, the take reverts and the account stays.
  function testAnAccountMovedOutDuringACallRevertsTheCall() public {
    ManagerBook mb = new ManagerBook(subAccounts);
    _allow(BookCustodian.Kind.Manager, address(mb));
    _allow(BookCustodian.Kind.Book, address(mb));
    uint id = custodian.openAccount(wallet, IManager(address(mb)));
    BookCustodian.Take memory t = _order(id, address(mb), true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectRevert(BookCustodian.BC_AccountLeft.selector);
    custodian.take(t, sig, "");
    assertEq(subAccounts.ownerOf(id), address(custodian));
  }

  /// Review F1, book path: an allowed book cannot leave itself (or anyone) a standing allowance.
  function testReviewABookCannotPlantAnAllowance() public {
    AllowancePlantingBook b = new AllowancePlantingBook(subAccounts, IAsset(address(CASH)), attacker);
    _allow(BookCustodian.Kind.Book, address(b));
    BookCustodian.Take memory t = _order(acc, address(b), true, CONTRACT, false);
    bytes memory sig = _takeSig(walletPk, t);
    vm.expectPartialRevert(ISubAccounts.AC_NotOwnerOrERC721Approved.selector);
    custodian.take(t, sig, "");
    assertEq(_cashAllowance(acc, attacker), 0);
  }

  /////////////
  // Modules //
  /////////////

  function testAModuleActsOnTheSignedAccountWithTheSignedDataOnly() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), "", _noGrants(), false, 1, deadline));
    custodian.act(_x(acc, address(m), "", _noGrants(), false, 1, deadline), sig);
    assertEq(m.lastSigner(), wallet);
    assertEq(subAccounts.getApproved(acc), address(0));

    uint dest = _attackerAccount();
    bytes memory data = abi.encode(dest, int(1e18));
    sig = _actSig(walletPk, _x(acc, address(m), "", _noGrants(), false, 2, deadline));
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.act(_x(acc, address(m), data, _noGrants(), false, 2, deadline), sig);

    // the grant is part of what is signed too
    sig = _actSig(walletPk, _x(acc, address(m), data, _cashGrant(1e18), false, 3, deadline));
    vm.expectRevert(BookCustodian.BC_BadSignature.selector);
    custodian.act(_x(acc, address(m), data, _cashGrant(2e18), false, 3, deadline), sig);
  }

  /// A module moves no more than its grant, and a call-only grant is gone after the call.
  function testAModuleMovesOnlyWhatWasGranted() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    uint dest = _attackerAccount();
    uint64 deadline = uint64(block.timestamp + 60);

    bytes memory data = abi.encode(dest, int(101e18));
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), data, _cashGrant(100e18), false, 1, deadline));
    vm.expectRevert();
    custodian.act(_x(acc, address(m), data, _cashGrant(100e18), false, 1, deadline), sig);

    data = abi.encode(dest, int(60e18));
    sig = _actSig(walletPk, _x(acc, address(m), data, _cashGrant(100e18), false, 2, deadline));
    custodian.act(_x(acc, address(m), data, _cashGrant(100e18), false, 2, deadline), sig);
    assertEq(_cash(dest), 60e18);
    assertEq(_cashAllowance(acc, address(m)), 0, "nothing left after the call");
  }

  /// Review F1, module path: a module cannot plant an allowance (it is never ERC-721 approved).
  function testReviewAModuleCannotPlantAnAllowance() public {
    AllowancePlantingModule m = new AllowancePlantingModule(subAccounts, IAsset(address(CASH)), attacker);
    _allow(BookCustodian.Kind.Module, address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), "", _noGrants(), false, 1, deadline));
    vm.expectPartialRevert(ISubAccounts.AC_NotOwnerOrERC721Approved.selector);
    custodian.act(_x(acc, address(m), "", _noGrants(), false, 1, deadline), sig);
  }

  function testAQueuedModuleHasNoPowerAndAThievingOneCannotTakeTheAccount() public {
    ThievingModule thief = new ThievingModule(subAccounts);
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, _x(acc, address(thief), "", _noGrants(), false, 1, deadline));
    vm.prank(vault);
    custodian.queue(BookCustodian.Kind.Module, address(thief));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.act(_x(acc, address(thief), "", _noGrants(), false, 1, deadline), sig);

    vm.warp(block.timestamp + 48 hours);
    vm.prank(vault);
    custodian.enable(BookCustodian.Kind.Module, address(thief));
    deadline = uint64(block.timestamp + 60);
    sig = _actSig(walletPk, _x(acc, address(thief), "", _noGrants(), false, 2, deadline));
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(thief), acc));
    custodian.act(_x(acc, address(thief), "", _noGrants(), false, 2, deadline), sig);
    assertEq(subAccounts.ownerOf(acc), address(custodian));
  }

  /// Review F2: a trading key reaches only KeyModules, and the module is told it was the key.
  function testReviewATradingKeyReachesOnlyKeyModules() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    _setKey(uint64(block.timestamp + 10 days));
    uint dest = _attackerAccount();
    bytes memory data = abi.encode(dest, int(900e18));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(keyPk, _x(acc, address(m), data, _cashGrant(900e18), false, 1, deadline));
    vm.expectRevert(BookCustodian.BC_NotAllowed.selector);
    custodian.act(_x(acc, address(m), data, _cashGrant(900e18), false, 1, deadline), sig);
    assertEq(_cash(dest), 0);

    _allow(BookCustodian.Kind.KeyModule, address(m));
    deadline = uint64(block.timestamp + 60);
    sig = _actSig(keyPk, _x(acc, address(m), "", _noGrants(), false, 2, deadline));
    custodian.act(_x(acc, address(m), "", _noGrants(), false, 2, deadline), sig);
    assertEq(m.lastSigner(), key);
  }

  /// A persisted grant (a resting order's power to settle) stays after the call, and `clearGrants` and `exit` zero
  /// it, so it never revives when the account comes back.
  function testPersistedGrantsAreZeroedByClearAndByExit() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), "", _cashGrant(50e18), true, 1, deadline));
    custodian.act(_x(acc, address(m), "", _cashGrant(50e18), true, 1, deadline), sig);
    assertEq(_cashAllowance(acc, address(m)), 50e18);
    assertEq(custodian.persistedGrants(acc).length, 1);

    vm.prank(other);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.clearGrants(acc);
    vm.prank(wallet);
    custodian.clearGrants(acc);
    assertEq(_cashAllowance(acc, address(m)), 0);

    sig = _actSig(walletPk, _x(acc, address(m), "", _cashGrant(50e18), true, 2, deadline));
    custodian.act(_x(acc, address(m), "", _cashGrant(50e18), true, 2, deadline), sig);
    vm.prank(wallet);
    custodian.exit(acc);
    vm.prank(wallet);
    subAccounts.safeTransferFrom(wallet, address(custodian), acc);
    assertEq(_cashAllowance(acc, address(m)), 0, "nothing revives on return");
    assertEq(custodian.persistedGrants(acc).length, 0);
  }

  function testPersistedGrantsAreBounded() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    BookCustodian.Grant[] memory g = new BookCustodian.Grant[](17);
    for (uint i; i < 17; ++i) {
      g[i] = BookCustodian.Grant({asset: address(CASH), subId: 0, positive: 0, negative: 1});
    }
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), "", g, true, 1, deadline));
    vm.expectRevert(BookCustodian.BC_TooManyGrants.selector);
    custodian.act(_x(acc, address(m), "", g, true, 1, deadline), sig);
  }

  function testActionsPauseAndRelayedCallsExpire() public {
    CashMoveModule m = new CashMoveModule(subAccounts, IAsset(address(CASH)));
    _allow(BookCustodian.Kind.Module, address(m));
    uint64 deadline = uint64(block.timestamp + 60);
    bytes memory sig = _actSig(walletPk, _x(acc, address(m), "", _noGrants(), false, 1, deadline));
    vm.prank(vault);
    custodian.setPaused(true);
    vm.expectRevert(BookCustodian.BC_Paused.selector);
    custodian.act(_x(acc, address(m), "", _noGrants(), false, 1, deadline), sig);
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
    custodian.act(_x(acc, address(m), "", _noGrants(), false, 1, deadline), sig);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.withdrawFor(acc, CASH, 5e6, 2, deadline, w);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.exitFor(acc, 3, deadline, e);
    vm.expectRevert(BookCustodian.BC_Expired.selector);
    custodian.setTradingKeyFor(wallet, key, 1e10, 4, deadline, k);
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
    uint relayerBefore = IERC20(USDC).balanceOf(relayer);
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
    assertEq(IERC20(USDC).balanceOf(relayer), relayerBefore);
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
    vm.prank(key);
    vm.expectRevert(BookCustodian.BC_NotWallet.selector);
    custodian.clearGrants(acc);
  }

  /// Exit with an open position, while paused, with the book, manager and asset disallowed: the account and everything
  /// in it go to the wallet, and nobody else can do it.
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

  /// Guarantee 3 (no admin path to balances) as a test: the contract's whole external surface, pinned. A new function
  /// fails this until it is reviewed against the spec and added here. Owner-only today: queue, cancelQueued, enable,
  /// disallow, setPaused and Ownable2Step's own; none of them moves an account, a balance or a position.
  function testTheExternalSurfaceIsExactlyTheReviewedOne() public view {
    string[] memory got =
      vm.parseJsonKeys(vm.readFile("out/BookCustodian.sol/BookCustodian.json"), ".methodIdentifiers");
    string[45] memory want = [
      "ACT_TYPEHASH()",
      "DELAY()",
      "EXIT_TYPEHASH()",
      "GRANT_TYPEHASH()",
      "MAX_PERSISTED_GRANTS()",
      "SET_TRADING_KEY_TYPEHASH()",
      "TAKE_TYPEHASH()",
      "WITHDRAW_TYPEHASH()",
      "acceptOwnership()",
      "accountOwner(uint256)",
      "act((uint256,address,bytes,(address,uint256,uint256,uint256)[],bool,uint256,uint64),bytes)",
      "actDigest((uint256,address,bytes,(address,uint256,uint256,uint256)[],bool,uint256,uint64))",
      "allowed(uint8,address)",
      "cancelNonce(uint256)",
      "cancelQueued(uint8,address)",
      "cash()",
      "clearGrants(uint256)",
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
      "persistedGrants(uint256)",
      "queue(uint8,address)",
      "renounceOwnership()",
      "setPaused(bool)",
      "setTradingKey(address,uint64)",
      "setTradingKeyFor(address,address,uint64,uint256,uint64,bytes)",
      "subAccounts()",
      "take((uint256,address,uint256,bool,uint256,uint256,uint256,uint256,uint64,uint16,bool,uint256),bytes,bytes)",
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
    // a venue account today: under the engine, funded, with a position, held by Matching
    _take(_order(acc, BOOK, true, CONTRACT, false), walletPk);
    vm.startPrank(wallet);
    custodian.exit(acc);
    subAccounts.approve(address(MATCHING), acc);
    MATCHING.depositSubAccount(acc);
    vm.stopPrank();
    assertEq(subAccounts.ownerOf(acc), address(MATCHING));
    assertEq(_position(acc), int(CONTRACT));
    int cash = _cash(acc);

    vm.prank(wallet);
    MATCHING.requestWithdrawAccount(acc);
    vm.warp(block.timestamp + 30 minutes);
    vm.prank(relayer);
    MATCHING.completeWithdrawAccount(acc);
    assertEq(subAccounts.ownerOf(acc), wallet);

    vm.prank(wallet);
    subAccounts.safeTransferFrom(wallet, address(custodian), acc);
    assertEq(custodian.accountOwner(acc), wallet);
    assertEq(_position(acc), int(CONTRACT), "the position came along");
    assertApproxEqAbs(_cash(acc), cash, 1e15, "and the cash, less interest dust");

    // and it closes from the custodian (the book's index must be fresh: back to the pinned time)
    vm.warp(block.timestamp - 30 minutes);
    assertEq(_take(_order(acc, BOOK, false, CONTRACT, true), walletPk), CONTRACT);
    assertEq(_position(acc), 0);
  }
}
