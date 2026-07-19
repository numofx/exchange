// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {PerpAsset} from "../src/assets/PerpAsset.sol";
import {LyraSpotDiffFeed} from "../src/feeds/LyraSpotDiffFeed.sol";
import {PMRM} from "../src/risk-managers/PMRM.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {ISpotDiffFeed} from "../src/interfaces/ISpotDiffFeed.sol";
import {InvertedChainlinkSpotFeed} from "../src/feeds/InvertedChainlinkSpotFeed.sol";
import {IAggregatorV3} from "../src/feeds/ChainlinkSpotFeed.sol";
import {SpotPassthroughDiffFeed} from "../src/feeds/SpotPassthroughDiffFeed.sol";

import "forge-std/console2.sol";
import {Deployment, ConfigJson} from "./types.sol";
import {Utils} from "./utils.sol";

// get all default params
import "./config-mainnet.sol";


/**
 * MARKET_NAME=AAVE PRIVATE_KEY={} MAINNET_OWNER={} forge script scripts/deploy-perp-only-market.s.sol --private-key {} --rpc-url {} --verify --verifier blockscout --verifier-url {} --broadcast --priority-gas-price 1
 **/

// MAINNET 
// RPC: https://rpc.lyra.finance
// VERIFIER: https://explorer.derive.xyz/api

// TESTNET
// RPC: https://rpc-prod-testnet-0eakp60405.t.conduit.xyz
// VERIFIER: https://explorer-prod-testnet-0eakp60405.t.conduit.xyz/api

// will need to use an API key endpoint as limits will get hit
contract DeployPerpOnlyMarket is Utils {
  address internal constant BASE_NGN_USD_CHAINLINK = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD;
  uint64 internal constant NGN_CHAINLINK_HEARTBEAT = 1 days;
  uint64 internal constant L2_SEQUENCER_GRACE_PERIOD = 1 hours;

  struct PerpOnlyMarket {
    PerpAsset perp;
    ISpotFeed spotFeed;
    ISpotDiffFeed perpFeed;
    ISpotDiffFeed iapFeed;
    ISpotDiffFeed ibpFeed;
  }

  /// @dev main function
  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    // revert if not found
    string memory marketName = vm.envString("MARKET_NAME");

    console2.log("Start deploying new market: ", marketName);
    address deployer = vm.addr(deployerPrivateKey);
    console2.log("Deployer: ", deployer);

    // load configs
    ConfigJson memory config = _loadConfig();

    // load deployed core contracts
    Deployment memory deployment = _loadDeployment();

    // deploy core contracts
    PerpOnlyMarket memory market = _deployMarketContracts(marketName, config, deployment);
    _setCapForManager(address(deployment.srm), marketName, market);
    _whitelistManager(address(deployment.srm), market);

    if (block.chainid != 957) {
      _registerMarketToSRM(marketName, deployment, market);

      if (keccak256(abi.encodePacked(marketName)) != keccak256(abi.encodePacked("NGN"))) {
        PMRM(_getV2CoreContract("ETH", "pmrm")).setWhitelistedCallee(address(market.spotFeed), true);
        PMRM(_getV2CoreContract("ETH", "pmrm")).setWhitelistedCallee(address(market.iapFeed), true);
        PMRM(_getV2CoreContract("ETH", "pmrm")).setWhitelistedCallee(address(market.ibpFeed), true);
        PMRM(_getV2CoreContract("ETH", "pmrm")).setWhitelistedCallee(address(market.perpFeed), true);

        PMRM(_getV2CoreContract("BTC", "pmrm")).setWhitelistedCallee(address(market.spotFeed), true);
        PMRM(_getV2CoreContract("BTC", "pmrm")).setWhitelistedCallee(address(market.iapFeed), true);
        PMRM(_getV2CoreContract("BTC", "pmrm")).setWhitelistedCallee(address(market.ibpFeed), true);
        PMRM(_getV2CoreContract("BTC", "pmrm")).setWhitelistedCallee(address(market.perpFeed), true);
      }

      // TODO: add to matching modules (TRADE/RFQ/LIQUIDATION)
    } else {
      _transferOwner(marketName, market, vm.envAddress("MAINNET_OWNER"));
    }

    _writeToMarketJson(marketName, market);

    vm.stopBroadcast();
  }


  /// @dev deploy all contract needed for a single market
  function _deployMarketContracts(
    string memory marketName,
    ConfigJson memory config,
    Deployment memory deployment
  ) internal returns (PerpOnlyMarket memory market)  {
    if (keccak256(abi.encodePacked(marketName)) == keccak256(abi.encodePacked("NGN"))) {
      market.spotFeed = new InvertedChainlinkSpotFeed(
        IAggregatorV3(BASE_NGN_USD_CHAINLINK),
        IAggregatorV3(address(0)),
        NGN_CHAINLINK_HEARTBEAT,
        L2_SEQUENCER_GRACE_PERIOD
      );
      market.perpFeed = new SpotPassthroughDiffFeed(market.spotFeed);
      market.iapFeed = new SpotPassthroughDiffFeed(market.spotFeed);
      market.ibpFeed = new SpotPassthroughDiffFeed(market.spotFeed);
    } else {
      LyraSpotFeed spotFeed = new LyraSpotFeed();
      LyraSpotDiffFeed perpFeed = new LyraSpotDiffFeed(spotFeed);
      LyraSpotDiffFeed iapFeed = new LyraSpotDiffFeed(spotFeed);
      LyraSpotDiffFeed ibpFeed = new LyraSpotDiffFeed(spotFeed);

      spotFeed.setHeartbeat(Config.SPOT_HEARTBEAT);
      perpFeed.setHeartbeat(Config.PERP_HEARTBEAT);
      iapFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
      ibpFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);

      perpFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
      iapFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
      ibpFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);

      for (uint i=0; i<config.feedSigners.length; ++i) {
        spotFeed.addSigner(config.feedSigners[i], true);
        perpFeed.addSigner(config.feedSigners[i], true);
        iapFeed.addSigner(config.feedSigners[i], true);
        ibpFeed.addSigner(config.feedSigners[i], true);
      }

      spotFeed.setRequiredSigners(config.requiredSigners);
      perpFeed.setRequiredSigners(config.requiredSigners);
      iapFeed.setRequiredSigners(config.requiredSigners);
      ibpFeed.setRequiredSigners(config.requiredSigners);

      market.spotFeed = spotFeed;
      market.perpFeed = perpFeed;
      market.iapFeed = iapFeed;
      market.ibpFeed = ibpFeed;
    }

    // Deploy and configure perp
    (int staticInterestRate, int fundingRateCap, uint fundingConvergencePeriod) = Config.getPerpParams();

    market.perp = new PerpAsset(deployment.subAccounts);
    market.perp.setRateBounds(fundingRateCap);
    market.perp.setStaticInterestRate(staticInterestRate);
    if (fundingConvergencePeriod != 8e18) {
      market.perp.setConvergencePeriod(fundingConvergencePeriod);
    }

    // Add feeds to perp
    market.perp.setSpotFeed(market.spotFeed);
    market.perp.setPerpFeed(market.perpFeed);
    market.perp.setImpactFeeds(market.iapFeed, market.ibpFeed);

  }

  function _registerMarketToSRM(string memory marketName, Deployment memory deployment, PerpOnlyMarket memory market) internal {
    // find market ID
    uint marketId = deployment.srm.createMarket(marketName);

    console2.log("market ID for newly created market:", marketId);

    (
      IStandardManager.PerpMarginRequirements memory perpMarginRequirements,
      ,
      IStandardManager.OracleContingencyParams memory oracleContingencyParams,
    ) = Config.getSRMParams(marketName);

    // set assets per market
    deployment.srm.whitelistAsset(market.perp, marketId, IStandardManager.AssetType.Perpetual);

    // set oracles
    deployment.srm.setOraclesForMarket(marketId, market.spotFeed, IForwardFeed(address(0)), IVolFeed(address(0)));

    // set params
    deployment.srm.setOracleContingencyParams(marketId, oracleContingencyParams);
    deployment.srm.setPerpMarginRequirements(marketId, perpMarginRequirements.mmPerpReq, perpMarginRequirements.imPerpReq);

    deployment.srmViewer.setOIFeeRateBPS(address(market.perp), Config.OI_FEE_BPS);

    deployment.srm.setWhitelistedCallee(address(market.spotFeed), true);
    deployment.srm.setWhitelistedCallee(address(market.iapFeed), true);
    deployment.srm.setWhitelistedCallee(address(market.ibpFeed), true);
    deployment.srm.setWhitelistedCallee(address(market.perpFeed), true);
  }

  function _whitelistManager(address manager, PerpOnlyMarket memory market) internal {
    market.perp.setWhitelistManager(manager, true);
  }

  function _setCapForManager(address manager, string memory marketName, PerpOnlyMarket memory market) internal {
    (uint perpCap,, ) = Config.getSRMCaps(marketName);

    market.perp.setTotalPositionCap(IManager(manager), perpCap);
  }

  function _transferOwner(string memory marketName, PerpOnlyMarket memory market, address newOwner) internal {
    market.perp.transferOwnership(newOwner);
    if (keccak256(abi.encodePacked(marketName)) == keccak256(abi.encodePacked("NGN"))) {
      InvertedChainlinkSpotFeed(address(market.spotFeed)).transferOwnership(newOwner);
    } else {
      LyraSpotFeed(address(market.spotFeed)).transferOwnership(newOwner);
      LyraSpotDiffFeed(address(market.iapFeed)).transferOwnership(newOwner);
      LyraSpotDiffFeed(address(market.ibpFeed)).transferOwnership(newOwner);
      LyraSpotDiffFeed(address(market.perpFeed)).transferOwnership(newOwner);
    }

    console2.log("New owner for market: ", newOwner);
  }

  /**
   * @dev write to deployments/{network}/{marketName}.json
   */
  function _writeToMarketJson(string memory name, PerpOnlyMarket memory market) internal {

    string memory objKey = "market-deployments";

    vm.serializeAddress(objKey, "perp", address(market.perp));
    vm.serializeAddress(objKey, "spotFeed", address(market.spotFeed));
    vm.serializeAddress(objKey, "perpFeed", address(market.perpFeed));
    vm.serializeAddress(objKey, "ibpFeed", address(market.ibpFeed));
    string memory finalObj = vm.serializeAddress(objKey, "iapFeed", address(market.iapFeed));

    // build path
    _writeToDeployments(name, finalObj);
  }

}
