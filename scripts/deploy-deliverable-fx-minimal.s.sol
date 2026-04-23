// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {Utils} from "./utils.sol";
import {Config} from "./config-mainnet.sol";

import {IAsset} from "../src/interfaces/IAsset.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {IDeliverableFXFutureAsset} from "../src/interfaces/IDeliverableFXFutureAsset.sol";

import {SubAccounts} from "../src/SubAccounts.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {InterestRateModel} from "../src/assets/InterestRateModel.sol";
import {SecurityModule} from "../src/SecurityModule.sol";
import {DutchAuction} from "../src/liquidation/DutchAuction.sol";
import {WrappedERC20Asset} from "../src/assets/WrappedERC20Asset.sol";
import {LyraERC20} from "../src/l2/LyraERC20.sol";
import {LyraSpotFeed} from "../src/feeds/LyraSpotFeed.sol";
import {BasePortfolioViewer} from "../src/risk-managers/BasePortfolioViewer.sol";
import {DeliverableFXManager} from "../src/risk-managers/DeliverableFXManager.sol";
import {DeliverableFXFutureAsset} from "../src/assets/DeliverableFXFutureAsset.sol";

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {ICashAsset} from "../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IBasePortfolioViewer} from "../src/interfaces/IBasePortfolioViewer.sol";

contract BootstrapManager is IManager {
  function handleAdjustment(uint, uint, address, ISubAccounts.AssetDelta[] memory, bytes memory) external pure {}
}

contract DeployDeliverableFXMinimal is Utils {
  string internal constant FX_ARTIFACT_NAME = "CNGN_APR30_2026_FUTURE";

  uint64 internal constant EXPIRY = 1777507200;
  uint64 internal constant LAST_TRADE_TIME = 1777420800;
  uint internal constant CONTRACT_SIZE_BASE = 10_000e18;
  uint internal constant MIN_TRADE_INCREMENT = 0.001e18;
  uint internal constant TICK_SIZE = 1e18;
  uint internal constant INITIAL_MARK_PRICE = 1500e18;
  uint internal constant POSITION_CAP = 1e36;
  uint internal constant NORMAL_IM = 0.10e18;
  uint internal constant NORMAL_MM = 0.075e18;

  struct DeployState {
    address deployer;
    SubAccounts subAccounts;
    CashAsset cash;
    SecurityModule securityModule;
    DutchAuction auction;
    WrappedERC20Asset wrappedUsdcDeliverable;
    WrappedERC20Asset wrappedCngn;
    ISpotFeed cngnSpotFeed;
    address cngnUnderlying;
    BasePortfolioViewer viewer;
    DeliverableFXManager manager;
    DeliverableFXFutureAsset future;
    uint96 subId;
  }

  function run() external {
    DeployState memory s;
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    s.deployer = vm.addr(deployerPrivateKey);
    if (LAST_TRADE_TIME >= EXPIRY) revert("invalid future schedule");

    string memory shared = _readDeploymentFile("shared");
    address usdc = vm.parseJsonAddress(shared, ".usdc");
    if (usdc == address(0)) revert("shared.usdc missing");

    (s.subAccounts, s.cash, s.securityModule, s.auction) = _deployMinimalCore(usdc);

    (
      s.wrappedUsdcDeliverable,
      s.wrappedCngn,
      s.cngnSpotFeed,
      s.cngnUnderlying
    ) = _deployDeliverableAssets(s.subAccounts, s.deployer);

    (s.viewer, s.manager, s.future, s.subId) =
      _deployDeliverableStack(
        s.subAccounts, s.cash, s.auction, s.wrappedUsdcDeliverable, s.wrappedCngn, s.cngnSpotFeed
      );

    _writeCoreArtifact(s.subAccounts, s.cash, s.securityModule, s.auction);
    _writeWrappedUSDCArtifact(s.wrappedUsdcDeliverable, usdc);
    _writeWrappedCNGNArtifact(s.wrappedCngn, s.cngnSpotFeed, s.cngnUnderlying);
    _writeDeliverableFXArtifact(
      s.manager, s.viewer, s.future, s.subId, s.wrappedUsdcDeliverable, s.wrappedCngn, s.cngnSpotFeed
    );

    console2.log("Deployer:", s.deployer);
    console2.log("Minimal core deployed");
    console2.log("Wrapped USDC deliverable:", address(s.wrappedUsdcDeliverable));
    console2.log("Wrapped CNGN:", address(s.wrappedCngn));
    console2.log("CNGN spot feed:", address(s.cngnSpotFeed));
    console2.log("Deliverable FX manager:", address(s.manager));
    console2.log("Deliverable FX viewer:", address(s.viewer));
    console2.log("Deliverable FX future:", address(s.future));
    console2.log("Series subId:", uint(s.subId));
    console2.log("CNGN_APR30_2026_FUTURE_ASSET_ADDRESS=%s", address(s.future));
    console2.log("CNGN_APR30_2026_FUTURE_SUB_ID=%s", vm.toString(uint(s.subId)));

    vm.stopBroadcast();
  }

  function _deployMinimalCore(address usdc)
    internal
    returns (SubAccounts subAccounts, CashAsset cash, SecurityModule securityModule, DutchAuction auction)
  {
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    (uint minRate, uint rateMultiplier, uint highRateMultiplier, uint optimalUtil) = Config.getDefaultInterestRateModel();
    InterestRateModel rateModel = new InterestRateModel(minRate, rateMultiplier, highRateMultiplier, optimalUtil);
    cash = new CashAsset(subAccounts, IERC20Metadata(usdc), rateModel);

    BootstrapManager bootstrapManager = new BootstrapManager();
    securityModule = new SecurityModule(subAccounts, ICashAsset(address(cash)), IManager(address(bootstrapManager)));
    auction = new DutchAuction(subAccounts, securityModule, ICashAsset(address(cash)));

    cash.setLiquidationModule(IDutchAuction(address(auction)));
    cash.setSmFeeRecipient(securityModule.accountId());
    cash.setSmFee(Config.CASH_SM_FEE);
    auction.setSMAccount(securityModule.accountId());
    auction.setAuctionParams(Config.getDefaultAuctionParam());
    securityModule.setWhitelistModule(address(auction), true);
  }

  function _deployDeliverableAssets(SubAccounts subAccounts, address deployer)
    internal
    returns (
      WrappedERC20Asset wrappedUsdcDeliverable,
      WrappedERC20Asset wrappedCngn,
      ISpotFeed cngnSpotFeed,
      address cngnUnderlying
    )
  {
    address usdc = vm.parseJsonAddress(_readDeploymentFile("shared"), ".usdc");

    address usdcDeliverableExisting = vm.envOr("WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS", address(0));
    if (usdcDeliverableExisting == address(0)) {
      wrappedUsdcDeliverable = new WrappedERC20Asset(subAccounts, IERC20Metadata(usdc));
    } else {
      wrappedUsdcDeliverable = WrappedERC20Asset(usdcDeliverableExisting);
    }

    cngnUnderlying = vm.envOr("CNGN_TOKEN_ADDRESS", address(0));
    if (cngnUnderlying == address(0)) {
      cngnUnderlying = address(new LyraERC20("cNGN", "cNGN", 18));
    }
    wrappedCngn = new WrappedERC20Asset(subAccounts, IERC20Metadata(cngnUnderlying));

    address cngnSpotFeedExisting = vm.envOr("CNGN_SPOT_FEED_ADDRESS", address(0));
    if (cngnSpotFeedExisting == address(0)) {
      LyraSpotFeed spotFeed = new LyraSpotFeed();
      spotFeed.setHeartbeat(Config.SPOT_HEARTBEAT);
      spotFeed.addSigner(deployer, true);
      spotFeed.setRequiredSigners(1);
      cngnSpotFeed = spotFeed;
    } else {
      cngnSpotFeed = ISpotFeed(cngnSpotFeedExisting);
    }
  }

  function _deployDeliverableStack(
    SubAccounts subAccounts,
    CashAsset cash,
    DutchAuction auction,
    WrappedERC20Asset wrappedUsdcDeliverable,
    WrappedERC20Asset wrappedCngn,
    ISpotFeed cngnSpotFeed
  ) internal returns (BasePortfolioViewer viewer, DeliverableFXManager manager, DeliverableFXFutureAsset future, uint96 subId) {
    viewer = new BasePortfolioViewer(subAccounts, cash);
    manager = new DeliverableFXManager(
      subAccounts, ICashAsset(address(cash)), IDutchAuction(address(auction)), IBasePortfolioViewer(address(viewer))
    );
    future = new DeliverableFXFutureAsset(subAccounts);

    auction.setWhitelistManager(address(manager), true);
    cash.setWhitelistManager(address(manager), true);

    wrappedUsdcDeliverable.setWhitelistManager(address(manager), true);
    wrappedCngn.setWhitelistManager(address(manager), true);
    future.setWhitelistManager(address(manager), true);

    wrappedUsdcDeliverable.setTotalPositionCap(IManager(address(manager)), POSITION_CAP);
    wrappedCngn.setTotalPositionCap(IManager(address(manager)), POSITION_CAP);
    future.setTotalPositionCap(IManager(address(manager)), POSITION_CAP);

    manager.setProduct(
      IDeliverableFXFutureAsset(address(future)),
      IAsset(address(wrappedUsdcDeliverable)),
      IAsset(address(wrappedCngn)),
      cngnSpotFeed
    );
    manager.setMarginParams(NORMAL_IM, NORMAL_MM);

    subId = future.createSeries(
      EXPIRY,
      LAST_TRADE_TIME,
      address(wrappedUsdcDeliverable),
      address(wrappedCngn),
      uint128(CONTRACT_SIZE_BASE),
      uint128(MIN_TRADE_INCREMENT),
      uint128(TICK_SIZE),
      INITIAL_MARK_PRICE
    );
  }

  function _writeCoreArtifact(
    SubAccounts subAccounts,
    CashAsset cash,
    SecurityModule securityModule,
    DutchAuction auction
  ) internal {
    string memory objKey = "core-deployments";

    vm.serializeAddress(objKey, "subAccounts", address(subAccounts));
    vm.serializeAddress(objKey, "cash", address(cash));
    vm.serializeAddress(objKey, "rateModel", address(0));
    vm.serializeAddress(objKey, "securityModule", address(securityModule));
    vm.serializeAddress(objKey, "auction", address(auction));
    vm.serializeAddress(objKey, "srm", address(0));
    vm.serializeAddress(objKey, "srmViewer", address(0));
    vm.serializeAddress(objKey, "dataSubmitter", address(0));
    vm.serializeAddress(objKey, "optionSettlementHelper", address(0));
    vm.serializeAddress(objKey, "perpSettlementHelper", address(0));
    string memory finalObj = vm.serializeAddress(objKey, "stableFeed", address(0));

    _writeToDeployments("core", finalObj);
  }

  function _writeWrappedUSDCArtifact(WrappedERC20Asset wrappedUsdcDeliverable, address usdc) internal {
    string memory objKey = "wrapped-usdc-deliverable";
    vm.serializeAddress(objKey, "base", address(wrappedUsdcDeliverable));
    vm.serializeAddress(objKey, "wrappedAsset", usdc);
    vm.serializeAddress(objKey, "WRAPPED_USDC_DELIVERABLE_ASSET_ADDRESS", address(wrappedUsdcDeliverable));
    vm.serializeString(objKey, "marketName", "WRAPPED_USDC_DELIVERABLE");
    string memory finalObj = vm.serializeString(objKey, "symbol", "WRAPPED_USDC_DELIVERABLE");
    _writeToDeployments("WRAPPED_USDC_DELIVERABLE", finalObj);
  }

  function _writeWrappedCNGNArtifact(WrappedERC20Asset wrappedCngn, ISpotFeed cngnSpotFeed, address cngnUnderlying)
    internal
  {
    string memory objKey = "wrapped-cngn";
    vm.serializeAddress(objKey, "base", address(wrappedCngn));
    vm.serializeAddress(objKey, "spotFeed", address(cngnSpotFeed));
    vm.serializeAddress(objKey, "wrappedAsset", cngnUnderlying);
    string memory finalObj = vm.serializeString(objKey, "symbol", "CNGN");
    _writeToDeployments("CNGN", finalObj);
  }

  function _writeDeliverableFXArtifact(
    DeliverableFXManager manager,
    BasePortfolioViewer viewer,
    DeliverableFXFutureAsset future,
    uint96 subId,
    WrappedERC20Asset wrappedUsdcDeliverable,
    WrappedERC20Asset wrappedCngn,
    ISpotFeed cngnSpotFeed
  ) internal {
    string memory objKey = "deliverable-fx-future";

    vm.serializeAddress(objKey, "manager", address(manager));
    vm.serializeAddress(objKey, "viewer", address(viewer));
    vm.serializeAddress(objKey, "future", address(future));
    vm.serializeString(objKey, "symbol", "USDC/cNGN APR-30-2026");
    vm.serializeString(objKey, "subId", vm.toString(uint(subId)));
    vm.serializeUint(objKey, "expiry", EXPIRY);
    vm.serializeUint(objKey, "lastTradeTime", LAST_TRADE_TIME);
    vm.serializeAddress(objKey, "baseAsset", address(wrappedUsdcDeliverable));
    vm.serializeAddress(objKey, "quoteAsset", address(wrappedCngn));
    vm.serializeAddress(objKey, "spotFeed", address(cngnSpotFeed));
    vm.serializeString(objKey, "contractSizeBase", vm.toString(CONTRACT_SIZE_BASE));
    vm.serializeString(objKey, "minTradeIncrement", vm.toString(MIN_TRADE_INCREMENT));
    vm.serializeString(objKey, "tickSize", vm.toString(TICK_SIZE));
    vm.serializeString(objKey, "initialMarkPrice", vm.toString(INITIAL_MARK_PRICE));
    vm.serializeString(objKey, "normalIM", vm.toString(NORMAL_IM));
    vm.serializeString(objKey, "normalMM", vm.toString(NORMAL_MM));
    vm.serializeAddress(objKey, "CNGN_APR30_2026_FUTURE_ASSET_ADDRESS", address(future));
    string memory finalObj = vm.serializeString(objKey, "CNGN_APR30_2026_FUTURE_SUB_ID", vm.toString(uint(subId)));

    _writeToDeployments(FX_ARTIFACT_NAME, finalObj);
  }
}
