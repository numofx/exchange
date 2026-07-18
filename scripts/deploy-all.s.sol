// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;


import {Matching} from "../src/Matching.sol";
import {DepositModule} from "../src/modules/DepositModule.sol";
import {TradeModule} from "../src/modules/TradeModule.sol";
import {TransferModule} from "../src/modules/TransferModule.sol";
import {LiquidateModule} from "../src/modules/LiquidateModule.sol";
import {RfqModule} from "../src/modules/RfqModule.sol";
import {WithdrawalModule} from "../src/modules/WithdrawalModule.sol";
import {SubAccountCreator} from "../src/periphery/SubAccountCreator.sol";
import {LyraSettlementUtils} from "../src/periphery/LyraSettlementUtils.sol";
import {LyraAuctionUtils} from "../src/periphery/LyraAuctionUtils.sol";
import {DutchAuction} from "v2-core/src/liquidation/DutchAuction.sol";
import {TSAShareHandler} from "../src/tokenizedSubaccounts/TSAShareHandler.sol";
import {AtomicSigningExecutor} from "../src/AtomicSigningExecutor.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {ICashAsset} from "v2-core/src/interfaces/ICashAsset.sol";

import "forge-std/console2.sol";
import {Deployment, NetworkConfig} from "./types.sol";
import {Utils} from "./utils.sol";


contract DeployAll is Utils {

  /// @dev main function
  function run() external {

    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    address deployer = vm.addr(deployerPrivateKey);
    console2.log("Start deploying matching contract and modules! deployer: ", deployer);

    // load configs
    NetworkConfig memory config = _loadConfig();

    // deploy core contracts
    _deployAllContracts(config);

    vm.stopBroadcast();
  }


  /// @dev deploy and initiate contracts
  function _deployAllContracts(NetworkConfig memory config) internal returns (Deployment memory deployment)  {
    uint defaultFeeRecipient = 1;

    deployment.matching = new Matching(ISubAccounts(config.subAccounts));

    ////
    // Modules

    deployment.deposit = new DepositModule(deployment.matching);
    deployment.trade = new TradeModule(deployment.matching, IAsset(config.cash), defaultFeeRecipient);
    deployment.transfer = new TransferModule(deployment.matching);
    deployment.withdrawal = new WithdrawalModule(deployment.matching);
    deployment.liquidate = new LiquidateModule(deployment.matching, DutchAuction(config.auction));
    deployment.rfq = new RfqModule(deployment.matching, ICashAsset(config.cash), defaultFeeRecipient);

    // whitelist modules
    deployment.matching.setAllowedModule(address(deployment.deposit), true);
    deployment.matching.setAllowedModule(address(deployment.trade), true);
    deployment.matching.setAllowedModule(address(deployment.transfer), true);
    deployment.matching.setAllowedModule(address(deployment.withdrawal), true);
    deployment.matching.setAllowedModule(address(deployment.liquidate), true);
    deployment.matching.setAllowedModule(address(deployment.rfq), true);

    /////
    // helpers

    deployment.settlementUtil = new LyraSettlementUtils();
    deployment.subAccountCreator = new SubAccountCreator(ISubAccounts(config.subAccounts), deployment.matching);
    deployment.auctionUtil = new LyraAuctionUtils(
      ISubAccounts(config.subAccounts), DutchAuction(config.auction), config.srm
    );
    deployment.tsaShareHandler = new TSAShareHandler();
    deployment.atomicSigningExecutor = new AtomicSigningExecutor(deployment.matching);

    // whitelist helpers
    // Legacy Lyra keeper — skipped on clean deployments (e.g. mainnet) via SKIP_LEGACY_EXECUTOR=true.
    if (!vm.envOr("SKIP_LEGACY_EXECUTOR", false)) {
      deployment.matching.setTradeExecutor(0xf00A105BC009eA3a250024cbe1DCd0509c71C52b, true);
    }
    deployment.matching.setTradeExecutor(address(deployment.atomicSigningExecutor), true);

    // Authorize the execution-service relayer (the EOA whose key is PRIVATE_KEY on that service),
    // otherwise verifyAndMatch reverts for it. Optional; set RELAYER_EXECUTOR to enable.
    address relayer = vm.envOr("RELAYER_EXECUTOR", address(0));
    if (relayer != address(0)) {
      deployment.matching.setTradeExecutor(relayer, true);
    }

    // Register a deliverable FX (dated) future on the trade + rfq modules so VM-blended fills
    // price correctly (see DeliverableFXFutureAsset.handleAdjustment assetData path). Optional;
    // set DATED_FUTURE_ASSET to enable.
    address datedFuture = vm.envOr("DATED_FUTURE_ASSET", address(0));
    if (datedFuture != address(0)) {
      deployment.trade.setDatedFutureAsset(datedFuture, true);
      deployment.rfq.setDatedFutureAsset(datedFuture, true);
    }

    // write to output (off-chain) before ownership handoff
    __writeToDeploymentsJson(deployment);

    // Hand ownership to the MPC vault. Ownable2Step: this only sets pendingOwner — the vault
    // must acceptOwnership() on each contract to complete the transfer. Done last so all the
    // onlyOwner setup above executes as the deployer. Optional; set MATCHING_OWNER to enable.
    address newOwner = vm.envOr("MATCHING_OWNER", address(0));
    if (newOwner != address(0)) {
      deployment.matching.transferOwnership(newOwner);
      deployment.deposit.transferOwnership(newOwner);
      deployment.trade.transferOwnership(newOwner);
      deployment.transfer.transferOwnership(newOwner);
      deployment.withdrawal.transferOwnership(newOwner);
      deployment.liquidate.transferOwnership(newOwner);
      deployment.rfq.transferOwnership(newOwner);
      console2.log("Ownership transfer initiated; vault must acceptOwnership() on each:", newOwner);
    }
  }

 
  /**
   * @dev write to deployments/{network}/core.json
   */
  function __writeToDeploymentsJson(Deployment memory deployment) internal {

    string memory objKey = "matching-deployments";

    vm.serializeAddress(objKey, "matching", address(deployment.matching));
    vm.serializeAddress(objKey, "deposit", address(deployment.deposit));
    vm.serializeAddress(objKey, "trade", address(deployment.trade));
    vm.serializeAddress(objKey, "transfer", address(deployment.transfer));
    vm.serializeAddress(objKey, "withdrawal", address(deployment.withdrawal));
    vm.serializeAddress(objKey, "subAccountCreator", address(deployment.subAccountCreator));
    vm.serializeAddress(objKey, "settlementUtil", address(deployment.settlementUtil));
    vm.serializeAddress(objKey, "auctionUtil", address(deployment.auctionUtil));
    vm.serializeAddress(objKey, "liquidate", address(deployment.liquidate));
    vm.serializeAddress(objKey, "rfq", address(deployment.rfq));
    vm.serializeAddress(objKey, "tsaShareHandler", address(deployment.tsaShareHandler));
    vm.serializeAddress(objKey, "atomicSigningExecutor", address(deployment.atomicSigningExecutor));

    string memory finalObj = vm.serializeAddress(objKey, "withdrawal", address(deployment.withdrawal));

    // build path
    _writeToDeployments("matching", finalObj);
  }

}