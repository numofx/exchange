// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable2Step.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";
import "openzeppelin/utils/cryptography/EIP712.sol";
import "openzeppelin/utils/cryptography/SignatureChecker.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import "openzeppelin/token/ERC721/IERC721Receiver.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IManager} from "../interfaces/IManager.sol";
import {IAsset} from "../interfaces/IAsset.sol";

/// @dev OnchainBook as the custodian calls it. `TakeOrder` and `markets` mirror OnchainBook.sol field for field.
interface ICustodianBook {
  struct TakeOrder {
    uint marketId;
    uint takerAccountId;
    bool isBuy;
    uint amount;
    uint limitPrice;
    uint minFill;
    uint maxFee;
    uint64 deadline;
    uint16 maxLevels;
    uint8 selfTradeMode;
    bytes managerData;
  }

  /// @dev Every field is static, so this struct decodes the getter's thirteen return values as they are encoded.
  struct MarketView {
    address future;
    address engine;
    uint96 subId;
    uint64 expiry;
    uint64 lastTradeTime;
    address adapter;
    uint tickSize;
    uint lotSize;
    uint takerFeeRate;
    uint32 takeMaxAge;
    uint32 maxTtl;
    uint16 maxMakers;
    bool enabled;
  }

  function take(TakeOrder calldata o, bytes calldata optionalReport) external returns (uint filled, uint avgPrice);
  function markets(uint marketId) external view returns (MarketView memory);
}

/// @dev CashAsset and WrappedERC20Asset: both deposit from the caller and withdraw only for the account's owner.
interface ICustodianAsset {
  function wrappedAsset() external view returns (IERC20);
  function deposit(uint recipientAccount, uint amount) external;
  function withdraw(uint accountId, uint amount, address recipient) external;
}

/// @notice An action module (FIFO post, cancel, ...): approved on the one account for the length of the call.
interface IBookCustodianModule {
  function onAct(uint accountId, address wallet, bytes calldata data) external;
}

/**
 * @title BookCustodian
 * @notice Holds app users' SubAccounts accounts so the OnchainBooks (and, later, timelocked action modules such as a
 *         FIFO book) can act on them, without the venue holding any power over the money in them
 *         (docs/book-custodian-spec.md). Each account is recorded to one wallet. What the contract guarantees:
 *
 *         1. Only the wallet withdraws, and only to itself. A trading key can take and act, never withdraw, exit or
 *            change keys.
 *         2. `exit` always works: the wallet gets its account back (positions and balances), with no pause, no
 *            allowlist, no cooldown and no relayer in the way.
 *         3. The owner has no function that moves an account, a balance or a position. No upgrade, no delegatecall.
 *         4. Nothing holds standing power over the accounts. A book or module is ERC-721 approved on the one account
 *            in the call, and only for that call; the account must still be here afterwards. A book, module, manager
 *            or deposit asset becomes usable only 48 hours after the owner queues it, so users can leave first.
 *         5. A signature authorizes one action, once: EIP-712, per-signer nonces, a deadline, and the account inside
 *            what is signed.
 *
 *         Below this contract, as for every account: the vault's admin powers on SubAccounts, the assets and the
 *         MarginEngine, liquidation, and token issuers' freezes.
 */
contract BookCustodian is Ownable2Step, ReentrancyGuard, EIP712, IERC721Receiver {
  using SafeERC20 for IERC20;

  enum Kind {
    Manager,
    Asset,
    Book,
    Module
  }

  struct TradingKey {
    address key;
    uint64 validUntil;
  }

  /// @dev What a wallet (or its trading key) signs for a take. The taker is always `accountId`.
  struct Take {
    uint accountId;
    address book;
    uint marketId;
    bool isBuy;
    uint amount;
    uint limitPrice;
    uint minFill;
    uint maxFee;
    uint64 deadline;
    uint16 maxLevels;
    bool reduceOnly;
    uint nonce;
  }

  uint public constant DELAY = 48 hours;
  /// @dev OnchainBook.SelfTradeMode.Abort
  uint8 internal constant SELF_TRADE_ABORT = 0;

  bytes32 public constant TAKE_TYPEHASH = keccak256(
    "Take(uint256 accountId,address book,uint256 marketId,bool isBuy,uint256 amount,uint256 limitPrice,uint256 minFill,uint256 maxFee,uint64 deadline,uint16 maxLevels,bool reduceOnly,uint256 nonce)"
  );
  bytes32 public constant ACT_TYPEHASH =
    keccak256("Act(uint256 accountId,address module,bytes32 dataHash,uint256 nonce,uint64 deadline)");
  bytes32 public constant WITHDRAW_TYPEHASH =
    keccak256("Withdraw(uint256 accountId,address asset,uint256 amount,uint256 nonce,uint64 deadline)");
  bytes32 public constant EXIT_TYPEHASH = keccak256("Exit(uint256 accountId,uint256 nonce,uint64 deadline)");
  bytes32 public constant SET_TRADING_KEY_TYPEHASH =
    keccak256("SetTradingKey(address wallet,address key,uint64 validUntil,uint256 nonce,uint64 deadline)");

  ISubAccounts public immutable subAccounts;

  /// @notice The wallet each held account belongs to; zero for an account this contract does not hold.
  mapping(uint accountId => address wallet) public accountOwner;
  mapping(address wallet => TradingKey) public tradingKey;
  mapping(address signer => mapping(uint nonce => bool)) public nonceUsed;
  mapping(Kind => mapping(address => bool)) public allowed;
  /// @notice When a queued entry may be enabled; zero when nothing is queued.
  mapping(Kind => mapping(address => uint)) public eta;
  /// @notice Pauses takes and module actions only: never deposits' withdrawal, exit or key changes.
  bool public paused;

  event AccountOpened(uint indexed accountId, address indexed wallet, address manager);
  event AccountDeposited(uint indexed accountId, address indexed wallet);
  event Deposited(uint indexed accountId, address indexed asset, address from, uint amount);
  event Withdrawn(uint indexed accountId, address indexed asset, address indexed wallet, uint amount);
  event Exited(uint indexed accountId, address indexed wallet);
  event TradingKeySet(address indexed wallet, address key, uint64 validUntil);
  event NonceUsed(address indexed signer, uint nonce);
  event Took(
    uint indexed accountId, address indexed book, uint indexed marketId, bool isBuy, uint filled, uint avgPrice
  );
  event Acted(uint indexed accountId, address indexed module, address signer);
  event Queued(Kind indexed kind, address indexed target, uint eta);
  event QueueCancelled(Kind indexed kind, address indexed target);
  event Allowed(Kind indexed kind, address indexed target, bool allowed);
  event Paused(bool paused);

  error BC_NotHeld();
  error BC_NotWallet();
  error BC_BadSignature();
  error BC_NonceUsed();
  error BC_Expired();
  error BC_Paused();
  error BC_NotAllowed();
  error BC_NotQueued();
  error BC_TooEarly();
  error BC_NotSubAccounts();
  error BC_ZeroAddress();
  error BC_NotReducing();
  error BC_AccountLeft();
  error BC_LengthMismatch();

  /// @param initialKinds,initialTargets allowed at once: there are no accounts to protect before deployment
  constructor(ISubAccounts subAccounts_, address owner_, Kind[] memory initialKinds, address[] memory initialTargets)
    Ownable(owner_)
    EIP712("NumoBookCustodian", "1")
  {
    if (initialKinds.length != initialTargets.length) revert BC_LengthMismatch();
    subAccounts = subAccounts_;
    for (uint i; i < initialKinds.length; ++i) {
      _setAllowed(initialKinds[i], initialTargets[i], true);
    }
  }

  //////////////
  // Accounts //
  //////////////

  /// @notice A new account under an allowed manager, recorded to `wallet`. Anyone may open one: it starts empty.
  function openAccount(address wallet, IManager manager) external nonReentrant returns (uint accountId) {
    if (wallet == address(0)) revert BC_ZeroAddress();
    if (!allowed[Kind.Manager][address(manager)]) revert BC_NotAllowed();
    accountId = subAccounts.createAccount(address(this), manager);
    accountOwner[accountId] = wallet;
    emit AccountOpened(accountId, wallet, address(manager));
  }

  /// @notice A wallet sends its own account in with `safeTransferFrom`; it is recorded to the wallet it came from.
  function onERC721Received(address, address from, uint accountId, bytes calldata)
    external
    nonReentrant
    returns (bytes4)
  {
    if (msg.sender != address(subAccounts)) revert BC_NotSubAccounts();
    if (from == address(0)) revert BC_ZeroAddress();
    if (!allowed[Kind.Manager][address(subAccounts.manager(accountId))]) revert BC_NotAllowed();
    accountOwner[accountId] = from;
    emit AccountDeposited(accountId, from);
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice Deposit the caller's own tokens (after an ERC-20 approve) into a held account.
  function deposit(uint accountId, ICustodianAsset asset, uint amount) external nonReentrant {
    _held(accountId);
    _deposit(accountId, asset, msg.sender, amount);
  }

  /**
   * @notice Deposit the wallet's tokens into its own account with an EIP-2612 permit, relayed by anyone. The permit
   *         may have been used already (it can be front-run), so its failure is tolerated; the tokens can only ever
   *         go from the account's wallet into that wallet's account.
   */
  function depositWithPermit(
    uint accountId,
    ICustodianAsset asset,
    uint amount,
    uint permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external nonReentrant {
    address wallet = _held(accountId);
    IERC20 token = _depositToken(asset);
    try IERC20Permit(address(token)).permit(wallet, address(this), amount, permitDeadline, v, r, s) {} catch {}
    _deposit(accountId, asset, wallet, amount);
  }

  /////////////
  // Trading //
  /////////////

  /// @notice A take on an allowed book for the signed account, signed by its wallet or its trading key.
  function take(Take calldata t, bytes calldata signature) external nonReentrant returns (uint filled, uint avgPrice) {
    if (paused) revert BC_Paused();
    if (block.timestamp > t.deadline) revert BC_Expired();
    address wallet = _held(t.accountId);
    _verify(wallet, keccak256(abi.encode(TAKE_TYPEHASH, t)), signature, true, t.nonce);
    if (!allowed[Kind.Book][t.book]) revert BC_NotAllowed();

    uint amount = t.reduceOnly ? _reducing(t) : t.amount;
    ICustodianBook.TakeOrder memory order = ICustodianBook.TakeOrder({
      marketId: t.marketId,
      takerAccountId: t.accountId,
      isBuy: t.isBuy,
      amount: amount,
      limitPrice: t.limitPrice,
      minFill: t.minFill > amount ? amount : t.minFill,
      maxFee: t.maxFee,
      deadline: t.deadline,
      maxLevels: t.maxLevels,
      selfTradeMode: SELF_TRADE_ABORT,
      managerData: ""
    });

    subAccounts.approve(t.book, t.accountId);
    (filled, avgPrice) = ICustodianBook(t.book).take(order, "");
    _revokeAndCheck(t.accountId);
    emit Took(t.accountId, t.book, t.marketId, t.isBuy, filled, avgPrice);
  }

  /// @notice A call to an allowed module, approved on this one account for the call, signed by the wallet or its key.
  function act(
    uint accountId,
    IBookCustodianModule module,
    bytes calldata data,
    uint nonce,
    uint64 deadline,
    bytes calldata signature
  ) external nonReentrant {
    if (paused) revert BC_Paused();
    if (block.timestamp > deadline) revert BC_Expired();
    address wallet = _held(accountId);
    address signer = _verify(
      wallet,
      keccak256(abi.encode(ACT_TYPEHASH, accountId, address(module), keccak256(data), nonce, deadline)),
      signature,
      true,
      nonce
    );
    if (!allowed[Kind.Module][address(module)]) revert BC_NotAllowed();

    subAccounts.approve(address(module), accountId);
    module.onAct(accountId, wallet, data);
    _revokeAndCheck(accountId);
    emit Acted(accountId, address(module), signer);
  }

  /////////////
  // Leaving //
  /////////////

  /// @notice The wallet withdraws to itself. The asset's own owner check and the engine's margin check apply.
  function withdraw(uint accountId, ICustodianAsset asset, uint amount) external nonReentrant {
    address wallet = _held(accountId);
    if (msg.sender != wallet) revert BC_NotWallet();
    _withdraw(accountId, asset, wallet, amount);
  }

  /// @notice `withdraw`, relayed with the wallet's own signature (never a trading key's). Still only to the wallet.
  function withdrawFor(
    uint accountId,
    ICustodianAsset asset,
    uint amount,
    uint nonce,
    uint64 deadline,
    bytes calldata signature
  ) external nonReentrant {
    if (block.timestamp > deadline) revert BC_Expired();
    address wallet = _held(accountId);
    _verify(
      wallet,
      keccak256(abi.encode(WITHDRAW_TYPEHASH, accountId, address(asset), amount, nonce, deadline)),
      signature,
      false,
      nonce
    );
    _withdraw(accountId, asset, wallet, amount);
  }

  /// @notice The account, with everything in it, back to its wallet. Nothing the owner controls can stop it.
  function exit(uint accountId) external nonReentrant {
    address wallet = accountOwner[accountId];
    if (wallet == address(0)) revert BC_NotHeld();
    if (msg.sender != wallet) revert BC_NotWallet();
    _exit(accountId, wallet);
  }

  /// @notice `exit`, relayed with the wallet's own signature, for a wallet with no ETH.
  function exitFor(uint accountId, uint nonce, uint64 deadline, bytes calldata signature) external nonReentrant {
    if (block.timestamp > deadline) revert BC_Expired();
    address wallet = accountOwner[accountId];
    if (wallet == address(0)) revert BC_NotHeld();
    _verify(wallet, keccak256(abi.encode(EXIT_TYPEHASH, accountId, nonce, deadline)), signature, false, nonce);
    _exit(accountId, wallet);
  }

  //////////
  // Keys //
  //////////

  /// @notice The caller's trading key (zero revokes): it may take and act until `validUntil`, nothing else.
  function setTradingKey(address key, uint64 validUntil) external {
    _setTradingKey(msg.sender, key, validUntil);
  }

  function setTradingKeyFor(
    address wallet,
    address key,
    uint64 validUntil,
    uint nonce,
    uint64 deadline,
    bytes calldata signature
  ) external nonReentrant {
    if (block.timestamp > deadline) revert BC_Expired();
    _verify(
      wallet,
      keccak256(abi.encode(SET_TRADING_KEY_TYPEHASH, wallet, key, validUntil, nonce, deadline)),
      signature,
      false,
      nonce
    );
    _setTradingKey(wallet, key, validUntil);
  }

  /// @notice Burn one of the caller's nonces, cancelling a signature made with it.
  function cancelNonce(uint nonce) external {
    nonceUsed[msg.sender][nonce] = true;
    emit NonceUsed(msg.sender, nonce);
  }

  ///////////
  // Owner //
  ///////////

  /// @notice Start the 48-hour delay after which `target` may be enabled.
  function queue(Kind kind, address target) external onlyOwner {
    if (target == address(0)) revert BC_ZeroAddress();
    uint when = block.timestamp + DELAY;
    eta[kind][target] = when;
    emit Queued(kind, target, when);
  }

  function cancelQueued(Kind kind, address target) external onlyOwner {
    delete eta[kind][target];
    emit QueueCancelled(kind, target);
  }

  function enable(Kind kind, address target) external onlyOwner {
    uint when = eta[kind][target];
    if (when == 0) revert BC_NotQueued();
    if (block.timestamp < when) revert BC_TooEarly();
    delete eta[kind][target];
    _setAllowed(kind, target, true);
  }

  /// @notice Immediate: removing an entry only takes power away. Withdraw and exit never consult the allowlist.
  function disallow(Kind kind, address target) external onlyOwner {
    delete eta[kind][target];
    _setAllowed(kind, target, false);
  }

  function setPaused(bool paused_) external onlyOwner {
    paused = paused_;
    emit Paused(paused_);
  }

  ///////////
  // Views //
  ///////////

  function domainSeparator() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  /// @notice The digest a wallet or key signs for `t`.
  function takeDigest(Take calldata t) external view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(TAKE_TYPEHASH, t)));
  }

  //////////////
  // Internal //
  //////////////

  function _held(uint accountId) internal view returns (address wallet) {
    wallet = accountOwner[accountId];
    if (wallet == address(0)) revert BC_NotHeld();
  }

  /// @dev The wallet's signature, or its live trading key's when `keyMaySign`; then the signer's nonce is spent.
  function _verify(address wallet, bytes32 structHash, bytes calldata signature, bool keyMaySign, uint nonce)
    internal
    returns (address signer)
  {
    bytes32 digest = _hashTypedDataV4(structHash);
    if (SignatureChecker.isValidSignatureNow(wallet, digest, signature)) {
      signer = wallet;
    } else {
      TradingKey memory k = tradingKey[wallet];
      if (
        !keyMaySign || k.key == address(0) || block.timestamp > k.validUntil
          || !SignatureChecker.isValidSignatureNow(k.key, digest, signature)
      ) revert BC_BadSignature();
      signer = k.key;
    }
    if (nonceUsed[signer][nonce]) revert BC_NonceUsed();
    nonceUsed[signer][nonce] = true;
    emit NonceUsed(signer, nonce);
  }

  function _depositToken(ICustodianAsset asset) internal view returns (IERC20) {
    if (!allowed[Kind.Asset][address(asset)]) revert BC_NotAllowed();
    return asset.wrappedAsset();
  }

  function _deposit(uint accountId, ICustodianAsset asset, address from, uint amount) internal {
    IERC20 token = _depositToken(asset);
    token.safeTransferFrom(from, address(this), amount);
    token.forceApprove(address(asset), amount);
    asset.deposit(accountId, amount);
    emit Deposited(accountId, address(asset), from, amount);
  }

  function _withdraw(uint accountId, ICustodianAsset asset, address wallet, uint amount) internal {
    asset.withdraw(accountId, amount, wallet);
    emit Withdrawn(accountId, address(asset), wallet, amount);
  }

  /// @dev An account the margin engine moved out (its manager may) is already gone: the record is simply cleared.
  function _exit(uint accountId, address wallet) internal {
    delete accountOwner[accountId];
    if (subAccounts.ownerOf(accountId) == address(this)) {
      subAccounts.transferFrom(address(this), wallet, accountId);
    }
    emit Exited(accountId, wallet);
  }

  function _setTradingKey(address wallet, address key, uint64 validUntil) internal {
    tradingKey[wallet] = TradingKey({key: key, validUntil: key == address(0) ? 0 : validUntil});
    emit TradingKeySet(wallet, key, validUntil);
  }

  function _setAllowed(Kind kind, address target, bool value) internal {
    if (target == address(0)) revert BC_ZeroAddress();
    allowed[kind][target] = value;
    emit Allowed(kind, target, value);
  }

  /// @dev After a book or module call: the approval cleared, and the account still here.
  function _revokeAndCheck(uint accountId) internal {
    if (subAccounts.ownerOf(accountId) != address(this)) revert BC_AccountLeft();
    subAccounts.approve(address(0), accountId);
  }

  /// @dev The take cut to the position it reduces: a buy needs a short, a sell a long.
  function _reducing(Take calldata t) internal view returns (uint) {
    ICustodianBook.MarketView memory m = ICustodianBook(t.book).markets(t.marketId);
    int position = subAccounts.getBalance(t.accountId, IAsset(m.future), m.subId);
    if (t.isBuy ? position >= 0 : position <= 0) revert BC_NotReducing();
    uint size = uint(position < 0 ? -position : position);
    return t.amount < size ? t.amount : size;
  }
}
