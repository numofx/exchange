// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IAsset} from "./IAsset.sol";
import {IPerpAsset} from "./IPerpAsset.sol";
import {IBaseManager} from "./IBaseManager.sol";
import {IOptionAsset} from "./IOptionAsset.sol";
import {IFutureAsset} from "./IFutureAsset.sol";
import {ISpotFeed} from "./ISpotFeed.sol";
import {IForwardFeed} from "./IForwardFeed.sol";
import {IVolFeed} from "./IVolFeed.sol";

/**
 * @title IMarginEngine
 * @notice A fork of IStandardManager: the dated-future type is the cNGN-settled FutureAsset, whose variation margin
 *         moves as the market's base asset (wrapped cNGN) through the engine's own pool account.
 */
interface IMarginEngine is IBaseManager {
  enum AssetType {
    NotSet,
    Option,
    Perpetual,
    Base,
    Future
  }

  struct AssetDetail {
    bool isWhitelisted;
    AssetType assetType;
    uint marketId;
  }

  /**
   * @dev a standard manager portfolio contains multiple marketHoldings assets, each marketHolding contains multiple derivative type
   */
  struct MarginEnginePortfolio {
    // @dev each marketHolding take care of 1 base asset, for example ETH and BTC.
    MarketHolding[] marketHoldings;
    int cash;
  }

  struct MarketHolding {
    uint marketId;
    /// base position: doesn't contribute to margin, but increase total portfolio mark to market
    uint basePosition;
    /// perp position detail
    IPerpAsset perp;
    int perpPosition;
    /// option position detail
    IOptionAsset option;
    ExpiryHolding[] expiryHoldings;
    /// cNGN-settled dated futures position detail
    IFutureAsset future;
    FuturePosition[] futurePositions;
    // sum of all short positions and abs(perps) for the market.
    // used to increase margin requirement if stable price depegs.
    uint depegPenaltyPos;
  }

  struct FuturePosition {
    uint subId;
    int balance;
  }

  /// @dev contains portfolio struct for single expiry assets
  struct ExpiryHolding {
    /// array of option hold in this expiry
    Option[] options;
    /// expiry timestamp
    uint expiry;
    /// sum of all call positions, used to determine if portfolio max loss is bounded
    int netCalls;
    /// temporary variable to count how many options is used
    uint numOptions;
    /// total short position size. should be positive
    uint totalShortPositions;
  }

  struct Option {
    uint strike;
    int balance;
    bool isCall;
  }

  /// @dev Struct for Perp Margin Requirements
  struct PerpMarginRequirements {
    /// @dev minimum amount of spot required as maintenance margin for each perp position
    uint mmPerpReq;
    /// @dev minimum amount of spot required as initial margin for each perp position
    uint imPerpReq;
  }

  /// @dev Struct for Option Margin Parameters
  struct OptionMarginParams {
    /// @dev Percentage of spot to add to initial margin if option is ITM. Decreases as option becomes more OTM.
    uint maxSpotReq;
    /// @dev Minimum amount of spot price to add as initial margin.
    uint minSpotReq;
    /// @dev Minimum amount of spot price to add as maintenance margin.
    uint mmCallSpotReq;
    /// @dev Minimum amount of spot to add for maintenance margin
    uint mmPutSpotReq;
    /// @dev Minimum amount of mtm to add for maintenance margin for puts
    uint MMPutMtMReq;
    /// @dev Scaler applied to forward by amount if max loss is unbounded, when calculating IM
    uint unpairedIMScale;
    /// @dev Scaler applied to forward by amount if max loss is unbounded, when calculating MM
    uint unpairedMMScale;
    /// @dev Scale the MM for a put as minimum of IM
    uint mmOffsetScale;
  }

  struct DepegParams {
    uint threshold;
    uint depegFactor;
  }

  struct OracleContingencyParams {
    uint perpThreshold;
    uint optionThreshold;
    uint baseThreshold;
    uint OCFactor;
  }

  struct BaseMarginParams {
    uint marginFactor;
    uint IMScale;
  }

  struct FutureMarginRequirements {
    uint mmReq;
    uint imReq;
  }

  function assetDetails(IAsset asset) external view returns (AssetDetail memory);

  function assetMap(uint marketId, AssetType assetType) external view returns (IAsset);

  function lastMarketId() external view returns (uint);

  function getMarketFeeds(uint marketId) external view returns (ISpotFeed, IForwardFeed, IVolFeed);

  ///////////////
  //   Errors  //
  ///////////////

  /// @dev Market is not created yet
  error SRM_MarketNotCreated();

  /// @dev Caller is not the Accounts contract
  error SRM_NotAccounts();

  /// @dev Not whitelist manager
  error SRM_NotWhitelistManager();

  /// @dev Not supported asset
  error SRM_UnsupportedAsset();

  error SRM_TooManyAssets();

  /// @dev Account is under water, need more cash
  error SRM_PortfolioBelowMargin();

  /// @dev Invalid Parameters for perp margin requirements
  error SRM_InvalidPerpMarginParams();

  error SRM_InvalidOptionMarginParams();

  /// @dev Forward Price for an asset is 0
  error SRM_NoForwardPrice();

  /// @dev Invalid depeg parameters
  error SRM_InvalidDepegParams();

  /// @dev Invalid Oracle contingency params
  error SRM_InvalidOracleContingencyParams();

  /// @dev Invalid base asset margin discount factor
  error SRM_InvalidBaseDiscountFactor();

  /// @dev No negative cash
  error SRM_NoNegativeCash();

  /// @dev closeOutExpired before the contract's settlement price is fixed
  error ME_NotSettled();

  /// @dev The asset is not a whitelisted cNGN-settled future
  error ME_NotFuture();

  ///////////////////
  //    Events     //
  ///////////////////

  event MarketCreated(uint marketId, string marketName);

  event AssetWhitelisted(address asset, uint marketId, AssetType assetType);

  event OraclesSet(uint marketId, address spotOracle, address forwardOracle, address volFeed);

  event PerpMarginRequirementsSet(uint marketId, uint perpMMRequirement, uint perpIMRequirement);

  event OptionMarginParamsSet(
    uint marketId,
    uint maxSpotReq,
    uint minSpotReq,
    uint mmCallSpotReq,
    uint mmPutSpotReq,
    uint MMPutMtMReq,
    uint unpairedIMScale,
    uint unpairedMMScale,
    uint mmOffsetScale
  );

  event BaseMarginParamsSet(uint marketId, uint baseAssetMarginFactor, uint baseAssetIMScale);

  event FutureMarginRequirementsSet(uint marketId, uint futureMMRequirement, uint futureIMRequirement);

  event DepegParametersSet(uint threshold, uint depegFactor);

  event OracleContingencySet(uint prepThreshold, uint optionThreshold, uint baseThreshold, uint OCFactor);

  event StableFeedUpdated(address stableFeed);

  event BorrowingEnabled(bool borrowingEnabled);

  /// @dev VM realised for an account: cngnDelta > 0 is paid to it. cngnMoved is what moved as the base asset, cashMoved
  ///      the remainder in cash.
  event VMSettled(uint indexed accountId, uint96 indexed subId, int cngnDelta, uint cngnMoved, uint cashMoved);

  event PositionClosedOut(uint indexed accountId, uint96 indexed subId, int position);
}
