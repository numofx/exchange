// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {ManagerWhitelist} from "../src/assets/utils/ManagerWhitelist.sol";
import {PositionTracking} from "../src/assets/utils/PositionTracking.sol";

interface IOwnable2StepAccept {
  function acceptOwnership() external;
}

interface IOwned {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

interface IERC20Supply {
  function totalSupply() external view returns (uint);
}

/**
 * @title CNGNSpotBatch
 * @notice THE single definition of the USDCcNGN-SPOT vault batch.
 *
 * @dev Both sides of the guarantee call this and nothing else:
 *        - scripts/register-cngn-spot-srm.s.sol serialises build() into the artifact the vault signs
 *        - test/fork/CNGNSpotSRMBaseFork.t.sol executes build() against live Base state
 *      so the batch under test and the batch signed cannot diverge. Do not inline an action list
 *      anywhere else.
 *
 * @dev hash() pins the shape. test/scripts/CNGNSpotBatchShape.t.sol asserts it against a committed
 *      constant for a fixed context, so any edit to the ordering, targets or calldata trips a test
 *      and has to be acknowledged deliberately. The script also writes the hash of the real context
 *      into the artifact, so a signer can regenerate it and confirm the JSON in front of them is
 *      what this code produces.
 */
library CNGNSpotBatch {
  uint internal constant ACTION_COUNT = 11;

  struct Ctx {
    address srm;
    address wrappedCngn;
    address cngnFeed;
    address stableFeed;
    uint marketId;
    uint baseCap;
  }

  /// @dev Refuse to emit calldata for a world that has moved. Lives here rather than in the script
  ///      so it can be tested directly against a fork. Every check is either something that would
  ///      revert mid-batch -- and the batch is 11 separate EOA transactions, so a mid-batch revert
  ///      is real partial state, not an atomic rollback -- or something that would silently succeed
  ///      while doing the wrong thing.
  function checkPreconditions(Ctx memory ctx, address cngnToken, address liveCngnFeed, uint tolerancePct)
    internal
    view
  {
    address vault = IOwned(ctx.srm).owner();
    require(vault != address(0), "PRE: srm owner is zero");
    require(IOwned(ctx.wrappedCngn).owner() == vault, "PRE: srm and wrappedCngn have different owners");

    // createMarket assigns ++lastMarketId. If a market was created since this id was resolved, every
    // later action in the batch targets the wrong market.
    require(ctx.marketId == StandardManager(ctx.srm).lastMarketId() + 1, "PRE: marketId is stale - re-run");
    require(
      address(StandardManager(ctx.srm).assetMap(ctx.marketId, IStandardManager.AssetType.Base)) == address(0),
      "PRE: market already has a base asset"
    );

    require(ctx.cngnFeed.code.length > 0, "PRE: cngn static feed has no code");
    require(ctx.stableFeed.code.length > 0, "PRE: stable static feed has no code");

    // actions 8 and 9 are acceptOwnership(); they revert unless the vault is already pending owner
    require(IOwned(ctx.cngnFeed).pendingOwner() == vault, "PRE: vault is not pending owner of cngn feed");
    require(IOwned(ctx.stableFeed).pendingOwner() == vault, "PRE: vault is not pending owner of stable feed");

    (uint stablePrice,) = ISpotFeed(ctx.stableFeed).getSpot();
    require(stablePrice == 1e18, "PRE: stable static feed is not 1e18");

    // ORIENTATION. The SRM's Base convention is USD-per-base, so this must be USDC-per-cNGN, far
    // below 1e18. The live DFXM feed is cNGN-per-USDC (~1345e18); wiring it in inflates
    // mark-to-market by spot^2. This is the check that catches that substitution.
    (uint usdcPerCngn,) = ISpotFeed(ctx.cngnFeed).getSpot();
    require(usdcPerCngn > 0, "PRE: cngn static feed is 0");
    require(usdcPerCngn < 1e18, "PRE: cngn static feed looks inverted - expected USDC-per-cNGN");

    // DRIFT. The static price is frozen at deploy time; if cNGN has moved materially since, the
    // venue would launch marking against a rate nobody chose.
    (uint cngnPerUsdc,) = ISpotFeed(liveCngnFeed).getSpot();
    require(cngnPerUsdc > 0, "PRE: live cNGN feed returned 0");
    uint expected = 1e36 / cngnPerUsdc;
    uint diff = usdcPerCngn > expected ? usdcPerCngn - expected : expected - usdcPerCngn;
    require(diff * 100 <= expected * tolerancePct, "PRE: static feed has drifted from live - redeploy feeds");

    require(IERC20Supply(cngnToken).totalSupply() > 0, "PRE: cNGN totalSupply is 0");
    require(ctx.baseCap > 0, "PRE: cap is 0");
  }

  /// @dev Per-action status read from chain, so a signer can resume a partially-executed batch.
  ///
  ///      AMBIGUOUS is the honest answer for actions 5 and 6: their postcondition is all-zeros,
  ///      which is exactly what an untouched market reads. There is no way to distinguish "we set
  ///      it" from "nobody has touched it" by state alone. resolve() below settles those using the
  ///      one thing that is true of an EOA batch: transactions land in nonce order, so if a later
  ///      action is DONE every earlier one must be.
  enum Status {
    Pending,
    Done,
    Diverged,
    Ambiguous
  }

  function statuses(Ctx memory ctx) internal view returns (Status[] memory out) {
    out = new Status[](ACTION_COUNT);
    address vault = IOwned(ctx.srm).owner();

    out[0] = _ownedBy(ctx.cngnFeed, vault);
    out[1] = _ownedBy(ctx.stableFeed, vault);

    address wiredStable = address(StandardManager(ctx.srm).stableFeed());
    out[2] = wiredStable == ctx.stableFeed ? Status.Done : Status.Pending;

    out[3] = StandardManager(ctx.srm).borrowingEnabled() ? Status.Pending : Status.Done;

    out[4] = StandardManager(ctx.srm).lastMarketId() >= ctx.marketId ? Status.Done : Status.Pending;

    // market not created yet: everything downstream is simply pending
    if (out[4] == Status.Pending) {
      for (uint i = 5; i < ACTION_COUNT; ++i) {
        out[i] = Status.Pending;
      }
      out[9] = _capStatus(ctx);
      out[10] = _whitelistStatus(ctx);
      return out;
    }

    (uint marginFactor, uint imScale) = StandardManager(ctx.srm).baseMarginParams(ctx.marketId);
    out[5] = (marginFactor == 0 && imScale == 0) ? Status.Ambiguous : Status.Diverged;

    out[6] = _contingencyStatus(ctx);

    (ISpotFeed spotFeed,,) = StandardManager(ctx.srm).getMarketFeeds(ctx.marketId);
    address wiredSpot = address(spotFeed);
    out[7] = wiredSpot == ctx.cngnFeed
      ? Status.Done
      : (wiredSpot == address(0) ? Status.Pending : Status.Diverged);

    address baseAsset = address(StandardManager(ctx.srm).assetMap(ctx.marketId, IStandardManager.AssetType.Base));
    out[8] = baseAsset == ctx.wrappedCngn
      ? Status.Done
      : (baseAsset == address(0) ? Status.Pending : Status.Diverged);

    out[9] = _capStatus(ctx);
    out[10] = _whitelistStatus(ctx);
  }

  /// @dev EOA transactions land in nonce order, so a DONE action implies every earlier one landed.
  ///      That is what lets an all-zeros postcondition be resolved rather than reported as unknown.
  ///      DIVERGED is never overwritten: it means the chain disagrees with the batch and no amount
  ///      of ordering inference makes that fine.
  function resolve(Status[] memory raw) internal pure returns (Status[] memory out) {
    out = raw;
    uint highestDone;
    bool any;
    for (uint i = 0; i < out.length; ++i) {
      if (out[i] == Status.Done) {
        highestDone = i;
        any = true;
      }
    }
    if (!any) return out;

    for (uint i = 0; i < highestDone; ++i) {
      if (out[i] == Status.Ambiguous) out[i] = Status.Done;
    }
  }

  function _ownedBy(address target, address vault) private view returns (Status) {
    if (target.code.length == 0) return Status.Pending;
    address owner = IOwned(target).owner();
    if (owner == vault) return Status.Done;
    return IOwned(target).pendingOwner() == vault ? Status.Pending : Status.Diverged;
  }

  function _capStatus(Ctx memory ctx) private view returns (Status) {
    uint cap = PositionTracking(ctx.wrappedCngn).totalPositionCap(IManager(ctx.srm));
    if (cap == ctx.baseCap) return Status.Done;
    return cap == 0 ? Status.Pending : Status.Diverged;
  }

  function _whitelistStatus(Ctx memory ctx) private view returns (Status) {
    return ManagerWhitelist(ctx.wrappedCngn).whitelistedManager(ctx.srm) ? Status.Done : Status.Pending;
  }

  function _contingencyStatus(Ctx memory ctx) private view returns (Status) {
    (uint perpThreshold, uint optionThreshold, uint baseThreshold, uint ocFactor) =
      StandardManager(ctx.srm).oracleContingencyParams(ctx.marketId);
    bool zeroed = perpThreshold == 0 && optionThreshold == 0 && baseThreshold == 0 && ocFactor == 0;
    return zeroed ? Status.Ambiguous : Status.Diverged;
  }

  function build(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ACTION_COUNT);
    data = new bytes[](ACTION_COUNT);
    descriptions = new string[](ACTION_COUNT);

    // no oracle contingency: at marginFactor 0 the base margin is 0 and _getBaseMarginAndMtM returns
    // before the contingency penalty, so a non-zero threshold here would be inert config. This is
    // also why the static feeds' confidence value is never read on the spot path.
    IStandardManager.OracleContingencyParams memory ocParams =
      IStandardManager.OracleContingencyParams({perpThreshold: 0, optionThreshold: 0, baseThreshold: 0, OCFactor: 0});

    // ORDERING: secure custody -> tighten globals -> configure an inert market -> enable last.
    // The vault is an EOA, so this is 11 separate transactions and a mid-batch stop is real partial
    // state, not a rollback. Every prefix of this order is safe to abandon: nothing can be deposited
    // or traded until the final action, and the two states that used to carry risk -- feeds left on
    // the deployer key, and the old 3600s stableFeed still wired in -- are now cleared first.

    descriptions[0] = "staticCngnFeed.acceptOwnership() [secures custody; no functional change]";
    to[0] = ctx.cngnFeed;
    data[0] = abi.encodeCall(IOwnable2StepAccept.acceptOwnership, ());

    descriptions[1] = "staticStableFeed.acceptOwnership() [secures custody; no functional change]";
    to[1] = ctx.stableFeed;
    data[1] = abi.encodeCall(IOwnable2StepAccept.acceptOwnership, ());

    descriptions[2] = "srm.setStableFeed(staticStableFeed) [GLOBAL; removes the 3600s staleness halt]";
    to[2] = ctx.srm;
    data[2] = abi.encodeCall(StandardManager.setStableFeed, (ISpotFeed(ctx.stableFeed)));

    descriptions[3] = "srm.setBorrowingEnabled(false) [GLOBAL; strictly tightening]";
    to[3] = ctx.srm;
    data[3] = abi.encodeCall(StandardManager.setBorrowingEnabled, (false));

    descriptions[4] = "srm.createMarket(CNGN) [market exists but nothing is wired to it]";
    to[4] = ctx.srm;
    data[4] = abi.encodeCall(StandardManager.createMarket, ("CNGN"));

    descriptions[5] = "srm.setBaseAssetMarginFactor(0) [pinned before the asset can ever be traded]";
    to[5] = ctx.srm;
    data[5] = abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, 0, 0));

    descriptions[6] = "srm.setOracleContingencyParams(zeroed)";
    to[6] = ctx.srm;
    data[6] = abi.encodeCall(StandardManager.setOracleContingencyParams, (ctx.marketId, ocParams));

    descriptions[7] = "srm.setOraclesForMarket(staticCngnFeed) [USDC-per-cNGN: SRM Base convention]";
    to[7] = ctx.srm;
    data[7] = abi.encodeCall(
      StandardManager.setOraclesForMarket,
      (ctx.marketId, ISpotFeed(ctx.cngnFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
    );

    descriptions[8] = "srm.whitelistAsset(wrappedCngn, Base) [SRM side of the gate; asset side still shut]";
    to[8] = ctx.srm;
    data[8] = abi.encodeCall(
      StandardManager.whitelistAsset, (IAsset(ctx.wrappedCngn), ctx.marketId, IStandardManager.AssetType.Base)
    );

    descriptions[9] = "wrappedCngn.setTotalPositionCap(srm) [cap in place before deposits are possible]";
    to[9] = ctx.wrappedCngn;
    data[9] = abi.encodeCall(PositionTracking.setTotalPositionCap, (IManager(ctx.srm), ctx.baseCap));

    descriptions[10] =
      "wrappedCngn.setWhitelistManager(srm) [THE ENABLING SWITCH - nothing can enter before this]";
    to[10] = ctx.wrappedCngn;
    data[10] = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (ctx.srm, true));
  }

  /// @dev commits to targets, calldata and ordering. Descriptions are prose and deliberately
  ///      excluded: rewording a comment must not invalidate a signature.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);

    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    return keccak256(acc);
  }

  /// @dev The vault is an EOA (codesize 0), not a Safe: there is no MultiSend and no single proposed
  ///      payload. Each action is signed as its own transaction, so the unit a signer can actually
  ///      compare against what their MPC console displays is one (to, data) pair. This is that
  ///      digest. `value` is omitted because every action in this batch is value 0 and the verifier
  ///      asserts that separately.
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }
}
