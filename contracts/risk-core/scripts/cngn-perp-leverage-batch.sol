// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";

interface IOwnedLeverage {
  function owner() external view returns (address);
}

/**
 * Stage (B) of the USDCcNGN-PERP leverage path, as one vault batch: 3x to 5x on USDC margin
 * (IM 33.3% / MM 20% to IM 20% / MM 12%) and the cNGN margin factor from 0.5 to 0.35, sized
 * together by CngnPerpFiveXFork. The two move as one because each was sized against the other: at
 * MM 20% a 0.35 factor would cut a 1:1 hedge's rally room from 43% to about 18%, and at MM 12% the
 * 0.5 factor leaves a long-naira account on cNGN insolvent after a 25% step.
 *
 * Ordering inside the batch: the requirements first (only eases every account), then the factor
 * (tightens cNGN-margined accounts; a 1:1 hedge is still well within initial margin at 0.35).
 *
 * The SecurityModule top-up comes before the batch and is the operator's funding, not a vault call:
 * `checkFunded` is the gate the proposer runs so the batch cannot be proposed against an SM below
 * the agreed floor. Hedge mode (markets-service, the app) stays at 1:1 and is not on chain.
 */
library CNGNPerpLeverageBatch {
  uint internal constant ACTION_COUNT = 2;

  struct Ctx {
    /// @dev Who executes the batch: the MPCVault on mainnet, the test contract on a fork.
    address vault;
    address srm;
    address subAccounts;
    /// @dev The perp's CashAsset: what the SecurityModule's account holds.
    address cash;
    uint securityModuleAccount;
    uint marketId;
    /// @dev 18dp perp margin requirements after the batch.
    uint mmReq;
    uint imReq;
    /// @dev 18dp cNGN margin factor and IM scale after the batch.
    uint marginFactor;
    uint imScale;
    /// @dev 18dp cash the SecurityModule must hold before the batch may be proposed.
    uint securityModuleFloor;
  }

  /// @dev Structural checks: the batch is a tightening of the factor and an easing of the
  ///      requirements on an SRM the vault owns. Anything else is a world that has moved.
  function checkPreconditions(Ctx memory ctx) internal view {
    require(IOwnedLeverage(ctx.srm).owner() == ctx.vault, "PRE: srm owner is not the recorded vault");
    (uint mmNow, uint imNow) = StandardManager(ctx.srm).perpMarginRequirements(ctx.marketId);
    require(ctx.mmReq > 0 && ctx.mmReq < ctx.imReq && ctx.imReq < 1e18, "PRE: requirements out of order");
    require(ctx.imReq < imNow && ctx.mmReq < mmNow, "PRE: the batch does not lower both requirements");
    (uint factorNow, uint imScaleNow) = StandardManager(ctx.srm).baseMarginParams(ctx.marketId);
    require(factorNow > 0, "PRE: cNGN is not yet a margin asset on this market (batch 4 first)");
    require(ctx.marginFactor > 0 && ctx.marginFactor < factorNow, "PRE: the batch does not lower the factor");
    require(ctx.imScale == imScaleNow, "PRE: the batch does not change the IM scale");
    // Solvent through a 25% step at maintenance margin: F <= MM(1-s)/s, from the fork study.
    require(ctx.marginFactor * 2_500 <= ctx.mmReq * 7_500, "PRE: factor is not sized for a 25% step at this MM");
  }

  /// @dev The funding gate: the SecurityModule holds at least the floor. The proposer runs this
  ///      before proposing; the fork test funds the module first.
  function checkFunded(Ctx memory ctx) internal view {
    int held = ISubAccounts(ctx.subAccounts).getBalance(ctx.securityModuleAccount, IAsset(ctx.cash), 0);
    require(held >= int(ctx.securityModuleFloor), "PRE: SecurityModule below the agreed floor; fund it first");
  }

  function build(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ACTION_COUNT);
    data = new bytes[](ACTION_COUNT);
    descriptions = new string[](ACTION_COUNT);

    descriptions[0] = "srm.setPerpMarginRequirements(marketId, mm, im) [5x: eases every account; first]";
    to[0] = ctx.srm;
    data[0] = abi.encodeCall(StandardManager.setPerpMarginRequirements, (ctx.marketId, ctx.mmReq, ctx.imReq));

    descriptions[1] =
    "srm.setBaseAssetMarginFactor(marketId, factor, imScale) [cNGN haircut sized for the new MM; second]";
    to[1] = ctx.srm;
    data[1] = abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, ctx.marginFactor, ctx.imScale));
  }

  /// @dev Commits to targets, calldata and ordering, not to the prose.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    return keccak256(acc);
  }

  /// @dev What MPCVault shows for one action: keccak256(abi.encodePacked(to, keccak256(data))).
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }

  /// @dev Executes the batch as the caller: the fork test's path (the test owns the SRM).
  function execute(Ctx memory ctx) internal {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      (bool ok, bytes memory ret) = to[i].call(data[i]);
      require(ok, string.concat("leverage action failed: ", _revertReason(ret)));
    }
  }

  function _revertReason(bytes memory ret) private pure returns (string memory) {
    if (ret.length < 68) return "(no reason)";
    assembly {
      ret := add(ret, 0x04)
    }
    return abi.decode(ret, (string));
  }
}
