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
import {IAllowances} from "../interfaces/IAllowances.sol";
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

/**
 * @notice An action module (FIFO post, cancel, ...). It is never ERC-721 approved: it may move only what the signer
 *         granted it as SubAccounts subId allowances, for the call or (`persist`) until spent, cleared or exit.
 *         `signer` is the wallet, or its trading key (only for modules the owner also allowed as a KeyModule).
 */
interface IBookCustodianModule {
  function onAct(uint accountId, address wallet, address signer, bytes calldata data) external;
}

/**
 * @title BookCustodian
 * @notice Holds app users' SubAccounts accounts so the OnchainBooks (and, later, timelocked action modules such as a
 *         FIFO book) can act on them, without the venue holding any power over the money in them
 *         (docs/book-custodian-spec.md). Each account is recorded to one wallet. What the contract guarantees:
 *
 *         1. Only the wallet withdraws, and only to itself. A trading key can take, and act through modules the owner
 *            allowed for keys; never withdraw, exit, use other modules or change keys.
 *         2. `exit` always works: the wallet gets its account back (positions and balances), with no pause, no
 *            allowlist, no cooldown and no relayer in the way, and every allowance this contract left on it zeroed.
 *         3. The owner has no function that moves an account, a balance or a position. No upgrade, no delegatecall.
 *         4. Nothing is ever ERC-721 approved on an account, so nothing can re-delegate it. A book may move only the
 *            signed order (its size on that series, its `maxFee` in cash), zeroed after the call. A module may move
 *            only what the signer granted it. Books, modules, managers and deposit assets become usable only 48 hours
 *            after the owner queues them, so users can leave first.
 *         5. A signature authorizes one action, once: EIP-712, per-signer nonces, a deadline, and the account inside
 *            what is signed.
 *
 *         Below this contract, as for every account: the vault's admin powers on SubAccounts, the assets and the
 *         MarginEngine, liquidation, and token issuers' freezes.
 */
contract BookCustodian is Ownable2Step, ReentrancyGuard, EIP712, IERC721Receiver {
  using SafeERC20 for IERC20;

  /// @dev KeyModule: a module a trading key may call (it must also be allowed as a Module)
  enum Kind {
    Manager,
    Asset,
    Book,
    Module,
    KeyModule
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

  /// @dev A subId allowance granted to a module, in SubAccounts' terms.
  struct Grant {
    address asset;
    uint subId;
    uint positive;
    uint negative;
  }

  /// @dev What a wallet (or, for a KeyModule, its trading key) signs for a module call. Fields in ACT_TYPEHASH order.
  struct Action {
    uint accountId;
    address module;
    bytes data;
    Grant[] grants;
    bool persist;
    uint nonce;
    uint64 deadline;
  }

  /// @dev A persisted grant's key, zeroed on `clearGrants` or exit.
  struct GrantKey {
    address module;
    address asset;
    uint subId;
  }

  uint public constant DELAY = 48 hours;
  /// @dev bounds the zeroing loop in `exit`
  uint public constant MAX_PERSISTED_GRANTS = 16;
  /// @dev OnchainBook.SelfTradeMode.Abort
  uint8 internal constant SELF_TRADE_ABORT = 0;

  bytes32 public constant TAKE_TYPEHASH = keccak256(
    "Take(uint256 accountId,address book,uint256 marketId,bool isBuy,uint256 amount,uint256 limitPrice,uint256 minFill,uint256 maxFee,uint64 deadline,uint16 maxLevels,bool reduceOnly,uint256 nonce)"
  );
  bytes32 public constant GRANT_TYPEHASH =
    keccak256("Grant(address asset,uint256 subId,uint256 positive,uint256 negative)");
  bytes32 public constant ACT_TYPEHASH = keccak256(
    "Act(uint256 accountId,address module,bytes data,Grant[] grants,bool persist,uint256 nonce,uint64 deadline)Grant(address asset,uint256 subId,uint256 positive,uint256 negative)"
  );
  bytes32 public constant WITHDRAW_TYPEHASH =
    keccak256("Withdraw(uint256 accountId,address asset,uint256 amount,uint256 nonce,uint64 deadline)");
  bytes32 public constant EXIT_TYPEHASH = keccak256("Exit(uint256 accountId,uint256 nonce,uint64 deadline)");
  bytes32 public constant SET_TRADING_KEY_TYPEHASH =
    keccak256("SetTradingKey(address wallet,address key,uint64 validUntil,uint256 nonce,uint64 deadline)");

  ISubAccounts public immutable subAccounts;
  /// @notice The cash every book charges its fee in; a take's fee allowance is on this asset and no other.
  IAsset public immutable cash;

  /// @notice The wallet each held account belongs to; zero for an account this contract does not hold.
  mapping(uint accountId => address wallet) public accountOwner;
  mapping(address wallet => TradingKey) public tradingKey;
  mapping(address signer => mapping(uint nonce => bool)) public nonceUsed;
  mapping(Kind => mapping(address => bool)) public allowed;
  /// @notice When a queued entry may be enabled; zero when nothing is queued.
  mapping(Kind => mapping(address => uint)) public eta;
  /// @notice Pauses takes and module actions only: never withdrawal, exit, grant clearing or key changes.
  bool public paused;
  mapping(uint accountId => GrantKey[]) internal _persisted;

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
  event Acted(uint indexed accountId, address indexed module, address signer, bool persist);
  event GrantsCleared(uint indexed accountId);
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
  error BC_PermitFailed();
  error BC_NotOwnerSending();
  error BC_TooManyGrants();

  /// @param initialKinds,initialTargets allowed at once: there are no accounts to protect before deployment
  constructor(
    ISubAccounts subAccounts_,
    IAsset cash_,
    address owner_,
    Kind[] memory initialKinds,
    address[] memory initialTargets
  ) Ownable(owner_) EIP712("NumoBookCustodian", "1") {
    if (initialKinds.length != initialTargets.length) revert BC_LengthMismatch();
    if (address(cash_) == address(0)) revert BC_ZeroAddress();
    subAccounts = subAccounts_;
    cash = cash_;
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

  /**
   * @notice A wallet sends its own account in with `safeTransferFrom`, and it is recorded to that wallet. Only the
   *         owner itself may send it (not an approved operator or the account's manager), so the record is always an
   *         address that chose to be here and so can call `exit`.
   */
  function onERC721Received(address operator, address from, uint accountId, bytes calldata)
    external
    nonReentrant
    returns (bytes4)
  {
    if (msg.sender != address(subAccounts)) revert BC_NotSubAccounts();
    if (from == address(0)) revert BC_ZeroAddress();
    if (operator != from) revert BC_NotOwnerSending();
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
   * @notice Deposit the wallet's tokens into its own account with an EIP-2612 permit, relayed by anyone. A relayer's
   *         call needs the permit to succeed, or (it was front-run) to have left exactly `amount` approved: nobody but
   *         the wallet can pull a standing approval.
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
    try IERC20Permit(address(token)).permit(wallet, address(this), amount, permitDeadline, v, r, s) {}
    catch {
      if (msg.sender != wallet && token.allowance(wallet, address(this)) != amount) revert BC_PermitFailed();
    }
    _deposit(accountId, asset, wallet, amount);
  }

  /////////////
  // Trading //
  /////////////

  /**
   * @notice A take on an allowed book for the signed account, signed by its wallet or its trading key. `reports` are
   *         Data Streams reports for the book's index (the book verifies them), so a relayer may attach fresh ones.
   */
  function take(Take calldata t, bytes calldata signature, bytes calldata reports)
    external
    nonReentrant
    returns (uint filled, uint avgPrice)
  {
    if (paused) revert BC_Paused();
    if (block.timestamp > t.deadline) revert BC_Expired();
    address wallet = _held(t.accountId);
    _verify(wallet, keccak256(abi.encode(TAKE_TYPEHASH, t)), signature, true, t.nonce);
    if (!allowed[Kind.Book][t.book]) revert BC_NotAllowed();

    ICustodianBook.MarketView memory m = ICustodianBook(t.book).markets(t.marketId);
    uint amount = t.reduceOnly ? _reducing(t, m) : t.amount;

    // The book may move exactly the order: its size on the series in the order's direction, and its fee in cash.
    IAllowances.SubIdAllowance[] memory a = new IAllowances.SubIdAllowance[](2);
    a[0] = IAllowances.SubIdAllowance({
      asset: IAsset(m.future), subId: m.subId, positive: t.isBuy ? amount : 0, negative: t.isBuy ? 0 : amount
    });
    a[1] = IAllowances.SubIdAllowance({asset: cash, subId: 0, positive: 0, negative: t.maxFee});
    subAccounts.setSubIdAllowances(t.accountId, t.book, a);

    (filled, avgPrice) = ICustodianBook(t.book)
      .take(
        ICustodianBook.TakeOrder({
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
      }),
        reports
      );

    _checkHeld(t.accountId);
    a[0].positive = 0;
    a[0].negative = 0;
    a[1].negative = 0;
    subAccounts.setSubIdAllowances(t.accountId, t.book, a);
    emit Took(t.accountId, t.book, t.marketId, t.isBuy, filled, avgPrice);
  }

  /**
   * @notice A call to an allowed module with the subId allowances the signer grants it. Without `persist` they are
   *         zeroed after the call; with it (a resting order) they stay, recorded, until `clearGrants` or `exit`.
   *         A trading key may sign only for a module also allowed as a KeyModule.
   */
  function act(Action calldata x, bytes calldata signature) external nonReentrant {
    if (paused) revert BC_Paused();
    if (block.timestamp > x.deadline) revert BC_Expired();
    address wallet = _held(x.accountId);
    address signer = _verify(wallet, _actHash(x), signature, true, x.nonce);
    if (!allowed[Kind.Module][x.module]) revert BC_NotAllowed();
    if (signer != wallet && !allowed[Kind.KeyModule][x.module]) revert BC_NotAllowed();

    IAllowances.SubIdAllowance[] memory a = _allowances(x.grants);
    if (a.length > 0) subAccounts.setSubIdAllowances(x.accountId, x.module, a);
    if (x.persist) _persist(x);

    IBookCustodianModule(x.module).onAct(x.accountId, wallet, signer, x.data);

    _checkHeld(x.accountId);
    if (!x.persist && a.length > 0) {
      for (uint i; i < a.length; ++i) {
        a[i].positive = 0;
        a[i].negative = 0;
      }
      subAccounts.setSubIdAllowances(x.accountId, x.module, a);
    }
    emit Acted(x.accountId, x.module, signer, x.persist);
  }

  /// @notice The wallet zeroes every persisted grant on its account (resting orders lose their power to settle).
  function clearGrants(uint accountId) external nonReentrant {
    if (msg.sender != _held(accountId)) revert BC_NotWallet();
    _clearGrants(accountId);
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

  /// @notice Immediate: no new take or action with `target`. Withdraw and exit never consult the allowlist. A
  ///         disallowed module's persisted grants stay until the wallet clears them or exits.
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

  /// @notice The digest a wallet or key signs for an `act`.
  function actDigest(Action calldata x) external view returns (bytes32) {
    return _hashTypedDataV4(_actHash(x));
  }

  function persistedGrants(uint accountId) external view returns (GrantKey[] memory) {
    return _persisted[accountId];
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

  /// @dev EIP-712 hashStruct of Act: `bytes` as its keccak, `Grant[]` as the keccak of its members' struct hashes.
  function _actHash(Action calldata x) internal pure returns (bytes32) {
    bytes32[] memory g = new bytes32[](x.grants.length);
    for (uint i; i < x.grants.length; ++i) {
      g[i] = keccak256(abi.encode(GRANT_TYPEHASH, x.grants[i]));
    }
    return keccak256(
      abi.encode(
        ACT_TYPEHASH,
        x.accountId,
        x.module,
        keccak256(x.data),
        keccak256(abi.encodePacked(g)),
        x.persist,
        x.nonce,
        x.deadline
      )
    );
  }

  function _persist(Action calldata x) internal {
    GrantKey[] storage keys = _persisted[x.accountId];
    if (keys.length + x.grants.length > MAX_PERSISTED_GRANTS) revert BC_TooManyGrants();
    for (uint i; i < x.grants.length; ++i) {
      keys.push(GrantKey({module: x.module, asset: x.grants[i].asset, subId: x.grants[i].subId}));
    }
  }

  function _allowances(Grant[] calldata grants) internal pure returns (IAllowances.SubIdAllowance[] memory a) {
    a = new IAllowances.SubIdAllowance[](grants.length);
    for (uint i; i < grants.length; ++i) {
      a[i] = IAllowances.SubIdAllowance({
        asset: IAsset(grants[i].asset),
        subId: grants[i].subId,
        positive: grants[i].positive,
        negative: grants[i].negative
      });
    }
  }

  function _clearGrants(uint accountId) internal {
    GrantKey[] storage keys = _persisted[accountId];
    IAllowances.SubIdAllowance[] memory zero = new IAllowances.SubIdAllowance[](1);
    for (uint i; i < keys.length; ++i) {
      zero[0] =
        IAllowances.SubIdAllowance({asset: IAsset(keys[i].asset), subId: keys[i].subId, positive: 0, negative: 0});
      subAccounts.setSubIdAllowances(accountId, keys[i].module, zero);
    }
    delete _persisted[accountId];
    emit GrantsCleared(accountId);
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

  /**
   * @dev Persisted grants are zeroed first (bounded by MAX_PERSISTED_GRANTS), so none revives if the account comes
   *      back. An account the margin engine moved out (its manager may) is already gone: the record is just cleared.
   */
  function _exit(uint accountId, address wallet) internal {
    delete accountOwner[accountId];
    if (subAccounts.ownerOf(accountId) == address(this)) {
      if (_persisted[accountId].length > 0) _clearGrants(accountId);
      subAccounts.transferFrom(address(this), wallet, accountId);
    } else {
      delete _persisted[accountId];
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

  /// @dev After a book or module call, the account must still be here.
  function _checkHeld(uint accountId) internal view {
    if (subAccounts.ownerOf(accountId) != address(this)) revert BC_AccountLeft();
  }

  /// @dev The take cut to the position it reduces (a buy needs a short, a sell a long), in whole lots.
  function _reducing(Take calldata t, ICustodianBook.MarketView memory m) internal view returns (uint) {
    int position = subAccounts.getBalance(t.accountId, IAsset(m.future), m.subId);
    if (t.isBuy ? position >= 0 : position <= 0) revert BC_NotReducing();
    uint size = uint(position < 0 ? -position : position);
    if (m.lotSize > 0) size -= size % m.lotSize;
    return t.amount < size ? t.amount : size;
  }
}
