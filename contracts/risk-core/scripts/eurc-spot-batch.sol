// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {MarginEngineV1 as MarginEngine} from "../src/legacy/v1/MarginEngineV1.sol";
import {ChainlinkSpotFeed} from "../src/feeds/ChainlinkSpotFeed.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {ManagerWhitelist} from "../src/assets/utils/ManagerWhitelist.sol";
import {PositionTracking} from "../src/assets/utils/PositionTracking.sol";

interface IEurcOwnable2StepAccept {
  function acceptOwnership() external;
}

interface IEurcOwned {
  function owner() external view returns (address);
  function pendingOwner() external view returns (address);
}

/**
 * @title EURCSpotBatch
 * @notice THE single definition of the two vault batches that list EURC on the MarginEngine: market 2, its base asset a
 *         dedicated EURC escrow (WrappedERC20Asset), priced by a ChainlinkSpotFeed over Chainlink EURC/USD, credited as
 *         margin at the haircut below, under a deposit cap. `build()` configures; `buildEnable()` is the single action
 *         that opens EURC deposits, signed on its own once markets-service, the keeper and the maker that know EURC are
 *         live. The deploy script (which serialises them for MPCVault), the fork test (which executes them against live
 *         Base state) and scripts/ops/propose_eurc_spot_batch.py (which re-derives each action) agree on this list.
 *
 * @dev Its own market, not market 1's Base slot: that slot is the cNGN escrow, which spot, the perp and the future all
 *      margin through. whitelistAsset on an occupied slot DE-WHITELISTS what was there, so the batch is only valid while
 *      the engine has exactly one market: createMarket must return 2, and checkPreconditions refuses any other world.
 *
 * @dev The feed is Chainlink EURC/USD (the token, not the EUR/USD rate, so a EURC depeg is priced), adapted to 18dp USD
 *      per EURC with confidence fixed at 1e18. It updates on a 24h heartbeat or a deviation, so the adapter's staleness
 *      limit is 25h; past it getSpot reverts and every account HOLDING EURC fails closed (no trade, no withdrawal, no
 *      liquidation) until Chainlink posts. Accounts without EURC never read it: _getMarketMargin runs per market held.
 *      Oracle contingency is left zero: with a fixed confidence there is nothing for it to act on.
 *
 * @dev The haircut. Borrowing is ON under the engine, so EURC credit is a loan book as well as margin: an account can
 *      withdraw USDC against EURC down to initial margin. Maintenance credits 90% of oracle value (a 10% EURC/USD move
 *      before an account at maintenance is insolvent; the largest one-day EUR/USD move since 1999 is under 3%), initial
 *      credits 72% (0.9 x 0.8): at the 40,000 EURC cap that bounds the on-chain loan book to about $32k, which is why the cap is
 *      the number to move carefully. test/fork/EurcSpotFork.t.sol pins both.
 *
 * @dev Ordering of build() (seven separate transactions from the vault; every prefix is a safe place to stop, since the
 *      escrow stays shut until buildEnable): custody of the escrow and the feed, the market, its feed, its haircut, the
 *      engine's view of the asset, the cap.
 */
library EURCSpotBatch {
  uint internal constant ACTION_COUNT = 7;
  uint internal constant ENABLE_ACTION_COUNT = 1;
  string internal constant MARKET_NAME = "EUR";

  struct Ctx {
    /// @dev Who executes the batch: the MPCVault on mainnet, the test contract on a fork.
    address vault;
    address engine;
    address escrow;
    address spotFeed;
    /// @dev The market createMarket will return: the engine's lastMarketId + 1.
    uint marketId;
    /// @dev 18dp: the share of the oracle value that counts as maintenance margin.
    uint marginFactor;
    /// @dev 18dp: multiplied in again for initial margin.
    uint imScale;
    /// @dev EURC, 18dp, summed over every account under the engine: the deposit cap.
    uint cap;
  }

  /// @dev Refuse to emit calldata for a world that has moved. Every check is something that would revert mid-batch,
  ///      configure the wrong market, or margin against the wrong feed.
  function checkPreconditions(Ctx memory ctx) internal view {
    MarginEngine engine = MarginEngine(ctx.engine);
    require(engine.owner() == ctx.vault, "PRE: engine owner is not the recorded vault");
    require(engine.lastMarketId() + 1 == ctx.marketId, "PRE: createMarket would not return the recorded market id");
    require(
      address(engine.assetMap(ctx.marketId, IMarginEngine.AssetType.Base)) == address(0),
      "PRE: the market's Base slot is occupied; whitelisting would de-whitelist it"
    );
    require(
      !engine.assetDetails(IAsset(ctx.escrow)).isWhitelisted, "PRE: the escrow is already whitelisted on the engine"
    );
    require(
      IEurcOwned(ctx.escrow).pendingOwner() == ctx.vault || IEurcOwned(ctx.escrow).owner() == ctx.vault,
      "PRE: escrow is not nominated to the vault"
    );
    require(
      IEurcOwned(ctx.spotFeed).pendingOwner() == ctx.vault || IEurcOwned(ctx.spotFeed).owner() == ctx.vault,
      "PRE: spot feed is not nominated to the vault"
    );
    require(!ManagerWhitelist(ctx.escrow).whitelistedManager(ctx.engine), "PRE: escrow already open to the engine");
    (uint spot, uint confidence) = ISpotFeed(ctx.spotFeed).getSpot();
    require(spot >= 0.8e18 && spot <= 1.6e18, "PRE: the feed does not read a EURC price in USD");
    require(confidence == 1e18, "PRE: the feed's confidence is not fixed");
    require(ctx.marginFactor > 0 && ctx.marginFactor < 1e18, "PRE: margin factor out of range");
    require(ctx.imScale > 0 && ctx.imScale <= 1e18, "PRE: IM scale out of range");
    require(ctx.cap > 0, "PRE: a zero cap would whitelist an asset nobody can deposit");
  }

  function build(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ACTION_COUNT);
    data = new bytes[](ACTION_COUNT);
    descriptions = new string[](ACTION_COUNT);

    descriptions[0] = "eurcEscrow.acceptOwnership() [custody; the escrow was nominated at deploy]";
    to[0] = ctx.escrow;
    data[0] = abi.encodeCall(IEurcOwnable2StepAccept.acceptOwnership, ());

    descriptions[1] = "eurcSpotFeed.acceptOwnership() [custody of the feed's staleness limit]";
    to[1] = ctx.spotFeed;
    data[1] = abi.encodeCall(IEurcOwnable2StepAccept.acceptOwnership, ());

    descriptions[2] = "engine.createMarket(EUR) [market 2; nothing can hold it yet]";
    to[2] = ctx.engine;
    data[2] = abi.encodeCall(MarginEngine.createMarket, (MARKET_NAME));

    descriptions[3] = "engine.setOraclesForMarket(2, eurcSpotFeed, 0, 0) [Chainlink EURC/USD, before the asset counts]";
    to[3] = ctx.engine;
    data[3] = abi.encodeCall(
      MarginEngine.setOraclesForMarket,
      (ctx.marketId, ISpotFeed(ctx.spotFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
    );

    descriptions[4] = "engine.setBaseAssetMarginFactor(2, factor, imScale) [the haircut, before the asset can count]";
    to[4] = ctx.engine;
    data[4] = abi.encodeCall(MarginEngine.setBaseAssetMarginFactor, (ctx.marketId, ctx.marginFactor, ctx.imScale));

    descriptions[5] = "engine.whitelistAsset(eurcEscrow, 2, Base) [engine side of the gate; escrow still shut]";
    to[5] = ctx.engine;
    data[5] =
      abi.encodeCall(MarginEngine.whitelistAsset, (IAsset(ctx.escrow), ctx.marketId, IMarginEngine.AssetType.Base));

    descriptions[6] = "eurcEscrow.setTotalPositionCap(engine, cap) [deposit cap in place before deposits are possible]";
    to[6] = ctx.escrow;
    data[6] = abi.encodeCall(PositionTracking.setTotalPositionCap, (IManager(ctx.engine), ctx.cap));
  }

  /// @dev The one action that opens EURC deposits, and with them the market. Its own batch.
  function buildEnable(Ctx memory ctx)
    internal
    pure
    returns (address[] memory to, bytes[] memory data, string[] memory descriptions)
  {
    to = new address[](ENABLE_ACTION_COUNT);
    data = new bytes[](ENABLE_ACTION_COUNT);
    descriptions = new string[](ENABLE_ACTION_COUNT);

    descriptions[0] = "eurcEscrow.setWhitelistManager(engine, true) [THE ENABLING SWITCH - EURC deposits open here]";
    to[0] = ctx.escrow;
    data[0] = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (ctx.engine, true));
  }

  /// @dev Commits to targets, calldata and ordering of BOTH batches, not to the prose.
  function hash(Ctx memory ctx) internal pure returns (bytes32) {
    (address[] memory to, bytes[] memory data,) = build(ctx);
    (address[] memory enableTo, bytes[] memory enableData,) = buildEnable(ctx);
    bytes memory acc;
    for (uint i = 0; i < ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(to[i], data[i]));
    }
    for (uint i = 0; i < ENABLE_ACTION_COUNT; ++i) {
      acc = abi.encodePacked(acc, actionHash(enableTo[i], enableData[i]));
    }
    return keccak256(acc);
  }

  /// @dev What MPCVault shows for one action: keccak256(abi.encodePacked(to, keccak256(data))).
  function actionHash(address to, bytes memory data) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(to, keccak256(data)));
  }
}
