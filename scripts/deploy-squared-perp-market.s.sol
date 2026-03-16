// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {Utils} from "./utils.sol";
import {ConfigJson, Deployment} from "./types.sol";
import "./config-mainnet.sol";

import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {LyraSpotDiffFeed} from "../src/feeds/LyraSpotDiffFeed.sol";
import {ChainlinkSpotFeed, IAggregatorV3} from "../src/feeds/ChainlinkSpotFeed.sol";
import {InvertedChainlinkSpotFeed} from "../src/feeds/InvertedChainlinkSpotFeed.sol";
import {SquaredPerpAsset} from "../src/assets/SquaredPerpAsset.sol";
import {BasePortfolioViewer} from "../src/risk-managers/BasePortfolioViewer.sol";
import {SquaredPerpManager} from "../src/risk-managers/SquaredPerpManager.sol";

/**
 * MARKET_NAME=SFP forge script scripts/deploy-squared-perp-market.s.sol --rpc-url <rpc> --broadcast
 */
contract DeploySquaredPerpMarket is Utils {
  address internal constant BASE_BTC_USD_CHAINLINK = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
  address internal constant BASE_NGN_USD_CHAINLINK = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD;
  uint64 internal constant CHAINLINK_SPOT_HEARTBEAT = 60 minutes;
  uint64 internal constant L2_SEQUENCER_GRACE_PERIOD = 1 hours;

  struct SquaredPerpDeployment {
    SquaredPerpAsset perp;
    LyraSpotDiffFeed perpFeed;
    LyraSpotDiffFeed iapFeed;
    LyraSpotDiffFeed ibpFeed;
    BasePortfolioViewer viewer;
    SquaredPerpManager manager;
    ISpotFeed spotFeed;
  }

  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    string memory marketName = vm.envString("MARKET_NAME");

    console2.log("Start deploying squared perp market:", marketName);
    console2.log("Deployer:", vm.addr(deployerPrivateKey));

    ConfigJson memory config = _loadConfig();
    Deployment memory deployment = _loadDeployment();
    SquaredPerpDeployment memory squaredPerpDeployment = _deploySquaredPerpContracts(marketName, config, deployment);

    _setPermissionsAndRisk(marketName, deployment, squaredPerpDeployment);
    _writeSquaredPerpArtifact(marketName, squaredPerpDeployment);

    vm.stopBroadcast();
  }

  function _deploySquaredPerpContracts(
    string memory marketName,
    ConfigJson memory config,
    Deployment memory deployment
  ) internal returns (SquaredPerpDeployment memory squaredPerpDeployment) {
    squaredPerpDeployment.spotFeed = _getSquaredPerpSpotFeed(marketName);

    squaredPerpDeployment.perpFeed = new LyraSpotDiffFeed(squaredPerpDeployment.spotFeed);
    squaredPerpDeployment.iapFeed = new LyraSpotDiffFeed(squaredPerpDeployment.spotFeed);
    squaredPerpDeployment.ibpFeed = new LyraSpotDiffFeed(squaredPerpDeployment.spotFeed);

    squaredPerpDeployment.perpFeed.setHeartbeat(Config.PERP_HEARTBEAT);
    squaredPerpDeployment.iapFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);
    squaredPerpDeployment.ibpFeed.setHeartbeat(Config.IMPACT_PRICE_HEARTBEAT);

    squaredPerpDeployment.perpFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
    squaredPerpDeployment.iapFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);
    squaredPerpDeployment.ibpFeed.setSpotDiffCap(Config.PERP_MAX_PERCENT_DIFF);

    for (uint i = 0; i < config.feedSigners.length; ++i) {
      squaredPerpDeployment.perpFeed.addSigner(config.feedSigners[i], true);
      squaredPerpDeployment.iapFeed.addSigner(config.feedSigners[i], true);
      squaredPerpDeployment.ibpFeed.addSigner(config.feedSigners[i], true);
    }

    squaredPerpDeployment.perpFeed.setRequiredSigners(config.requiredSigners);
    squaredPerpDeployment.iapFeed.setRequiredSigners(config.requiredSigners);
    squaredPerpDeployment.ibpFeed.setRequiredSigners(config.requiredSigners);

    squaredPerpDeployment.perp = new SquaredPerpAsset(deployment.subAccounts);
    squaredPerpDeployment.perp.setSpotFeed(squaredPerpDeployment.spotFeed);
    squaredPerpDeployment.perp.setPerpFeed(squaredPerpDeployment.perpFeed);
    squaredPerpDeployment.perp.setImpactFeeds(squaredPerpDeployment.iapFeed, squaredPerpDeployment.ibpFeed);

    (int staticInterestRate, int fundingRateCap, uint fundingConvergencePeriod) = Config.getPerpParams();
    squaredPerpDeployment.perp.setRateBounds(fundingRateCap);
    squaredPerpDeployment.perp.setStaticInterestRate(staticInterestRate);
    if (fundingConvergencePeriod != 8e18) {
      squaredPerpDeployment.perp.setConvergencePeriod(fundingConvergencePeriod);
    }

    squaredPerpDeployment.viewer = new BasePortfolioViewer(deployment.subAccounts, deployment.cash);
    squaredPerpDeployment.manager =
      new SquaredPerpManager(deployment.subAccounts, deployment.cash, deployment.auction, squaredPerpDeployment.viewer);
  }

  function _setPermissionsAndRisk(
    string memory marketName,
    Deployment memory deployment,
    SquaredPerpDeployment memory squaredPerpDeployment
  ) internal {
    (
      SquaredPerpManager.PerpRiskParams memory riskParams,
      uint perpCap,
      uint maxAccountSize,
      uint oiFeeRateBPS,
      uint minOIFee
    ) = Config.getSquaredPerpConfig(marketName);

    deployment.auction.setWhitelistManager(address(squaredPerpDeployment.manager), true);
    deployment.cash.setWhitelistManager(address(squaredPerpDeployment.manager), true);

    squaredPerpDeployment.perp.setWhitelistManager(address(squaredPerpDeployment.manager), true);
    squaredPerpDeployment.perp.setTotalPositionCap(IManager(address(squaredPerpDeployment.manager)), perpCap);

    squaredPerpDeployment.manager.setPerpRiskParams(squaredPerpDeployment.perp, riskParams);
    squaredPerpDeployment.manager.setMaxAccountSize(maxAccountSize);
    squaredPerpDeployment.manager.setMinOIFee(minOIFee);
    squaredPerpDeployment.manager.setWhitelistedCallee(address(squaredPerpDeployment.perpFeed), true);
    squaredPerpDeployment.manager.setWhitelistedCallee(address(squaredPerpDeployment.iapFeed), true);
    squaredPerpDeployment.manager.setWhitelistedCallee(address(squaredPerpDeployment.ibpFeed), true);
    squaredPerpDeployment.manager.setWhitelistedCallee(address(squaredPerpDeployment.spotFeed), true);

    squaredPerpDeployment.viewer.setOIFeeRateBPS(address(squaredPerpDeployment.perp), oiFeeRateBPS);
  }

  function _loadExistingSpotFeed(string memory marketName) internal view returns (ISpotFeed) {
    if (block.chainid == 8453 && keccak256(abi.encodePacked(marketName)) == keccak256(abi.encodePacked("NGN"))) {
      marketName = "CNGN";
    }

    string memory content = _readDeploymentFile(marketName);
    return ISpotFeed(vm.parseJsonAddress(content, ".spotFeed"));
  }

  function _getSquaredPerpSpotFeed(string memory marketName) internal returns (ISpotFeed) {
    if (block.chainid == 8453 && keccak256(abi.encodePacked(marketName)) == keccak256(abi.encodePacked("BTC"))) {
      return ISpotFeed(address(new ChainlinkSpotFeed(IAggregatorV3(BASE_BTC_USD_CHAINLINK), CHAINLINK_SPOT_HEARTBEAT)));
    }

    if (block.chainid == 8453 && keccak256(abi.encodePacked(marketName)) == keccak256(abi.encodePacked("NGN"))) {
      return ISpotFeed(
        address(
          new InvertedChainlinkSpotFeed(
            IAggregatorV3(BASE_NGN_USD_CHAINLINK), IAggregatorV3(address(0)), CHAINLINK_SPOT_HEARTBEAT, L2_SEQUENCER_GRACE_PERIOD
          )
        )
      );
    }

    return _loadExistingSpotFeed(marketName);
  }

  function _writeSquaredPerpArtifact(string memory marketName, SquaredPerpDeployment memory squaredPerpDeployment) internal {
    (
      SquaredPerpManager.PerpRiskParams memory riskParams,
      uint perpCap,
      uint maxAccountSize,
      uint oiFeeRateBPS,
      uint minOIFee
    ) = Config.getSquaredPerpConfig(marketName);

    string memory objKey = "squared-market";
    string memory managerObj = "squared-market.managerConfig";
    string memory riskObj = "squared-market.riskConfig";

    vm.serializeAddress(objKey, "spotFeed", address(squaredPerpDeployment.spotFeed));
    vm.serializeAddress(objKey, "perp", address(squaredPerpDeployment.perp));
    vm.serializeAddress(objKey, "perpFeed", address(squaredPerpDeployment.perpFeed));
    vm.serializeAddress(objKey, "iapFeed", address(squaredPerpDeployment.iapFeed));
    vm.serializeAddress(objKey, "ibpFeed", address(squaredPerpDeployment.ibpFeed));
    vm.serializeAddress(objKey, "manager", address(squaredPerpDeployment.manager));
    vm.serializeAddress(objKey, "viewer", address(squaredPerpDeployment.viewer));

    vm.serializeUint(managerObj, "maxAccountSize", maxAccountSize);
    vm.serializeUint(managerObj, "minOIFee", minOIFee);
    vm.serializeUint(managerObj, "oiFeeRateBPS", oiFeeRateBPS);
    string memory managerJson = vm.serializeUint(managerObj, "perpCap", perpCap);
    vm.serializeString(objKey, "managerConfig", managerJson);

    vm.serializeBool(riskObj, "isWhitelisted", riskParams.isWhitelisted);
    vm.serializeBool(riskObj, "isSquared", riskParams.isSquared);
    vm.serializeUint(riskObj, "initialMarginRatio", riskParams.initialMarginRatio);
    vm.serializeUint(riskObj, "maintenanceMarginRatio", riskParams.maintenanceMarginRatio);
    vm.serializeUint(riskObj, "initialMaxLeverage", riskParams.initialMaxLeverage);
    vm.serializeUint(riskObj, "maintenanceMaxLeverage", riskParams.maintenanceMaxLeverage);
    vm.serializeUint(riskObj, "initialSpotShockUp", riskParams.initialSpotShockUp);
    vm.serializeUint(riskObj, "initialSpotShockDown", riskParams.initialSpotShockDown);
    vm.serializeUint(riskObj, "maintenanceSpotShockUp", riskParams.maintenanceSpotShockUp);
    string memory riskJson = vm.serializeUint(riskObj, "maintenanceSpotShockDown", riskParams.maintenanceSpotShockDown);
    string memory finalJson = vm.serializeString(objKey, "riskConfig", riskJson);

    _writeToDeployments(string.concat(marketName, "_SQUARED"), finalJson);
  }
}
