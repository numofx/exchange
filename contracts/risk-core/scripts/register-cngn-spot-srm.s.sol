// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";

import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {Deployment} from "./types.sol";
import {Utils, IOwnable2Step} from "./utils.sol";

/**
 * @dev Registers the existing wrapped cNGN asset as a base-only market on the already-deployed SRM,
 *      so USDCcNGN-SPOT runs under a manager where cNGN gives zero margin credit instead of
 *      DeliverableFXManager, which credits it at 100% of oracle value.
 *
 * @dev Deploys nothing. The wrapped cNGN ASSET is reused as-is, so CNGN_SPOT_ASSET_ADDRESS in the
 *      markets service does not change. The spot FEED is not reused - see
 *      deploy-cngn-spot-static-feeds.s.sol, which must run first. Every call below is onlyOwner on
 *      a vault-owned contract, so this script only writes calldata to
 *      deployments/{chainId}/CNGN_SPOT_SRM_VAULT_ACTIONS.json for the admin vault to execute in order.
 *
 * @dev The whole batch must execute AS THE VAULT. Actions 9 and 10 are acceptOwnership() calls,
 *      which only the pending owner can make; a deployer EOA cannot stand in. Leaving a feed on a
 *      deployer key is the same failure already recorded under "ABANDONED deployment" in
 *      DEPLOYED_ADDRESSES.md.
 *
 * Usage: forge script scripts/register-cngn-spot-srm.s.sol --rpc-url $BASE_RPC_URL
 *        (read-only rpc: resolves the next marketId and live cNGN supply; both are chain state)
 */
contract RegisterCNGNSpotOnSRM is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_SPOT_SRM_VAULT_ACTIONS";
  string internal constant MARKET_NAME = "CNGN";
  uint internal constant ACTION_COUNT = 11;

  /// @dev The cap is the venue's total cNGN inventory limit, expressed as a share of all cNGN in
  ///      existence. It is derived from live totalSupply rather than a constant: cNGN supply moves,
  ///      and a stale denominator is how a cap ends up being most of the float. (An earlier
  ///      hardcoded 1.5e9 was 73% of total supply.)
  uint internal constant DEFAULT_CAP_PCT = 10;

  function run() external {
    Deployment memory deployment = _loadDeployment();

    string memory cngnDeployment = _readDeploymentFile("CNGN");
    address wrappedCngn = vm.parseJsonAddress(cngnDeployment, ".base");
    address cngnToken = vm.parseJsonAddress(cngnDeployment, ".wrappedAsset");
    if (wrappedCngn == address(0) || cngnToken == address(0)) revert("CNGN deployment incomplete");

    string memory feeds = _readDeploymentFile("CNGN_SPOT_STATIC_FEEDS");
    address staticCngnFeed = vm.parseJsonAddress(feeds, ".cngnStaticSpotFeed");
    address staticStableFeed = vm.parseJsonAddress(feeds, ".stableStaticSpotFeed");
    if (staticCngnFeed == address(0) || staticStableFeed == address(0)) {
      revert("run deploy-cngn-spot-static-feeds.s.sol first");
    }

    // createMarket assigns ++lastMarketId, so the id the later calls must use is only knowable
    // against live state. Reading it wrong silently points the market config at another market.
    uint marketId = vm.envOr("CNGN_MARKET_ID", uint(0));
    if (marketId == 0) {
      marketId = deployment.srm.lastMarketId() + 1;
      if (marketId == 1) {
        console2.log("WARNING: lastMarketId read as 0 - run against an rpc or set CNGN_MARKET_ID");
      }
    }

    uint baseCap = _resolveCap(cngnToken);

    string memory json = _buildActions(
      Ctx({
        srm: address(deployment.srm),
        wrappedCngn: wrappedCngn,
        cngnFeed: staticCngnFeed,
        stableFeed: staticStableFeed,
        marketId: marketId,
        baseCap: baseCap
      })
    );

    _writeToDeployments(ARTIFACT_NAME, json);

    console2.log("SRM:", address(deployment.srm));
    console2.log("wrapped cNGN (unchanged, still CNGN_SPOT_ASSET_ADDRESS):", wrappedCngn);
    console2.log("static cNGN spot feed:", staticCngnFeed);
    console2.log("static stable feed:", staticStableFeed);
    console2.log("market id the vault must create:", marketId);
    console2.log("");
    console2.log("Vault must execute all %s calls in %s.json IN ORDER, as the vault.", ACTION_COUNT, ARTIFACT_NAME);
  }

  /// @dev cap = pct% of live cNGN totalSupply, scaled from the token's decimals to the wrapped
  ///      asset's 18. Hitting the cap blocks DEPOSITS only, not trading: _checkAssetCap reverts on
  ///      `preTradePos < postTradePos && postTradePos > cap`, and an account-to-account transfer of
  ///      a non-negative asset leaves totalPosition unchanged. Alert at 80% so the cap is raised
  ///      before users are rejected, rather than after.
  function _resolveCap(address cngnToken) internal view returns (uint baseCap) {
    uint pct = vm.envOr("CNGN_SPOT_CAP_PCT", DEFAULT_CAP_PCT);
    if (pct == 0 || pct > 100) revert("CNGN_SPOT_CAP_PCT must be 1..100");

    uint supply = IERC20Metadata(cngnToken).totalSupply();
    if (supply == 0) revert("cNGN totalSupply read as 0 - run against an rpc");

    uint8 decimals = IERC20Metadata(cngnToken).decimals();
    if (decimals > 18) revert("unexpected cNGN decimals");
    uint supply18 = supply * (10 ** (18 - decimals));

    baseCap = vm.envOr("CNGN_SPOT_BASE_CAP", uint(0));
    if (baseCap == 0) baseCap = supply18 * pct / 100;

    console2.log("cNGN totalSupply (18dp, live):", supply18);
    console2.log("cap pct:", pct);
    console2.log("base position cap (cNGN, 18dp):", baseCap);
    console2.log("  = %s%% of live supply", baseCap * 100 / supply18);
    console2.log("  alert threshold at 80%% of cap:", baseCap * 80 / 100);
  }

  struct Ctx {
    address srm;
    address wrappedCngn;
    address cngnFeed;
    address stableFeed;
    uint marketId;
    uint baseCap;
  }

  function _buildActions(Ctx memory ctx) internal pure returns (string memory) {
    // no oracle contingency: at marginFactor 0 the base margin is 0, and _getBaseMarginAndMtM
    // returns before the contingency penalty, so a non-zero threshold here would be inert config.
    // This is also why the static feeds' confidence value is never read on this path.
    IStandardManager.OracleContingencyParams memory ocParams =
      IStandardManager.OracleContingencyParams({perpThreshold: 0, optionThreshold: 0, baseThreshold: 0, OCFactor: 0});

    string[] memory actions = new string[](ACTION_COUNT);

    actions[0] =
      _vaultAction("srm.createMarket(CNGN)", ctx.srm, abi.encodeCall(StandardManager.createMarket, (MARKET_NAME)));
    actions[1] = _vaultAction(
      "wrappedCngn.setWhitelistManager(srm) [additive: DFXM stays whitelisted]",
      ctx.wrappedCngn,
      abi.encodeCall(WrappedERC20Asset(ctx.wrappedCngn).setWhitelistManager, (ctx.srm, true))
    );
    actions[2] = _vaultAction(
      "wrappedCngn.setTotalPositionCap(srm) [blocks deposits at cap, not trading]",
      ctx.wrappedCngn,
      abi.encodeCall(WrappedERC20Asset(ctx.wrappedCngn).setTotalPositionCap, (IManager(ctx.srm), ctx.baseCap))
    );
    actions[3] = _vaultAction(
      "srm.whitelistAsset(wrappedCngn, Base)",
      ctx.srm,
      abi.encodeCall(
        StandardManager.whitelistAsset, (IAsset(ctx.wrappedCngn), ctx.marketId, IStandardManager.AssetType.Base)
      )
    );
    actions[4] = _vaultAction(
      "srm.setOraclesForMarket(staticCngnFeed) [USDC-per-cNGN: SRM Base convention]",
      ctx.srm,
      abi.encodeCall(
        StandardManager.setOraclesForMarket,
        (ctx.marketId, ISpotFeed(ctx.cngnFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
      )
    );
    actions[5] = _vaultAction(
      "srm.setOracleContingencyParams(zeroed)",
      ctx.srm,
      abi.encodeCall(StandardManager.setOracleContingencyParams, (ctx.marketId, ocParams))
    );
    actions[6] = _vaultAction(
      "srm.setBaseAssetMarginFactor(0) [cNGN gives zero margin credit]",
      ctx.srm,
      abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, 0, 0))
    );
    actions[7] = _vaultAction(
      "srm.setBorrowingEnabled(false) [GLOBAL to the SRM, not per-market]",
      ctx.srm,
      abi.encodeCall(StandardManager.setBorrowingEnabled, (false))
    );
    actions[8] = _vaultAction(
      "staticCngnFeed.acceptOwnership() [must be the vault]",
      ctx.cngnFeed,
      abi.encodeCall(IOwnable2Step.acceptOwnership, ())
    );
    actions[9] = _vaultAction(
      "staticStableFeed.acceptOwnership() [must be the vault]",
      ctx.stableFeed,
      abi.encodeCall(IOwnable2Step.acceptOwnership, ())
    );
    actions[10] = _vaultAction(
      "srm.setStableFeed(staticStableFeed) [GLOBAL: also affects market 1]",
      ctx.srm,
      abi.encodeCall(StandardManager.setStableFeed, (ISpotFeed(ctx.stableFeed)))
    );

    string memory json = "[";
    for (uint i = 0; i < actions.length; ++i) {
      json = string.concat(json, i == 0 ? "" : ",", actions[i]);
    }
    return string.concat(json, "]");
  }

  function _vaultAction(string memory description, address to, bytes memory data)
    internal
    pure
    returns (string memory)
  {
    return string.concat(
      '{"description":"', description, '","to":"', vm.toString(to), '","value":"0","data":"', vm.toString(data), '"}'
    );
  }
}
