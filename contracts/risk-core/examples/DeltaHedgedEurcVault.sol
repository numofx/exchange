// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IOnchainBook} from "../src/interfaces/IOnchainBook.sol";

/*
 * Example integration for the OnchainBook kit (spec C4.4, docs/onchain-book-integration.md). NOT AUDITED: it shows the
 * calls, not a product. One canary instance ran open and close on mainnet on 2026-11-17 (scripts/ops/OPS_BOX_CHANGES.md).
 *
 * A leveraged EURC basis position opened in ONE transaction with no off-chain party, composing a lending market, a spot
 * DEX and the futures book (the C0 test):
 *   1. flash-borrow USDC from Morpho Blue;
 *   2. buy EURC with it and the owner's equity on an Aerodrome Slipstream (concentrated-liquidity) pool;
 *   3. supply the EURC to a Morpho market as collateral and borrow USDC against it, repaying the flash loan;
 *   4. short EURC-USDC futures on the OnchainBook for the same EURC, so the vault is delta-neutral: long spot (as
 *      collateral), short the future; it earns the basis less the borrow rate.
 * `rehedge` later brings the future back to the collateral after the position or the collateral moved. `close` undoes
 * it in one transaction (buy the short back; flash-borrow the debt, repay, withdraw the collateral, sell it), and
 * `withdrawMargin` returns the futures account's cash: nothing the owner puts in stays locked in the contract.
 *
 * Only the external ABIs are used: IOnchainBook and the minimal interfaces below. Nothing imports the book's source.
 */

/// @dev SubAccounts (ERC721 accounts); IManager and IAsset parameters are addresses in the ABI.
interface ISubAccountsLite {
  function createAccount(address owner, address manager) external returns (uint);
  function setApprovalForAll(address operator, bool approved) external;
  function getBalance(uint accountId, address asset, uint subId) external view returns (int);
}

interface ICashLite {
  function deposit(uint recipientAccount, uint stableAmount) external;
  /// @dev only the account's owner (this contract) may call it; pays `recipient`
  function withdraw(uint accountId, uint stableAmount, address recipient) external;
}

interface IFutureLite {
  /// @dev underlying units per contract, 18 dp (1,000 EURC: 1000e18)
  function contractSize() external view returns (uint);
}

struct MorphoMarketParams {
  address loanToken;
  address collateralToken;
  address oracle;
  address irm;
  uint lltv;
}

interface IMorphoLite {
  function flashLoan(address token, uint assets, bytes calldata data) external;
  function supplyCollateral(MorphoMarketParams memory p, uint assets, address onBehalf, bytes memory data) external;
  function borrow(MorphoMarketParams memory p, uint assets, uint shares, address onBehalf, address receiver)
    external
    returns (uint, uint);
  function repay(MorphoMarketParams memory p, uint assets, uint shares, address onBehalf, bytes memory data)
    external
    returns (uint, uint);
  function withdrawCollateral(MorphoMarketParams memory p, uint assets, address onBehalf, address receiver) external;
  function position(bytes32 id, address user)
    external
    view
    returns (uint supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @dev Aerodrome Slipstream pool (Uniswap v3 swap interface and callback).
interface ICLPoolLite {
  function token0() external view returns (address);
  function swap(address recipient, bool zeroForOne, int amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
    external
    returns (int amount0, int amount1);
}

contract DeltaHedgedEurcVault {
  using SafeERC20 for IERC20;

  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  IOnchainBook public immutable book;
  uint public immutable marketId;
  ISubAccountsLite public immutable subAccounts;
  ICashLite public immutable cash;
  address public immutable future;
  uint96 public immutable subId;
  uint public immutable lotSize;
  IMorphoLite public immutable morpho;
  ICLPoolLite public immutable pool;
  IERC20 public immutable usdc;
  IERC20 public immutable eurc;
  address public immutable owner;
  /// @dev the vault's own account on the book's margin engine
  uint public immutable accountId;

  MorphoMarketParams public lending;
  bytes32 public immutable lendingId;
  /// @dev the flash loan's callback is accepted only inside `open` (1) or `close` (2); 0 otherwise
  uint8 internal flashMode;

  struct Hedge {
    /// @dev worst futures price, 18 dp: the lowest when shorting, the highest when buying back
    uint limitPrice;
    /// @dev the take's fee cap, cash 18 dp
    uint maxFee;
    /// @dev Data Streams reports to attach, abi.encode(bytes[]); empty to use the stored ones
    bytes reports;
  }

  struct Close {
    /// @dev buys the short back; its `limitPrice` is the highest acceptable
    Hedge hedge;
    /// @dev USDC flash-borrowed to repay the debt: at least the debt with interest to this block (the rest is returned)
    uint flash;
    /// @dev the least USDC the owner accepts back from the whole unwind
    uint minUsdcOut;
  }

  struct Open {
    /// @dev the owner's USDC, pulled in
    uint equity;
    /// @dev flash-borrowed USDC, then borrowed from the lending market against the EURC
    uint borrow;
    /// @dev the swap's minimum EURC out
    uint minEurc;
    Hedge hedge;
  }

  event Opened(uint usdcIn, uint eurcBought, uint borrowed, uint shortFilled, uint avgPrice);
  event Rehedged(bool isBuy, uint filled, uint avgPrice);
  event Closed(uint boughtBack, uint eurcSold, uint usdcOut);

  error NotOwner();
  error NotCallback();
  error SwapTooSmall();
  error NotShort();

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor(
    IOnchainBook book_,
    uint marketId_,
    IMorphoLite morpho_,
    MorphoMarketParams memory lending_,
    ICLPoolLite pool_,
    address owner_
  ) {
    book = book_;
    marketId = marketId_;
    IOnchainBook.MarketView memory m = book_.markets(marketId_);
    subAccounts = ISubAccountsLite(book_.subAccounts());
    cash = ICashLite(book_.cash());
    future = m.future;
    subId = m.subId;
    lotSize = m.lotSize;
    morpho = morpho_;
    lending = lending_;
    lendingId = keccak256(abi.encode(lending_));
    pool = pool_;
    usdc = IERC20(lending_.loanToken);
    eurc = IERC20(lending_.collateralToken);
    owner = owner_;

    // The vault owns its account, so the book needs the vault's permission to move its positions and cash.
    accountId = subAccounts.createAccount(address(this), m.engine);
    subAccounts.setApprovalForAll(address(book_), true);
  }

  /// @notice USDC into the vault's futures account, as margin for the short and its fees.
  function depositMargin(uint amount) external onlyOwner {
    usdc.safeTransferFrom(msg.sender, address(this), amount);
    usdc.forceApprove(address(cash), amount);
    cash.deposit(accountId, amount);
  }

  /// @notice Open (or add to) the hedged position in one transaction; see the file header.
  function open(Open calldata p) external onlyOwner returns (uint eurcBought, uint shortFilled) {
    usdc.safeTransferFrom(msg.sender, address(this), p.equity);
    flashMode = 1;
    morpho.flashLoan(address(usdc), p.borrow, abi.encode(p));
    flashMode = 0;
    (eurcBought, shortFilled) = (_lastBought, _lastShort);
  }

  /// @dev the callback's results, read back by `open`
  uint internal _lastBought;
  uint internal _lastShort;

  /// @dev Morpho's flash-loan callback: Morpho pulls `assets` back from this contract when it returns.
  function onMorphoFlashLoan(uint assets, bytes calldata data) external {
    if (msg.sender != address(morpho) || flashMode == 0) revert NotCallback();
    if (flashMode == 2) return _closeLending(assets);
    Open memory p = abi.decode(data, (Open));

    // 2. Spot: all the USDC into EURC.
    uint bought = _swap(true, p.equity + assets);
    if (bought < p.minEurc) revert SwapTooSmall();

    // 3. Lending: the EURC as collateral, the flash loan's USDC borrowed against it.
    eurc.forceApprove(address(morpho), bought);
    morpho.supplyCollateral(lending, bought, address(this), "");
    morpho.borrow(lending, assets, 0, address(this), address(this));
    usdc.forceApprove(address(morpho), assets);

    // 4. Futures: short the same EURC, all or nothing (minFill = amount), so the result is delta-neutral to a lot.
    uint amount = _positionFor(bought);
    (uint filled, uint avg) = _take(false, amount, p.hedge);

    _lastBought = bought;
    _lastShort = filled;
    emit Opened(p.equity + assets, bought, assets, filled, avg);
  }

  /// @notice EURC exposure, 6 dp: the collateral held on the lending market plus the futures position (negative when
  ///         short). Zero, to within a lot, when hedged.
  function delta() public view returns (int) {
    (,, uint128 collateral) = morpho.position(lendingId, address(this));
    int pos = subAccounts.getBalance(accountId, future, subId);
    return int(uint(collateral)) + pos * int(IFutureLite(future).contractSize()) / 1e30;
  }

  /// @notice Take on the book to bring `delta()` back under one lot (after the collateral or the position changed).
  function rehedge(Hedge calldata h) external onlyOwner returns (uint filled, uint avg) {
    int d = delta();
    bool isBuy = d < 0; // net short: buy futures back
    uint amount = _positionFor(uint(d < 0 ? -d : d));
    if (amount == 0) return (0, 0);
    (filled, avg) = _take(isBuy, amount, h);
    emit Rehedged(isBuy, filled, avg);
  }

  /// @notice Unwind in one transaction: buy the whole short back (all or nothing), then repay the loan with a flash loan,
  ///         withdraw all the collateral and sell it, and send the owner every USDC left. The futures account's cash
  ///         stays: `withdrawMargin` returns it.
  function close(Close calldata c) external onlyOwner returns (uint usdcOut) {
    int pos = subAccounts.getBalance(accountId, future, subId);
    if (pos > 0) revert NotShort();
    uint boughtBack;
    if (pos < 0) (boughtBack,) = _take(true, uint(-pos), c.hedge);

    flashMode = 2;
    morpho.flashLoan(address(usdc), c.flash, "");
    flashMode = 0;

    usdcOut = usdc.balanceOf(address(this));
    if (usdcOut < c.minUsdcOut) revert SwapTooSmall();
    usdc.safeTransfer(owner, usdcOut);
    emit Closed(boughtBack, _lastSold, usdcOut);
  }

  /// @notice The futures account's cash back to the owner, in USDC units (6 dp). Fails while a position needs it.
  function withdrawMargin(uint amount) external onlyOwner {
    cash.withdraw(accountId, amount, owner);
  }

  uint internal _lastSold;

  /// @dev `close`'s flash-loan step: Morpho pulls `assets` back when this returns.
  function _closeLending(uint assets) internal {
    (, uint128 borrowShares, uint128 collateral) = morpho.position(lendingId, address(this));
    if (borrowShares > 0) {
      usdc.forceApprove(address(morpho), assets);
      morpho.repay(lending, 0, borrowShares, address(this), "");
    }
    if (collateral > 0) morpho.withdrawCollateral(lending, collateral, address(this), address(this));
    _lastSold = collateral;
    if (collateral > 0) _swap(false, collateral);
    usdc.forceApprove(address(morpho), assets);
  }

  /// @dev Pegged and self-priced quotes alike; `minFill = amount`, so a partial fill reverts the whole transaction.
  function _take(bool isBuy, uint amount, Hedge memory h) internal returns (uint filled, uint avg) {
    IOnchainBook.TakeOrder memory o = IOnchainBook.TakeOrder({
      marketId: marketId,
      takerAccountId: accountId,
      isBuy: isBuy,
      amount: amount,
      limitPrice: h.limitPrice,
      minFill: amount,
      maxFee: h.maxFee,
      deadline: uint64(block.timestamp),
      maxLevels: 50,
      selfTradeMode: IOnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
    return book.take(o, h.reports);
  }

  /// @dev EURC (6 dp) to futures position units (18 dp contracts), rounded down to whole lots.
  function _positionFor(uint eurcAmount) internal view returns (uint) {
    uint units = eurcAmount * 1e30 / IFutureLite(future).contractSize();
    return units / lotSize * lotSize;
  }

  /// @dev Exact-in swap on the pool: USDC for EURC (`usdcIn`), or EURC for USDC. Returns what came out.
  function _swap(bool usdcIn, uint amountIn) internal returns (uint out) {
    bool zeroForOne = (pool.token0() == address(usdc)) == usdcIn;
    (int a0, int a1) =
      pool.swap(address(this), zeroForOne, int(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, "");
    out = uint(-(zeroForOne ? a1 : a0));
  }

  /// @dev The pool's swap callback: pay what it is owed, in whichever token that is.
  function uniswapV3SwapCallback(int amount0Delta, int amount1Delta, bytes calldata) external {
    if (msg.sender != address(pool)) revert NotCallback();
    address t0 = pool.token0();
    if (amount0Delta > 0) IERC20(t0).safeTransfer(msg.sender, uint(amount0Delta));
    if (amount1Delta > 0) {
      IERC20(t0 == address(usdc) ? address(eurc) : address(usdc)).safeTransfer(msg.sender, uint(amount1Delta));
    }
  }
}
