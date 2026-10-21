// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {MarginEngineV1 as MarginEngine} from "../src/legacy/v1/MarginEngineV1.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {ChainlinkSpotFeed, IAggregatorV3} from "../src/feeds/ChainlinkSpotFeed.sol";
import {Utils} from "./utils.sol";
import {EURCSpotBatch} from "./eurc-spot-batch.sol";

/**
 * @title DeployEurcSpot
 * @notice Deploys the EURC escrow (a plain WrappedERC20Asset over Base EURC) and its spot feed (a ChainlinkSpotFeed over
 *         Chainlink EURC/USD), nominates both to the vault, and writes deployments/{chainId}/EURC_SPOT.json,
 *         EURC_SPOT_VAULT_ACTIONS.json (configure: custody, market 2, feed, haircut, whitelist, cap) and
 *         EURC_SPOT_ENABLE_VAULT_ACTIONS.json (open deposits, last). See scripts/eurc-spot-batch.sol for the batches.
 *
 * @dev The margin factor and IM scale are not knobs: test/fork/EurcSpotFork.t.sol pins what they buy, and this script
 *      refuses anything more generous. Re-size there first, then change the constants.
 *
 * Usage (mainnet, from a keystore; the key never touches a command line). Needs no signer env; set BASE_RPC_URL.
 * `--sender` is required alongside `--account` (forge simulates with its placeholder sender otherwise).
 *   forge script scripts/deploy-eurc-spot.s.sol --rpc-url $BASE_RPC_URL \
 *     --account numo-deployer --sender 0x2D724867d3AeD4A9F09c096B87F939285DD3AE2D --broadcast
 */
contract DeployEurcSpot is Utils {
  string internal constant ARTIFACT_NAME = "EURC_SPOT";
  string internal constant VAULT_ACTIONS_NAME = "EURC_SPOT_VAULT_ACTIONS";
  string internal constant ENABLE_ACTIONS_NAME = "EURC_SPOT_ENABLE_VAULT_ACTIONS";

  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
  /// @dev Circle EURC on Base.
  address public constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
  /// @dev Chainlink EURC / USD on Base (8 decimals; 24h heartbeat or deviation).
  address public constant EURC_USD_AGGREGATOR = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;

  /// @dev Chainlink's 24h heartbeat plus an hour for a late round. Past it, accounts holding EURC fail closed.
  uint64 public constant FEED_HEARTBEAT = 25 hours;
  /// @dev 90% of oracle value counts as maintenance margin (a 10% EURC/USD move from MM to insolvency).
  uint public constant SIZED_MARGIN_FACTOR = 0.9e18;
  /// @dev Initial margin credits 0.9 x 0.8 = 72%: what an account can borrow USDC against.
  uint public constant SIZED_IM_SCALE = 0.8e18;
  /// @dev 5,000,000 EURC (about 10% of Base supply at listing), summed over every account under the engine.
  uint public constant DEFAULT_CAP = 5_000_000e18;

  struct Params {
    address subAccounts;
    address engine;
    address eurc;
    address aggregator;
    address vault;
    uint marketId;
    uint marginFactor;
    uint imScale;
    uint cap;
  }

  struct Deployed {
    WrappedERC20Asset escrow;
    ChainlinkSpotFeed spotFeed;
  }

  function run() external {
    Params memory params = loadParams();
    address deployer = msg.sender;
    if (deployer == FORGE_DEFAULT_SENDER) revert("run with --account <keystore> (or --private-key): no sender given");

    vm.startBroadcast();
    Deployed memory deployed = deploy(params);
    vm.stopBroadcast();

    assertDeployed(deployed, params, deployer);
    EURCSpotBatch.Ctx memory ctx = batchCtx(deployed, params);
    EURCSpotBatch.checkPreconditions(ctx);
    _writeArtifacts(deployed, params, ctx);

    console2.log("EURC escrow:", address(deployed.escrow));
    console2.log("EURC spot feed (Chainlink EURC/USD):", address(deployed.spotFeed));
    console2.log("nominated to vault:", params.vault);
    console2.log("market id:", params.marketId);
    console2.log("margin factor (18dp):", params.marginFactor);
    console2.log("IM scale (18dp):", params.imScale);
    console2.log("deposit cap (EURC, 18dp):", params.cap);
    console2.log("batches hash:", vm.toString(EURCSpotBatch.hash(ctx)));
    console2.log(
      "Vault executes the %s calls in %s.json IN ORDER; then, once the services are live, the 1 call in %s.json.",
      EURCSpotBatch.ACTION_COUNT,
      VAULT_ACTIONS_NAME,
      ENABLE_ACTIONS_NAME
    );
  }

  // ---------------------------------------------------------------------------------------------
  // inputs
  // ---------------------------------------------------------------------------------------------

  function loadParams() public view returns (Params memory params) {
    params.engine = vm.parseJsonAddress(_readDeploymentFile("MARGIN_ENGINE"), ".manager");
    params.subAccounts = address(MarginEngine(params.engine).subAccounts());
    params.eurc = EURC;
    params.aggregator = EURC_USD_AGGREGATOR;
    params.vault = EXPECTED_VAULT;
    params.marketId = MarginEngine(params.engine).lastMarketId() + 1;
    params.marginFactor = vm.envOr("EURC_MARGIN_FACTOR", SIZED_MARGIN_FACTOR);
    params.imScale = vm.envOr("EURC_IM_SCALE", SIZED_IM_SCALE);
    params.cap = vm.envOr("EURC_CAP", DEFAULT_CAP);
    checkParams(params);
  }

  function checkParams(Params memory params) public view {
    if (params.marginFactor == 0 || params.marginFactor > SIZED_MARGIN_FACTOR) {
      revert("EURC_MARGIN_FACTOR above the sized factor: re-size in EurcSpotFork.t.sol first");
    }
    if (params.imScale == 0 || params.imScale > SIZED_IM_SCALE) {
      revert("EURC_IM_SCALE above the sized scale: re-size in EurcSpotFork.t.sol first");
    }
    if (params.cap == 0 || params.cap > DEFAULT_CAP) revert("EURC_CAP outside (0, 5M EURC]");
    if (params.marketId != 2) revert("the engine does not have exactly one market: re-read MARGIN_ENGINE.json");
    if (params.engine.code.length == 0) revert("engine has no code - wrong chain?");
    if (MarginEngine(params.engine).owner() != params.vault) revert("engine owner is not the recorded vault");
    if (params.subAccounts.code.length == 0) revert("subAccounts has no code");
    if (params.eurc.code.length == 0) revert("EURC has no code");
    if (IERC20Metadata(params.eurc).decimals() != 6) revert("unexpected EURC decimals");
    if (IAggregatorV3(params.aggregator).decimals() != 8) revert("unexpected EURC/USD aggregator decimals");
  }

  // ---------------------------------------------------------------------------------------------
  // deployment: public so the fork test deploys exactly what the script deploys
  // ---------------------------------------------------------------------------------------------

  function deploy(Params memory params) public returns (Deployed memory deployed) {
    deployed.escrow = new WrappedERC20Asset(ISubAccounts(params.subAccounts), IERC20Metadata(params.eurc));
    deployed.escrow.transferOwnership(params.vault);
    deployed.spotFeed = new ChainlinkSpotFeed(IAggregatorV3(params.aggregator), FEED_HEARTBEAT);
    deployed.spotFeed.transferOwnership(params.vault);
  }

  function batchCtx(Deployed memory deployed, Params memory params) public pure returns (EURCSpotBatch.Ctx memory) {
    return EURCSpotBatch.Ctx({
      vault: params.vault,
      engine: params.engine,
      escrow: address(deployed.escrow),
      spotFeed: address(deployed.spotFeed),
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
    if (address(escrow.wrappedAsset()) != params.eurc) revert("escrow wraps the wrong token");
    if (escrow.assetDecimals() != 6) revert("escrow decimals mismatch");
    if (address(escrow.subAccounts()) != params.subAccounts) revert("escrow bound to the wrong SubAccounts");
    if (escrow.owner() != deployer) revert("escrow owner is not the deployer");
    if (escrow.pendingOwner() != params.vault) revert("escrow not nominated to the vault");
    if (escrow.whitelistedManager(params.engine)) revert("escrow must not be open before the vault batch");
    if (escrow.totalPositionCap(IManager(params.engine)) != 0) revert("escrow cap must be unset before the batch");
    ChainlinkSpotFeed feed = deployed.spotFeed;
    if (address(feed.aggregator()) != params.aggregator) revert("feed reads the wrong aggregator");
    if (feed.heartbeat() != FEED_HEARTBEAT) revert("feed heartbeat mismatch");
    if (feed.owner() != deployer) revert("feed owner is not the deployer");
    if (feed.pendingOwner() != params.vault) revert("feed not nominated to the vault");
  }

  // ---------------------------------------------------------------------------------------------
  // artifacts
  // ---------------------------------------------------------------------------------------------

  function _writeArtifacts(Deployed memory deployed, Params memory params, EURCSpotBatch.Ctx memory ctx) internal {
    string memory obj = "eurc-spot";
    vm.serializeAddress(obj, "escrow", address(deployed.escrow));
    vm.serializeAddress(obj, "spotFeed", address(deployed.spotFeed));
    vm.serializeAddress(obj, "aggregator", params.aggregator);
    vm.serializeAddress(obj, "eurcToken", params.eurc);
    vm.serializeAddress(obj, "engine", params.engine);
    vm.serializeAddress(obj, "subAccounts", params.subAccounts);
    vm.serializeUint(obj, "feedHeartbeat", FEED_HEARTBEAT);
    vm.serializeUint(obj, "marketId", params.marketId);
    vm.serializeUint(obj, "marginFactor", params.marginFactor);
    vm.serializeUint(obj, "imScale", params.imScale);
    vm.serializeUint(obj, "cap", params.cap);
    string memory json = vm.serializeBytes32(obj, "batchHash", EURCSpotBatch.hash(ctx));
    _writeToDeployments(ARTIFACT_NAME, json);
    _writeToDeployments(VAULT_ACTIONS_NAME, vaultActionsJson(ctx));
    _writeToDeployments(ENABLE_ACTIONS_NAME, enableActionsJson(ctx));
  }

  /// @dev The configuring batch in the recorded vault-action format, one object per call, in order.
  function vaultActionsJson(EURCSpotBatch.Ctx memory ctx) public pure returns (string memory) {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = EURCSpotBatch.build(ctx);
    return _actionsJson(to, data, descriptions);
  }

  /// @dev The enabling action, its own batch.
  function enableActionsJson(EURCSpotBatch.Ctx memory ctx) public pure returns (string memory) {
    (address[] memory to, bytes[] memory data, string[] memory descriptions) = EURCSpotBatch.buildEnable(ctx);
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
      vm.toString(EURCSpotBatch.actionHash(to, data)),
      '"}'
    );
  }
}
