// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {BaseManager} from "../src/risk-managers/BaseManager.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";

/**
 * @dev Registers the existing wrapped cNGN asset as a base-only market on the already-deployed SRM,
 *      so USDCcNGN-SPOT can run under a manager with real risk knobs instead of DeliverableFXManager.
 *
 * @dev Deploys nothing. The wrapped cNGN asset and the cNGN spot feed are reused as-is, so
 *      CNGN_SPOT_ASSET_ADDRESS in the markets service does not change. Every call below is
 *      onlyOwner on a vault-owned contract, so this script only writes the calldata to
 *      deployments/{chainId}/CNGN_SPOT_SRM_VAULT_ACTIONS.json for the admin vault to execute in order.
 *
 * @dev marginFactor is set to 0: wrapped cNGN contributes no margin, so cash is the only thing that
 *      can fund a buy and the wrapped asset cannot go short. See
 *      test/integration-tests/standard-manager/spot-trade.sol for both directions.
 *
 * Usage: forge script scripts/register-cngn-spot-srm.s.sol --rpc-url $BASE_RPC_URL
 *        (the rpc is read-only, used to resolve the next marketId; override with CNGN_MARKET_ID)
 */
contract RegisterCNGNSpotOnSRM is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_SPOT_SRM_VAULT_ACTIONS";
  string internal constant MARKET_NAME = "CNGN";

  /// @dev Config.getSRMCaps("CNGN") returns 3_000_000e18, which is ~$2k at 1,500 cNGN/USDC — sized for
  ///      a per-contract deliverable leg, not for spot inventory. Spot needs a cap in cNGN terms:
  ///      1.5e9 cNGN is ~$1m at 1,500. Override with CNGN_SPOT_BASE_CAP before the vault signs.
  uint internal constant DEFAULT_BASE_CAP = 1_500_000_000e18;
  uint internal constant REFERENCE_RATE = 1_500e18;

  function run() external {
    Deployment memory deployment = _loadDeployment();

    string memory cngnDeployment = _readDeploymentFile("CNGN");
    address wrappedCngn = vm.parseJsonAddress(cngnDeployment, ".base");
    address cngnSpotFeed = vm.parseJsonAddress(cngnDeployment, ".spotFeed");
    if (wrappedCngn == address(0) || cngnSpotFeed == address(0)) revert("CNGN deployment incomplete");

    // createMarket assigns ++lastMarketId, so the id the later calls must use is only knowable
    // against live state. Reading it wrong silently points the market config at another market.
    uint marketId = vm.envOr("CNGN_MARKET_ID", uint(0));
    if (marketId == 0) {
      marketId = deployment.srm.lastMarketId() + 1;
      if (marketId == 1) {
        console2.log("WARNING: lastMarketId read as 0 - run against an rpc or set CNGN_MARKET_ID");
      }
    }

    uint baseCap = vm.envOr("CNGN_SPOT_BASE_CAP", DEFAULT_BASE_CAP);

    Ctx memory ctx = Ctx({
      srm: address(deployment.srm),
      wrappedCngn: wrappedCngn,
      spotFeed: cngnSpotFeed,
      marketId: marketId,
      baseCap: baseCap
    });

    string memory json = _buildActions(ctx);

    _writeToDeployments(ARTIFACT_NAME, json);

    console2.log("SRM:", address(deployment.srm));
    console2.log("wrapped cNGN (unchanged, still CNGN_SPOT_ASSET_ADDRESS):", wrappedCngn);
    console2.log("cNGN spot feed:", cngnSpotFeed);
    console2.log("market id the vault must create:", marketId);
    console2.log("base position cap (cNGN):", baseCap);
    console2.log("  ~USDC notional at %s cNGN/USDC:", REFERENCE_RATE / 1e18, baseCap / REFERENCE_RATE);
    console2.log("  CONFIRM this cap before signing - it is the venue's total cNGN inventory limit");
    console2.log("Vault must execute the calls in %s.json IN ORDER", ARTIFACT_NAME);
  }

  struct Ctx {
    address srm;
    address wrappedCngn;
    address spotFeed;
    uint marketId;
    uint baseCap;
  }

  function _buildActions(Ctx memory ctx) internal pure returns (string memory) {
    // no oracle contingency: at marginFactor 0 the base margin is 0, and _getBaseMarginAndMtM
    // returns before the contingency penalty, so a non-zero threshold here would be inert config
    IStandardManager.OracleContingencyParams memory ocParams =
      IStandardManager.OracleContingencyParams({perpThreshold: 0, optionThreshold: 0, baseThreshold: 0, OCFactor: 0});

    string[] memory actions = new string[](9);

    actions[0] =
      _vaultAction("srm.createMarket(CNGN)", ctx.srm, abi.encodeCall(StandardManager.createMarket, (MARKET_NAME)));
    actions[1] = _vaultAction(
      "wrappedCngn.setWhitelistManager(srm)",
      ctx.wrappedCngn,
      abi.encodeCall(WrappedERC20Asset(ctx.wrappedCngn).setWhitelistManager, (ctx.srm, true))
    );
    actions[2] = _vaultAction(
      "wrappedCngn.setTotalPositionCap(srm)",
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
      "srm.setOraclesForMarket(cngnSpotFeed)",
      ctx.srm,
      abi.encodeCall(
        StandardManager.setOraclesForMarket,
        (ctx.marketId, ISpotFeed(ctx.spotFeed), IForwardFeed(address(0)), IVolFeed(address(0)))
      )
    );
    actions[5] = _vaultAction(
      "srm.setOracleContingencyParams(zeroed)",
      ctx.srm,
      abi.encodeCall(StandardManager.setOracleContingencyParams, (ctx.marketId, ocParams))
    );
    actions[6] = _vaultAction(
      "srm.setBaseAssetMarginFactor(0)",
      ctx.srm,
      abi.encodeCall(StandardManager.setBaseAssetMarginFactor, (ctx.marketId, 0, 0))
    );
    actions[7] = _vaultAction(
      "srm.setBorrowingEnabled(false)", ctx.srm, abi.encodeCall(StandardManager.setBorrowingEnabled, (false))
    );
    actions[8] = _vaultAction(
      "srm.setWhitelistedCallee(cngnSpotFeed)",
      ctx.srm,
      abi.encodeCall(BaseManager.setWhitelistedCallee, (ctx.spotFeed, true))
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
