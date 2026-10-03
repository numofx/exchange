// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {InterestRateModel} from "../src/assets/InterestRateModel.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {Utils} from "./utils.sol";
import {CNGNPerpCollateralBatch} from "./cngn-perp-collateral-batch.sol";

/**
 * @title DeployCngnPerpCollateral
 * @notice Deploys the perp stack's own cNGN escrow (a plain WrappedERC20Asset over Base cNGN) and
 *         a replacement InterestRateModel with a higher floor, nominates the escrow to the vault,
 *         and writes the two vault batches: deployments/{chainId}/CNGN_PERP_COLLATERAL.json,
 *         CNGN_PERP_COLLATERAL_VAULT_ACTIONS.json (configure: custody, haircut, whitelist, cap,
 *         rate model) and CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS.json (open deposits, last).
 *
 * @dev A SEPARATE escrow from spot's (WRAPPED_CNGN.json `base`): that one is whitelisted on the
 *      spot SRM, where cNGN earns no margin, and an asset whitelisted on two managers lets an
 *      account's cNGN be moved between stacks by a transfer. The perp escrow only ever knows the
 *      perp SRM.
 *
 * @dev The margin factor is not a knob. SIZED_MARGIN_FACTOR is what
 *      test/fork/CngnPerpCollateralFork.t.sol found for the venue's sizing case (a long-naira
 *      account that posted only cNGN, left at maintenance margin, through a 25% step), and this
 *      script refuses anything larger. Re-size there first, then change the constant.
 *
 * Usage (mainnet, from a keystore; the key never touches a command line). Needs no signer env;
 * set BASE_RPC_URL. `--sender` is required alongside `--account`: forge simulates with its
 * placeholder sender unless told the keystore's address, and the guard below refuses that (seen
 * 2026-10-03: "no sender given" with --account alone).
 *   forge script scripts/deploy-cngn-perp-collateral.s.sol --rpc-url $BASE_RPC_URL \
 *     --account numo-deployer --sender 0x2D724867d3AeD4A9F09c096B87F939285DD3AE2D --broadcast
 */
contract DeployCngnPerpCollateral is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_PERP_COLLATERAL";
  string internal constant VAULT_ACTIONS_NAME = "CNGN_PERP_COLLATERAL_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

  /// @dev Sized by the fork test (see the contract note). 50% of oracle value counts as maintenance
  ///      margin; a long-naira account on cNGN alone at MM is then still solvent after a 25% step.
  uint public constant SIZED_MARGIN_FACTOR = 0.5e18;
  /// @dev Initial margin credits the same haircut (perp IM/MM already differ, 33.3% vs 20%).
  uint public constant DEFAULT_IM_SCALE = 1e18;
  /// @dev Launch collateral cap, summed over every account under the perp SRM: one OI side. At the
  ///      sized factor it margins the whole short side on cNGN alone (25M x 0.5 / 0.333 = 37.5M
  ///      cNGN of notional against a 25M side). Raise it by vault transaction with the OI cap.
  uint public constant DEFAULT_COLLATERAL_CAP = 8_000_000e18;
  /// @dev The replacement rate model's floor: 10% on borrowed cash (the live model's is 2%). The
  ///      other parameters are the live model's (config-mainnet.sol): +8% x utilisation to 85%,
  ///      then +90% x the excess. A loan against cNGN is meant to be unattractive, not impossible;
  ///      a trader's own negative cash after a loss is small and short-lived.
  uint public constant DEFAULT_RATE_FLOOR = 0.1e18;
  uint internal constant RATE_MULTIPLIER = 0.08e18;
  uint internal constant HIGH_RATE_MULTIPLIER = 0.9e18;
  uint internal constant OPTIMAL_UTIL = 0.85e18;

  struct Params {
    address subAccounts;
    address cngnToken;
    address srm;
    address cash;
    address indexFeed;
    uint marketId;
    address vault;
    uint marginFactor;
    uint imScale;
    uint cap;
    uint rateFloor;
  }

  struct Deployed {
    WrappedERC20Asset escrow;
    InterestRateModel rateModel;
  }

  function run() external {
    Params memory params = _loadParams();
    address deployer = msg.sender;
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");

    vm.startBroadcast();
    Deployed memory deployed = deploy(params);
    vm.stopBroadcast();

    assertDeployed(deployed, params, deployer);
    CNGNPerpCollateralBatch.Ctx memory ctx = batchCtx(deployed, params);
    CNGNPerpCollateralBatch.checkPreconditions(ctx);
    _writeArtifacts(deployed, params, ctx);

    console2.log("perp cNGN escrow:", address(deployed.escrow));
    console2.log("rate model (floor raised):", address(deployed.rateModel));
    console2.log("nominated to vault:", params.vault);
    console2.log("margin factor (18dp):", params.marginFactor);
    console2.log("IM scale (18dp):", params.imScale);
    console2.log("collateral cap (cNGN, 18dp):", params.cap);
    console2.log("rate floor (18dp):", params.rateFloor);
    console2.log("batches hash:", vm.toString(CNGNPerpCollateralBatch.hash(ctx)));
    console2.log(
      "Vault executes the %s calls in %s.json IN ORDER; then, once the services are live, the 1 call in %s.json.",
      CNGNPerpCollateralBatch.ACTION_COUNT,
      VAULT_ACTIONS_NAME,
      ENABLE_ACTIONS_NAME
    );
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function _loadParams() internal view returns (Params memory params) {
    string memory stack = _readDeploymentFile(ARTIFACT_STACK);
    params.srm = vm.parseJsonAddress(stack, ".srm");
    params.cash = vm.parseJsonAddress(stack, ".cash");
    params.indexFeed = vm.parseJsonAddress(stack, ".indexFeed");
    params.marketId = vm.parseJsonUint(stack, ".marketId");
    params.subAccounts = vm.parseJsonAddress(_readDeploymentFile("core"), ".subAccounts");
    params.cngnToken = vm.parseJsonAddress(_readDeploymentFile("WRAPPED_CNGN"), ".wrappedAsset");
    params.vault = EXPECTED_VAULT;
    params.marginFactor = vm.envOr("CNGN_MARGIN_FACTOR", SIZED_MARGIN_FACTOR);
    params.imScale = vm.envOr("CNGN_IM_SCALE", DEFAULT_IM_SCALE);
    params.cap = vm.envOr("CNGN_COLLATERAL_CAP", DEFAULT_COLLATERAL_CAP);
    params.rateFloor = vm.envOr("CNGN_RATE_FLOOR", DEFAULT_RATE_FLOOR);

    if (params.marginFactor == 0 || params.marginFactor > SIZED_MARGIN_FACTOR) {
      revert("CNGN_MARGIN_FACTOR above the sized factor: re-size in CngnPerpCollateralFork.t.sol first");
    }
    if (params.imScale == 0 || params.imScale > 1e18) revert("CNGN_IM_SCALE must be in (0, 1]");
    if (params.cap == 0) revert("CNGN_COLLATERAL_CAP is zero");
    if (params.rateFloor < 0.05e18 || params.rateFloor > 0.5e18) revert("CNGN_RATE_FLOOR outside 5%..50%");
    if (params.cash.code.length == 0) revert("perp cash has no code");
    if (CashAsset(params.cash).owner() != params.vault) revert("perp cash owner is not the recorded vault");
    if (InterestRateModel(address(CashAsset(params.cash).rateModel())).minRate() >= params.rateFloor) {
      revert("the live rate floor is already that high");
    }
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code - wrong chain?");
    if (params.cngnToken.code.length == 0) revert("cNGN token has no code");
    if (IERC20Metadata(params.cngnToken).decimals() > 18) revert("unexpected cNGN decimals");
    if (params.srm.code.length == 0) revert("perp srm has no code");
    if (StandardManager(params.srm).owner() != params.vault) revert("perp srm owner is not the recorded vault");
    // A market that already credits a base asset has one; a second escrow would be a mistake.
    (uint factor,) = StandardManager(params.srm).baseMarginParams(params.marketId);
    if (factor != 0) revert("market already has a base margin factor: is an escrow already live?");
    (ISpotFeed spot,,) = StandardManager(params.srm).getMarketFeeds(params.marketId);
    if (address(spot) != params.indexFeed) revert("market spot feed is not the perp index feed");
  }

  string internal constant ARTIFACT_STACK = "CNGN_PERP_STACK";

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployed memory deployed) {
    deployed.escrow = new WrappedERC20Asset(ISubAccounts(params.subAccounts), IERC20Metadata(params.cngnToken));
    deployed.escrow.transferOwnership(params.vault);
    // Not Ownable: nothing to nominate. It only ever does arithmetic for the cash that points at it.
    deployed.rateModel = new InterestRateModel(params.rateFloor, RATE_MULTIPLIER, HIGH_RATE_MULTIPLIER, OPTIMAL_UTIL);
  }

  function batchCtx(Deployed memory deployed, Params memory params)
    public
    pure
    returns (CNGNPerpCollateralBatch.Ctx memory)
  {
    return CNGNPerpCollateralBatch.Ctx({
      vault: params.vault,
      srm: params.srm,
      escrow: address(deployed.escrow),
      cash: params.cash,
      rateModel: address(deployed.rateModel),
      indexFeed: params.indexFeed,
      marketId: params.marketId,
      marginFactor: params.marginFactor,
      imScale: params.imScale,
      cap: params.cap
    });
  }

  // ---------------------------------------------------------------------------------------------
  // postconditions
  // ---------------------------------------------------------------------------------------------

  function assertDeployed(Deployed memory deployed, Params memory params, address deployer) public view {
    WrappedERC20Asset escrow = deployed.escrow;
    if (deployed.rateModel.minRate() != params.rateFloor) revert("rate model floor mismatch");
    if (deployed.rateModel.rateMultiplier() != RATE_MULTIPLIER) revert("rate model multiplier mismatch");
    if (address(escrow.wrappedAsset()) != params.cngnToken) revert("escrow wraps the wrong token");
    if (escrow.assetDecimals() != IERC20Metadata(params.cngnToken).decimals()) revert("escrow decimals mismatch");
    if (address(escrow.subAccounts()) != params.subAccounts) revert("escrow bound to the wrong SubAccounts");
    if (escrow.owner() != deployer) revert("escrow owner is not the deployer");
    if (escrow.pendingOwner() != params.vault) revert("escrow not nominated to the vault");
    if (escrow.whitelistedManager(params.srm)) revert("escrow must not be open before the vault batch");
    if (escrow.totalPositionCap(StandardManager(params.srm)) != 0) revert("escrow cap must be unset before the batch");
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployed memory deployed, Params memory params, CNGNPerpCollateralBatch.Ctx memory ctx)
    internal
  {
    string memory obj = "cngn-perp-collateral";
    vm.serializeAddress(obj, "escrow", address(deployed.escrow));
    vm.serializeAddress(obj, "rateModel", address(deployed.rateModel));
    vm.serializeAddress(obj, "cngnToken", params.cngnToken);
    vm.serializeAddress(obj, "srm", params.srm);
    vm.serializeAddress(obj, "cash", params.cash);
    vm.serializeAddress(obj, "indexFeed", params.indexFeed);
    vm.serializeUint(obj, "marketId", params.marketId);
    vm.serializeUint(obj, "marginFactor", params.marginFactor);
    vm.serializeUint(obj, "imScale", params.imScale);
    vm.serializeUint(obj, "collateralCap", params.cap);
    vm.serializeUint(obj, "rateFloor", params.rateFloor);
    string memory json = vm.serializeBytes32(obj, "batchHash", CNGNPerpCollateralBatch.hash(ctx));
    _writeToDeployments(ARTIFACT_NAME, json);
    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(ctx));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(ctx));
  }

  /// @dev The configuring batch in the recorded vault-action format, one object per call, in order.
  function vaultActionsJson(CNGNPerpCollateralBatch.Ctx memory ctx) public pure returns (string memory json) {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = CNGNPerpCollateralBatch.build(ctx);
    return _actionsJson(to, data, descriptions);
  }

  /// @dev The enabling action, its own batch.
  function enableActionsJson(CNGNPerpCollateralBatch.Ctx memory ctx) public pure returns (string memory json) {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = CNGNPerpCollateralBatch.buildEnable(ctx);
    return _actionsJson(to, data, descriptions);
  }

  function _actionsJson(address[] memory to, bytes[] memory data, string[] memory descriptions)
    internal
    pure
    returns (string memory json)
  {
    json = "[";
    for (uint i = 0; i < to.length; i++) {
      json = string.concat(json, i == 0 ? "" : ",", _action(descriptions[i], to[i], data[i]));
    }
    json = string.concat(json, "]");
  }

  function _action(string memory description, address to, bytes memory data) internal pure returns (string memory) {
    return string.concat(
      '{"description":"',
      description,
      '","to":"',
      vm.toString(to),
      '","value":"0","data":"',
      vm.toString(data),
      '","digest":"',
      vm.toString(CNGNPerpCollateralBatch.actionHash(to, data)),
      '"}'
    );
  }
}
