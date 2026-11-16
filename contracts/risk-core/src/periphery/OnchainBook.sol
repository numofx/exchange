// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable2Step.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";
import "openzeppelin/utils/math/SafeCast.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IAllowances} from "../interfaces/IAllowances.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {IFutureAssetV3} from "../interfaces/IFutureAssetV3.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {StreamsIndexAdapter} from "../feeds/StreamsIndexAdapter.sol";

/// @dev EurcIndexFeed's adapter: the book pegs to the reports the future's band check reads.
interface IIndexFeedAdapter {
  function adapter() external view returns (address);
}

/// @dev The two manager reads a maker check needs. Both exist on MarginEngine (BaseManager.liquidation, getMargin).
interface IOnchainBookManager {
  function liquidation() external view returns (IDutchAuction);
  function getMargin(uint accountId, bool isInitial) external view returns (int);
}

interface IOnchainBookManagerWhitelist {
  function whitelistedManager(address manager) external view returns (bool);
}

/**
 * @title OnchainBook
 * @notice On-chain matching for dated futures (docs/eurc-usdc-futures-spec.md, Part B). Makers quote with curves pegged
 *         to the Data Streams index and repriced by one update; anyone takes against them directly and atomically.
 *         Runs beside `Matching`: makers and takers use their own subaccounts, outside `Matching`, and grant this
 *         contract allowances on the future and on cash (B3). Once granted, this code is the only thing protecting
 *         those accounts.
 *
 *         Prices are in ticks of `tickSize` (18 dp quote per base). Sizes are in lots of `lotSize` (the future's
 *         18 dp position units; one contract is 1e18). A maker's mid is `index + offsetTicks - skew`; its bid curve
 *         sits `halfSpreadTicks + region offset` below it and its ask curve the same above.
 *
 *         Settlement of a fill is the transfer `TradeModule` builds for a dated future (B5): the position, with the
 *         fill price in `assetData` and no quote leg, plus the taker fee in cash. One `submitTransfers` per maker, in
 *         `try/catch`, so one failing maker cannot freeze the market (B5a).
 */
contract OnchainBook is Ownable2Step, ReentrancyGuard {
  using SafeCast for uint;
  using SafeCast for int;

  uint public constant MAX_REGIONS = 10;
  /// @dev At a 1 gwei priority fee, at most 10 USDC (18 dp) of tax a take
  uint public constant MAX_PRIORITY_TAX_RATE = 1e10;

  /////////////
  // Structs //
  /////////////

  struct Market {
    IFutureAssetV3 future;
    /// @dev the margin engine every maker account must be under; the only manager this contract ever calls
    IOnchainBookManager engine;
    uint96 subId;
    uint64 expiry;
    uint64 lastTradeTime;
    StreamsIndexAdapter adapter;
    /// @dev quote per base, 18 dp, per tick
    uint tickSize;
    /// @dev position units per lot
    uint lotSize;
    /// @dev taker fee as a fraction of notional, 18 dp
    uint takerFeeRate;
    /// @dev splines quote only while both streams' stored reports are at most this old (B6a)
    uint32 takeMaxAge;
    uint32 maxTtl;
    uint16 maxMakers;
    bool enabled;
  }

  /// @dev One region of a curve: `lots` available at `offsetTicks` beyond the half spread.
  struct Region {
    uint32 lots;
    uint32 offsetTicks;
  }

  struct Spline {
    int32 offsetTicks;
    uint32 halfSpreadTicks;
    uint16 bidCurve;
    uint16 askCurve;
    uint32 skewTicksPerLot;
    uint32 maxSkewTicks;
    uint32 refillLotsPerSecond;
    uint40 updatedAt;
    uint32 ttl;
    uint64 seq;
    bool active;
    /// @dev the account's owner when the spline was written: a transfer of the account takes the spline down, so a
    ///      new owner (allowlisted or not) quotes only through its own update
    address owner;
  }

  struct SplineUpdate {
    uint marketId;
    uint accountId;
    int32 offsetTicks;
    uint32 halfSpreadTicks;
    uint16 bidCurve;
    uint16 askCurve;
    uint32 skewTicksPerLot;
    uint32 maxSkewTicks;
    uint32 refillLotsPerSecond;
    uint32 ttl;
    uint64 seq;
  }

  /// @dev Lots taken from the top of one side of a spline, refilling at `refillLotsPerSecond` (B7).
  struct Cursor {
    uint64 consumedLots;
    uint40 at;
  }

  enum SelfTradeMode {
    Abort,
    DecrementTake
  }

  struct TakeOrder {
    uint marketId;
    uint takerAccountId;
    bool isBuy;
    /// @dev position units; rounded down to whole lots
    uint amount;
    /// @dev worst acceptable price, 18 dp
    uint limitPrice;
    /// @dev revert if less is filled, position units
    uint minFill;
    /// @dev fee plus priority-fee tax, in cash (18 dp); revert if exceeded
    uint maxFee;
    uint64 deadline;
    uint16 maxLevels;
    SelfTradeMode selfTradeMode;
    bytes managerData;
  }

  enum DeactivationReason {
    AllowanceTooLow,
    AuctionLive,
    BelowInitialMargin
  }

  /// @dev A take's running totals across rounds.
  struct Pass {
    uint remainingLots;
    uint levelsLeft;
    bool[] excluded;
    uint filledLots;
    uint notionalTicks;
    uint fee;
  }

  /// @dev In-memory state of one maker during a take.
  struct MakerState {
    uint accountId;
    address owner;
    uint16 curveId;
    int midTicks;
    uint32 halfSpreadTicks;
    uint8 region;
    uint regionLotsLeft;
    uint curveLotsLeft;
    uint filledLots;
    uint notionalTicks;
    bool done;
  }

  ///////////////
  // Variables //
  ///////////////

  ISubAccounts public immutable subAccounts;
  IAsset public immutable cash;

  uint public feeRecipient;
  /// @dev minimum gas left before each maker's settlement call (B5a, the 63/64 rule)
  uint public gasFloor;
  /// @dev cash (18 dp) charged per wei of priority fee per gas; 0 is off (B8)
  uint public priorityTaxRate;

  uint public nextMarketId = 1;
  mapping(uint marketId => Market) public markets;
  mapping(uint marketId => uint[] accountIds) internal _makers;
  mapping(uint marketId => mapping(uint accountId => bool)) public isRegistered;
  mapping(uint marketId => mapping(uint accountId => Spline)) public splines;
  mapping(uint marketId => mapping(uint accountId => mapping(bool isBid => Cursor))) public cursors;

  mapping(address owner => mapping(uint16 curveId => Region[])) internal _curves;
  mapping(address owner => bool) public makerAllowed;

  ////////////
  // Events //
  ////////////

  event MarketCreated(uint indexed marketId, address future, uint96 subId, address adapter);
  event MarketParamsSet(
    uint indexed marketId, uint takerFeeRate, uint32 takeMaxAge, uint32 maxTtl, uint16 maxMakers, bool enabled
  );
  event FeeRecipientSet(uint feeRecipient);
  event GasFloorSet(uint gasFloor);
  event PriorityTaxRateSet(uint rate);
  event MakerAllowedSet(address indexed owner, bool allowed);
  event MakerRemoved(uint indexed marketId, uint indexed accountId);

  event CurvesSet(address indexed owner, uint16 indexed curveId, Region[] regions);
  event SplineRegistered(uint indexed marketId, uint indexed accountId);
  event SplineUpdated(uint indexed marketId, uint indexed accountId, uint64 seq);
  event SplineCancelled(uint indexed marketId, uint indexed accountId);
  event Fill(
    uint indexed marketId,
    uint indexed takerAccountId,
    uint indexed makerAccountId,
    bool isBuy,
    uint amount,
    uint price,
    uint fee
  );
  event TakeExecuted(
    uint indexed marketId, uint indexed takerAccountId, bool isBuy, uint filled, uint avgPrice, uint fee
  );
  event MakerSkipped(uint indexed marketId, uint indexed accountId, bytes reason);
  event MakerDeactivated(uint indexed marketId, uint indexed accountId, DeactivationReason reason);

  ////////////
  // Errors //
  ////////////

  error OB_InvalidMarket();
  error OB_InvalidParams();
  error OB_MarketDisabled();
  error OB_TradingClosed();
  error OB_Expired();
  error OB_NotAuthorized();
  error OB_MakerNotAllowed();
  error OB_TooManyMakers();
  error OB_AlreadyRegistered();
  error OB_NotRegistered();
  error OB_InvalidCurve();
  error OB_StaleSeq();
  error OB_CrossedSpline();
  error OB_InvalidTtl();
  error OB_TakerAllowanceTooLow();
  error OB_FeeTooHigh();
  error OB_BelowMinFill();
  error OB_SelfTrade();
  error OB_GasFloor();
  error OB_WrongManager();
  error OB_BatchOutOfGas();

  constructor(ISubAccounts subAccounts_, IAsset cash_, uint feeRecipient_) Ownable(msg.sender) {
    subAccounts = subAccounts_;
    cash = cash_;
    feeRecipient = feeRecipient_;
  }

  ///////////
  // Admin //
  ///////////

  function createMarket(
    IFutureAssetV3 future,
    uint96 subId,
    IOnchainBookManager engine,
    StreamsIndexAdapter adapter,
    uint tickSize,
    uint lotSize
  ) external onlyOwner returns (uint marketId) {
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    if (
      !c.listed || c.settled || address(adapter) == address(0) || tickSize == 0 || lotSize == 0
        || !IOnchainBookManagerWhitelist(address(future)).whitelistedManager(address(engine))
        || IIndexFeedAdapter(address(future.indexFeed())).adapter() != address(adapter)
    ) revert OB_InvalidParams();
    marketId = nextMarketId++;
    Market storage m = markets[marketId];
    m.future = future;
    m.engine = engine;
    m.subId = subId;
    m.expiry = c.expiry;
    m.lastTradeTime = c.lastTradeTime;
    m.adapter = adapter;
    m.tickSize = tickSize;
    m.lotSize = lotSize;
    emit MarketCreated(marketId, address(future), subId, address(adapter));
  }

  /// @notice A market opens only through here, after its parameters are set.
  function setMarketParams(
    uint marketId,
    uint takerFeeRate,
    uint32 takeMaxAge,
    uint32 maxTtl,
    uint16 maxMakers,
    bool enabled
  ) external onlyOwner {
    Market storage m = _market(marketId);
    if (takerFeeRate > 0.01e18 || takeMaxAge == 0 || maxTtl == 0 || maxMakers == 0) revert OB_InvalidParams();
    m.takerFeeRate = takerFeeRate;
    m.takeMaxAge = takeMaxAge;
    m.maxTtl = maxTtl;
    m.maxMakers = maxMakers;
    m.enabled = enabled;
    emit MarketParamsSet(marketId, takerFeeRate, takeMaxAge, maxTtl, maxMakers, enabled);
  }

  function setFeeRecipient(uint feeRecipient_) external onlyOwner {
    feeRecipient = feeRecipient_;
    emit FeeRecipientSet(feeRecipient_);
  }

  function setGasFloor(uint gasFloor_) external onlyOwner {
    gasFloor = gasFloor_;
    emit GasFloorSet(gasFloor_);
  }

  function setPriorityTaxRate(uint rate) external onlyOwner {
    if (rate > MAX_PRIORITY_TAX_RATE) revert OB_InvalidParams();
    priorityTaxRate = rate;
    emit PriorityTaxRateSet(rate);
  }

  function setMakerAllowed(address owner_, bool allowed) external onlyOwner {
    makerAllowed[owner_] = allowed;
    emit MakerAllowedSet(owner_, allowed);
  }

  /// @notice Remove a maker from a market's list, keeping the others' registration order.
  function removeMaker(uint marketId, uint accountId) external onlyOwner {
    if (!isRegistered[marketId][accountId]) revert OB_NotRegistered();
    uint[] storage list = _makers[marketId];
    uint n = list.length;
    uint i;
    while (list[i] != accountId) ++i;
    for (; i + 1 < n; ++i) {
      list[i] = list[i + 1];
    }
    list.pop();
    isRegistered[marketId][accountId] = false;
    splines[marketId][accountId].active = false;
    emit MakerRemoved(marketId, accountId);
  }

  ///////////
  // Maker //
  ///////////

  /// @notice Store a curve under the caller. Offsets must not decrease; each region holds at least one lot.
  function setCurve(uint16 curveId, Region[] calldata regions) external nonReentrant {
    if (regions.length == 0 || regions.length > MAX_REGIONS) revert OB_InvalidCurve();
    Region[] storage stored = _curves[msg.sender][curveId];
    while (stored.length > 0) stored.pop();
    uint32 prev;
    for (uint i; i < regions.length; ++i) {
      if (regions[i].lots == 0 || regions[i].offsetTicks < prev) revert OB_InvalidCurve();
      prev = regions[i].offsetTicks;
      stored.push(regions[i]);
    }
    emit CurvesSet(msg.sender, curveId, regions);
  }

  function registerMaker(uint marketId, uint accountId) external nonReentrant {
    Market storage m = _market(marketId);
    address owner_ = _authorize(accountId);
    if (!makerAllowed[owner_]) revert OB_MakerNotAllowed();
    if (isRegistered[marketId][accountId]) revert OB_AlreadyRegistered();
    // Every take calls into a maker's manager: only the market's engine, never one the maker chose. Checked once:
    // SubAccounts sets an account's manager at creation and has no way to change it.
    if (address(subAccounts.manager(accountId)) != address(m.engine)) revert OB_WrongManager();
    if (_makers[marketId].length >= m.maxMakers) revert OB_TooManyMakers();
    _makers[marketId].push(accountId);
    isRegistered[marketId][accountId] = true;
    emit SplineRegistered(marketId, accountId);
  }

  /// @notice Reprice any number of splines. Each update's seq must exceed the stored one; it resets both cursors and
  ///         reactivates the spline.
  function updateSplines(SplineUpdate[] calldata updates) external nonReentrant {
    for (uint i; i < updates.length; ++i) {
      _updateSpline(updates[i]);
    }
  }

  function cancelSpline(uint marketId, uint accountId) external nonReentrant {
    _authorize(accountId);
    splines[marketId][accountId].active = false;
    emit SplineCancelled(marketId, accountId);
  }

  /// @notice Anyone may switch off a maker that is below initial margin, in an auction, or has withdrawn its
  ///         allowance. Position-reducing fills are held only to maintenance, but deactivating here is simpler (B5a).
  function poke(uint marketId, uint accountId) external nonReentrant {
    Market storage m = _market(marketId);
    Spline storage s = splines[marketId][accountId];
    if (!s.active) return;
    IOnchainBookManager mgr = m.engine;
    if (mgr.liquidation().isAuctionLive(accountId)) {
      _deactivate(marketId, accountId, DeactivationReason.AuctionLive);
    } else if (mgr.getMargin(accountId, true) < 0) {
      _deactivate(marketId, accountId, DeactivationReason.BelowInitialMargin);
    } else if (
      !_allowanceCovers(accountId, m.future, m.subId, true, m.lotSize)
        || !_allowanceCovers(accountId, m.future, m.subId, false, m.lotSize)
    ) {
      _deactivate(marketId, accountId, DeactivationReason.AllowanceTooLow);
    }
  }

  ///////////
  // Taker //
  ///////////

  /**
   * @notice Take against the market's splines, best price first and registration order at equal prices. The walk
   *         stops at the limit, the index band, `maxLevels` or a full fill. `optionalReport` is abi.encode(bytes[])
   *         of Data Streams reports, posted to the index before anything else.
   */
  function take(TakeOrder calldata o, bytes calldata optionalReport)
    external
    nonReentrant
    returns (uint filled, uint avgPrice)
  {
    Market memory m = _market(o.marketId);
    if (!m.enabled) revert OB_MarketDisabled();
    if (block.timestamp > o.deadline) revert OB_Expired();
    if (block.timestamp >= m.lastTradeTime) revert OB_TradingClosed();
    address takerOwner = _authorize(o.takerAccountId);

    // Post before transferring: the future checks each fill against the index in its asset hook (B6).
    if (optionalReport.length > 0) m.adapter.acceptData(optionalReport);

    uint tax = _priorityTax();
    if (!_allowanceCovers(o.takerAccountId, m.future, m.subId, o.isBuy, o.amount)) revert OB_TakerAllowanceTooLow();
    if (o.maxFee > 0 && !_allowanceCovers(o.takerAccountId, cash, 0, false, o.maxFee)) {
      revert OB_TakerAllowanceTooLow();
    }

    // Plan, settle, and re-plan without any maker whose batch reverted, so one failing maker cannot hold the take's
    // size away from the others (B5a). Each round excludes at least one maker, so there are at most makers + 1.
    Pass memory p = Pass({
      remainingLots: o.amount / m.lotSize,
      levelsLeft: o.maxLevels,
      excluded: new bool[](_makers[o.marketId].length),
      filledLots: 0,
      notionalTicks: 0,
      fee: 0
    });
    for (uint round; round <= p.excluded.length && p.remainingLots > 0 && p.levelsLeft > 0; ++round) {
      if (!_settleAll(o, m, _walk(m, o, takerOwner, p), p)) break;
    }

    // The tax prices priority in the block; a take that fills nothing pays none.
    if (tax > 0 && p.filledLots > 0) {
      _chargeCash(o.takerAccountId, tax, o.managerData);
      p.fee += tax;
    }
    if (p.fee > o.maxFee) revert OB_FeeTooHigh();
    filled = p.filledLots * m.lotSize;
    if (filled < o.minFill) revert OB_BelowMinFill();
    if (p.filledLots > 0) avgPrice = p.notionalTicks * m.tickSize / p.filledLots;
    emit TakeExecuted(o.marketId, o.takerAccountId, o.isBuy, filled, avgPrice, p.fee);
  }

  /// @dev Settle each planned maker in turn. A maker whose allowance no longer covers its fill is switched off (an
  ///      attributable failure); one whose batch reverts is only skipped. Either way its lots go back to the take and
  ///      it is excluded from the next round. Returns whether any maker failed.
  function _settleAll(TakeOrder calldata o, Market memory m, MakerState[] memory makers, Pass memory p)
    internal
    returns (bool anyFailed)
  {
    for (uint i; i < makers.length; ++i) {
      MakerState memory mk = makers[i];
      if (mk.filledLots == 0) continue;
      bool ok;
      if (!_allowanceCovers(mk.accountId, m.future, m.subId, !o.isBuy, mk.filledLots * m.lotSize)) {
        _deactivate(o.marketId, mk.accountId, DeactivationReason.AllowanceTooLow);
      } else {
        uint fee = _fee(m, mk.filledLots * m.lotSize, mk.notionalTicks * m.tickSize / mk.filledLots);
        if (gasleft() < gasFloor) revert OB_GasFloor();
        ok = _settle(o, m, mk, fee);
        if (ok) {
          p.filledLots += mk.filledLots;
          p.notionalTicks += mk.notionalTicks;
          p.fee += fee;
        }
      }
      if (!ok) {
        p.remainingLots += mk.filledLots;
        p.excluded[i] = true;
        anyFailed = true;
      }
    }
  }

  //////////
  // Walk //
  //////////

  /// @dev Plans the take in memory: no state is written, so a maker skipped later changes nothing stored.
  function _walk(Market memory m, TakeOrder calldata o, address takerOwner, Pass memory p)
    internal
    view
    returns (MakerState[] memory makers)
  {
    uint[] storage list = _makers[o.marketId];
    makers = new MakerState[](list.length);

    (bool fresh, int indexTicks) = _peg(m);
    if (!fresh) return makers;
    (uint index,) = m.future.indexFeed().getSpot();
    uint band = m.future.markIndexBand(m.expiry);

    for (uint i; i < list.length; ++i) {
      if (p.excluded[i]) {
        makers[i].done = true;
        continue;
      }
      makers[i] = _loadMaker(m, o.marketId, list[i], !o.isBuy, indexTicks);
    }

    // A level counts against maxLevels when it fills or is cancelled by DecrementTake. A level dropped for being short
    // of the band's near edge does not: it costs the taker nothing, and counting it would let a maker's unfillable
    // levels use up a small maxLevels. Drops are bounded by MAX_REGIONS per maker.
    while (p.levelsLeft > 0 && p.remainingLots > 0) {
      (uint best, int priceTicks) = _best(makers, o.isBuy);
      if (best == type(uint).max) break;
      uint price = uint(priceTicks) * m.tickSize;
      if (o.isBuy ? price > o.limitPrice : price < o.limitPrice) break;
      if (!_insideBand(price, index, band)) {
        // Past the far edge (an ask above the band, a bid below it) every later level is further out: stop. Short of
        // the near edge (an ask below the band, a bid above it) this level cannot fill, but a worse one, this maker's
        // or another's, may: drop it for this take and go on, so one maker's quote cannot close the side.
        if (o.isBuy ? price > index : price < index) break;
        _advance(makers[best], makers[best].regionLotsLeft);
        continue;
      }

      MakerState memory mk = makers[best];
      uint lots = mk.regionLotsLeft < p.remainingLots ? mk.regionLotsLeft : p.remainingLots;
      p.remainingLots -= lots;
      if (mk.owner == takerOwner) {
        if (o.selfTradeMode == SelfTradeMode.Abort) revert OB_SelfTrade();
        // DecrementTake: the crossing level is cancelled from the take, and the maker is out for the whole take.
        mk.done = true;
        p.excluded[best] = true;
        --p.levelsLeft;
        continue;
      }
      mk.filledLots += lots;
      mk.notionalTicks += lots * uint(priceTicks);
      _advance(mk, lots);
      --p.levelsLeft;
    }
  }

  function _loadMaker(Market memory m, uint marketId, uint accountId, bool isBid, int indexTicks)
    internal
    view
    returns (MakerState memory mk)
  {
    mk.accountId = accountId;
    mk.done = true;
    Spline memory s = splines[marketId][accountId];
    if (!s.active || block.timestamp > uint(s.updatedAt) + s.ttl) return mk;

    mk.owner = subAccounts.ownerOf(accountId);
    if (mk.owner != s.owner) return mk;
    if (m.engine.liquidation().isAuctionLive(accountId)) return mk;

    // Skew from the position at the start of the take, clamped, not recomputed between levels (B7).
    int posLots = subAccounts.getBalance(accountId, m.future, m.subId) / int(m.lotSize);
    int skew = posLots * int(uint(s.skewTicksPerLot));
    int maxSkew = int(uint(s.maxSkewTicks));
    if (skew > maxSkew) skew = maxSkew;
    if (skew < -maxSkew) skew = -maxSkew;
    mk.midTicks = indexTicks + s.offsetTicks - skew;
    mk.halfSpreadTicks = s.halfSpreadTicks;
    mk.curveId = isBid ? s.bidCurve : s.askCurve;

    Region[] storage curve = _curves[mk.owner][mk.curveId];
    uint consumed = _consumedNow(cursors[marketId][accountId][isBid], s.refillLotsPerSecond);
    for (uint r; r < curve.length; ++r) {
      uint lots = curve[r].lots;
      if (consumed >= lots) {
        consumed -= lots;
        continue;
      }
      if (mk.region == 0 && mk.regionLotsLeft == 0) {
        mk.region = uint8(r);
        mk.regionLotsLeft = lots - consumed;
        mk.done = false;
      }
      mk.curveLotsLeft += lots - consumed;
      consumed = 0;
    }
  }

  /// @dev The maker with the best current level; ties go to registration order. Levels at a non-positive price are
  ///      not quoted.
  function _best(MakerState[] memory makers, bool isBuy) internal view returns (uint best, int bestTicks) {
    best = type(uint).max;
    for (uint i; i < makers.length; ++i) {
      if (makers[i].done) continue;
      int p = _levelTicks(makers[i], isBuy);
      if (p <= 0) continue;
      if (best == type(uint).max || (isBuy ? p < bestTicks : p > bestTicks)) {
        best = i;
        bestTicks = p;
      }
    }
  }

  function _levelTicks(MakerState memory mk, bool isBuy) internal view returns (int) {
    uint32 off = _curves[mk.owner][mk.curveId][mk.region].offsetTicks;
    int away = int(uint(mk.halfSpreadTicks)) + int(uint(off));
    return isBuy ? mk.midTicks + away : mk.midTicks - away;
  }

  function _advance(MakerState memory mk, uint lots) internal view {
    mk.regionLotsLeft -= lots;
    mk.curveLotsLeft -= lots;
    if (mk.regionLotsLeft > 0) return;
    if (mk.curveLotsLeft == 0) {
      mk.done = true;
      return;
    }
    mk.region += 1;
    mk.regionLotsLeft = _curves[mk.owner][mk.curveId][mk.region].lots;
  }

  ////////////////
  // Settlement //
  ////////////////

  /// @dev One maker's fills and the taker fee on them, in one batch. A revert only skips this maker for this take and
  ///      changes nothing stored: a margin revert carries no account id, and the taker's margin is checked in the
  ///      same batch, so deactivating here would let an underfunded taker switch off every maker (B5a).
  function _settle(TakeOrder calldata o, Market memory m, MakerState memory mk, uint fee) internal returns (bool) {
    uint amount = mk.filledLots * m.lotSize;
    uint price = mk.notionalTicks * m.tickSize / mk.filledLots;
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](fee > 0 ? 2 : 1);
    batch[0] = ISubAccounts.AssetTransfer({
      fromAcc: o.isBuy ? mk.accountId : o.takerAccountId,
      toAcc: o.isBuy ? o.takerAccountId : mk.accountId,
      asset: m.future,
      subId: m.subId,
      amount: amount.toInt256(),
      assetData: bytes32(price)
    });
    if (fee > 0) {
      batch[1] = ISubAccounts.AssetTransfer({
        fromAcc: o.takerAccountId,
        toAcc: feeRecipient,
        asset: cash,
        subId: 0,
        amount: fee.toInt256(),
        assetData: bytes32(0)
      });
    }
    uint gasBefore = gasleft();
    try subAccounts.submitTransfers(batch, o.managerData) {
      Cursor storage c = cursors[o.marketId][mk.accountId][!o.isBuy];
      uint consumed = _consumedNow(c, splines[o.marketId][mk.accountId].refillLotsPerSecond);
      c.consumedLots = (consumed + mk.filledLots).toUint64();
      c.at = uint40(block.timestamp);
      emit Fill(o.marketId, o.takerAccountId, mk.accountId, o.isBuy, amount, price, fee);
      return true;
    } catch (bytes memory reason) {
      // Out of gas, not a real revert. In this frame it leaves about 1/64 of the gas; below it (the manager hook, the
      // viewer, a managerData receiver) it surfaces as a revert with no data, after the batch took nearly all it was
      // given. The taker chose the gas and can make the batch heavy through its own account or managerData, so
      // skipping here would let it pick which makers fill (B5a): the take reverts. An empty revert that did not use
      // the gas up (a feed with no code, a return too short to decode, in one maker's margin check) is that maker's
      // failure: skipped, as any other, so it cannot freeze the side.
      uint used = gasBefore - gasleft();
      if (gasleft() <= gasBefore / 63 || (reason.length == 0 && used >= gasBefore * 9 / 10)) {
        revert OB_BatchOutOfGas();
      }
      emit MakerSkipped(o.marketId, mk.accountId, reason);
      return false;
    }
  }

  function _chargeCash(uint accountId, uint amount, bytes calldata managerData) internal {
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: accountId, toAcc: feeRecipient, asset: cash, subId: 0, amount: amount.toInt256(), assetData: bytes32(0)
      }),
      managerData
    );
  }

  /////////////
  // Helpers //
  /////////////

  function _updateSpline(SplineUpdate calldata u) internal {
    Market storage m = _market(u.marketId);
    address owner_ = _authorize(u.accountId);
    if (!isRegistered[u.marketId][u.accountId]) revert OB_NotRegistered();
    if (!makerAllowed[owner_]) revert OB_MakerNotAllowed();
    if (u.ttl == 0 || u.ttl > m.maxTtl) revert OB_InvalidTtl();
    Region[] storage bid = _curves[owner_][u.bidCurve];
    Region[] storage ask = _curves[owner_][u.askCurve];
    if (bid.length == 0 || ask.length == 0) revert OB_InvalidCurve();
    // Best bid below best ask: 2 x half spread plus both first offsets must be positive.
    if (2 * uint(u.halfSpreadTicks) + bid[0].offsetTicks + ask[0].offsetTicks == 0) revert OB_CrossedSpline();

    Spline storage s = splines[u.marketId][u.accountId];
    if (u.seq <= s.seq) revert OB_StaleSeq();
    s.offsetTicks = u.offsetTicks;
    s.halfSpreadTicks = u.halfSpreadTicks;
    s.bidCurve = u.bidCurve;
    s.askCurve = u.askCurve;
    s.skewTicksPerLot = u.skewTicksPerLot;
    s.maxSkewTicks = u.maxSkewTicks;
    s.refillLotsPerSecond = u.refillLotsPerSecond;
    s.updatedAt = uint40(block.timestamp);
    s.ttl = u.ttl;
    s.seq = u.seq;
    s.active = true;
    s.owner = owner_;
    delete cursors[u.marketId][u.accountId][true];
    delete cursors[u.marketId][u.accountId][false];
    emit SplineUpdated(u.marketId, u.accountId, u.seq);
  }

  function _deactivate(uint marketId, uint accountId, DeactivationReason reason) internal {
    splines[marketId][accountId].active = false;
    emit MakerDeactivated(marketId, accountId, reason);
  }

  /// @dev The index in ticks, and whether both streams' stored reports are within `takeMaxAge` (B6a).
  function _peg(Market memory m) internal view returns (bool fresh, int indexTicks) {
    // The future's index can be rotated (FutureAsset.proposeIndexFeed, timelocked). Once it reads another adapter,
    // these reports are not what the band check prices against: quote nothing (a market on the new adapter replaces it).
    if (IIndexFeedAdapter(address(m.future.indexFeed())).adapter() != address(m.adapter)) return (false, 0);
    (uint base, uint64 baseAt) = m.adapter.latest(m.adapter.baseFeedId());
    (uint quote, uint64 quoteAt) = m.adapter.latest(m.adapter.quoteFeedId());
    if (baseAt == 0 || quoteAt == 0 || quote == 0) return (false, 0);
    uint oldest = baseAt < quoteAt ? baseAt : quoteAt;
    if (block.timestamp > oldest && block.timestamp - oldest > m.takeMaxAge) return (false, 0);
    return (true, int(base * 1e18 / quote / m.tickSize));
  }

  /// @dev The future's own fill check (FutureAsset._checkInsideIndexBand), so the walk stops where the chain would
  ///      refuse.
  function _insideBand(uint price, uint index, uint band) internal pure returns (bool) {
    if (band == 0) return true;
    uint diff = price > index ? price - index : index - price;
    return diff * 1e18 <= index * band;
  }

  function _consumedNow(Cursor memory c, uint refillPerSecond) internal view returns (uint) {
    uint refilled = (block.timestamp - c.at) * refillPerSecond;
    return c.consumedLots > refilled ? c.consumedLots - refilled : 0;
  }

  /// @dev Taker fee on a fill's notional, rounded up: amount x contract size x price x rate.
  function _fee(Market memory m, uint amount, uint price) internal view returns (uint) {
    if (m.takerFeeRate == 0) return 0;
    uint notional = amount * m.future.contractSize() / 1e18 * price / 1e18;
    return (notional * m.takerFeeRate + 1e18 - 1) / 1e18;
  }

  function _priorityTax() internal view returns (uint) {
    if (priorityTaxRate == 0 || tx.gasprice <= block.basefee) return 0;
    return (tx.gasprice - block.basefee) * priorityTaxRate;
  }

  /// @dev Whether this contract may move `amount` of `asset` in the given direction on `accountId`: as owner or
  ///      operator, or from subId plus asset allowances, as SubAccounts spends them.
  function _allowanceCovers(uint accountId, IAsset asset, uint subId, bool positive, uint amount)
    internal
    view
    returns (bool)
  {
    address owner_ = subAccounts.ownerOf(accountId);
    if (subAccounts.isApprovedForAll(owner_, address(this)) || subAccounts.getApproved(accountId) == address(this)) {
      return true;
    }
    IAllowances a = IAllowances(address(subAccounts));
    uint subIdAllowance = positive
      ? a.positiveSubIdAllowance(accountId, owner_, asset, subId, address(this))
      : a.negativeSubIdAllowance(accountId, owner_, asset, subId, address(this));
    uint assetAllowance = positive
      ? a.positiveAssetAllowance(accountId, owner_, asset, address(this))
      : a.negativeAssetAllowance(accountId, owner_, asset, address(this));
    if (subIdAllowance >= amount) return true;
    // SubAccounts adds the two with checked arithmetic (Allowances._spendAbsAllowance): a sum that overflows reverts
    // there, so it covers nothing here.
    return assetAllowance <= type(uint).max - subIdAllowance && subIdAllowance + assetAllowance >= amount;
  }

  /// @dev The caller must own the account or be approved for it; returns the owner.
  function _authorize(uint accountId) internal view returns (address owner_) {
    owner_ = subAccounts.ownerOf(accountId);
    if (
      msg.sender != owner_ && !subAccounts.isApprovedForAll(owner_, msg.sender)
        && subAccounts.getApproved(accountId) != msg.sender
    ) revert OB_NotAuthorized();
  }

  function _market(uint marketId) internal view returns (Market storage m) {
    m = markets[marketId];
    if (address(m.future) == address(0)) revert OB_InvalidMarket();
  }

  ///////////
  // Views //
  ///////////

  function makers(uint marketId) external view returns (uint[] memory) {
    return _makers[marketId];
  }

  function curve(address owner_, uint16 curveId) external view returns (Region[] memory) {
    return _curves[owner_][curveId];
  }
}
