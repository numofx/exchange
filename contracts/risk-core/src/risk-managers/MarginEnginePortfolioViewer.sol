// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import "lyra-utils/encoding/OptionEncoding.sol";
import "lyra-utils/arrays/UnorderedMemoryArray.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IMarginEnginePortfolioViewer} from "../interfaces/IMarginEnginePortfolioViewer.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IPerpAsset} from "../interfaces/IPerpAsset.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {BasePortfolioViewer} from "./BasePortfolioViewer.sol";
import {IPositionTracking, IManager} from "../interfaces/IPositionTracking.sol";

/**
 * @title MarginEnginePortfolioViewer
 * @notice A fork of SRMPortfolioViewer for MarginEngine: the dated-future type is the cNGN-settled FutureAsset.
 * @author Lyra
 * @notice Read only contract that helps with converting portfolio and balances
 */
contract MarginEnginePortfolioViewer is BasePortfolioViewer, IMarginEnginePortfolioViewer {
  using SafeCast for uint;
  using SafeCast for int;
  using UnorderedMemoryArray for uint[];

  ///@dev The MarginEngine whose assetDetails this reads
  IMarginEngine public marginEngine;

  constructor(ISubAccounts _subAccounts, ICashAsset _cash) BasePortfolioViewer(_subAccounts, _cash) {}

  /**
   * @dev update the MarginEngine contract
   */
  function setMarginEngine(IMarginEngine engine) external onlyOwner {
    marginEngine = engine;
  }

  /**
   * @dev The cap check, skipping an asset this trade did not touch. BasePortfolioViewer checks every asset an account
   *      holds, and an asset the trade never touched has no snapshot for it, which reads as a pre-trade position of 0:
   *      with a cap set below open interest, every deposit, withdrawal or spot trade by a holder then reverts
   *      BM_AssetCapExceeded. Skipped here, a cap below open interest means close-only and nothing more.
   */
  function _checkAssetCap(IManager manager, IPositionTracking asset, uint tradeId) internal view override {
    (bool touched,) = asset.totalPositionBeforeTrade(manager, tradeId);
    if (!touched) return;
    super._checkAssetCap(manager, asset, tradeId);
  }

  /**
   * @dev get the portfolio struct for standard risk manager
   */
  function getMarginEnginePortfolio(uint accountId) external view returns (IMarginEngine.MarginEnginePortfolio memory) {
    return arrangeMarginEnginePortfolio(subAccounts.getAccountBalances(accountId));
  }

  /**
   * @notice Arrange balances into standard manager portfolio struct
   * @param assets Array of balances for given asset and subId.
   */
  function arrangeMarginEnginePortfolio(ISubAccounts.AssetBalance[] memory assets)
    public
    view
    returns (IMarginEngine.MarginEnginePortfolio memory)
  {
    (uint marketCount, int cashBalance, uint marketBitMap) = _countMarketsAndParseCash(assets);

    IMarginEngine.MarginEnginePortfolio memory portfolio = IMarginEngine.MarginEnginePortfolio({
      cash: cashBalance, marketHoldings: new IMarginEngine.MarketHolding[](marketCount)
    });

    // for each market, need to count how many expires there are
    // and initiate a ExpiryHolding[] array in the corresponding marketHolding
    for (uint i; i < marketCount; i++) {
      uint marketId;
      for (uint8 id = 1; id < 255; id++) {
        uint masked = (1 << id);
        if (marketBitMap & masked == 0) continue;
        marketBitMap ^= masked;
        marketId = id;
        break;
      }
      (
        IMarginEngine.MarketHolding memory holding,
        uint[] memory seenExpires,
        uint[] memory expiryOptionCounts,
        uint numExpires,
        uint numFutures
      ) = _scanMarketAssets(assets, marketId);

      holding.marketId = marketId;
      holding.expiryHoldings = new IMarginEngine.ExpiryHolding[](numExpires);
      holding.futurePositions = new IMarginEngine.FuturePosition[](numFutures);

      for (uint j; j < numExpires; j++) {
        holding.expiryHoldings[j].expiry = seenExpires[j];
        holding.expiryHoldings[j].options = new IMarginEngine.Option[](expiryOptionCounts[j]);
      }

      portfolio.marketHoldings[i] = _populateMarketDerivatives(holding, assets, marketId, seenExpires, numExpires);
    }
    return portfolio;
  }

  function _scanMarketAssets(ISubAccounts.AssetBalance[] memory assets, uint marketId)
    internal
    view
    returns (
      IMarginEngine.MarketHolding memory holding,
      uint[] memory seenExpires,
      uint[] memory expiryOptionCounts,
      uint numExpires,
      uint numFutures
    )
  {
    seenExpires = new uint[](assets.length);
    expiryOptionCounts = new uint[](assets.length);

    for (uint j; j < assets.length; j++) {
      ISubAccounts.AssetBalance memory currentAsset = assets[j];
      if (currentAsset.asset == cashAsset) continue;

      IMarginEngine.AssetDetail memory detail = marginEngine.assetDetails(currentAsset.asset);
      if (detail.marketId != marketId) continue;

      if (detail.assetType == IMarginEngine.AssetType.Perpetual) {
        holding.perp = IPerpAsset(address(currentAsset.asset));
        holding.perpPosition = currentAsset.balance;
        holding.depegPenaltyPos += SignedMath.abs(currentAsset.balance);
      } else if (detail.assetType == IMarginEngine.AssetType.Future) {
        holding.future = IFutureAsset(address(currentAsset.asset));
        numFutures++;
        // not added to depegPenaltyPos, which is in base units and priced at spot: a futures balance is in contracts.
        // MarginEngine applies the depeg multiplier to the futures' own USDC notional (FutureVMLib.marketMargin).
      } else if (detail.assetType == IMarginEngine.AssetType.Option) {
        holding.option = IOptionAsset(address(currentAsset.asset));
        (uint expiry,,) = OptionEncoding.fromSubId(uint96(currentAsset.subId));
        uint expiryIndex;
        (numExpires, expiryIndex) = seenExpires.addUniqueToArray(expiry, numExpires);
        expiryOptionCounts[expiryIndex]++;
      } else {
        holding.basePosition = currentAsset.balance.toUint256();
      }
    }
  }

  function _populateMarketDerivatives(
    IMarginEngine.MarketHolding memory holding,
    ISubAccounts.AssetBalance[] memory assets,
    uint marketId,
    uint[] memory seenExpires,
    uint numExpires
  ) internal view returns (IMarginEngine.MarketHolding memory) {
    uint nextFutureIndex = 0;

    for (uint j; j < assets.length; j++) {
      ISubAccounts.AssetBalance memory currentAsset = assets[j];
      if (currentAsset.asset == cashAsset) continue;

      IMarginEngine.AssetDetail memory detail = marginEngine.assetDetails(currentAsset.asset);
      if (detail.marketId != marketId) continue;

      if (detail.assetType == IMarginEngine.AssetType.Option) {
        holding = _appendOptionPosition(holding, currentAsset, seenExpires, numExpires);
      } else if (detail.assetType == IMarginEngine.AssetType.Future) {
        holding.futurePositions[nextFutureIndex] =
          IMarginEngine.FuturePosition({subId: currentAsset.subId, balance: currentAsset.balance});
        nextFutureIndex++;
      }
    }

    return holding;
  }

  function _appendOptionPosition(
    IMarginEngine.MarketHolding memory holding,
    ISubAccounts.AssetBalance memory currentAsset,
    uint[] memory seenExpires,
    uint numExpires
  ) internal pure returns (IMarginEngine.MarketHolding memory) {
    (uint expiry, uint strike, bool isCall) = OptionEncoding.fromSubId(uint96(currentAsset.subId));
    uint expiryIndex = seenExpires.findInArray(expiry, numExpires).toUint256();
    IMarginEngine.ExpiryHolding memory expiryHolding = holding.expiryHoldings[expiryIndex];
    uint nextIndex = expiryHolding.numOptions;
    expiryHolding.options[nextIndex] =
      IMarginEngine.Option({strike: strike, isCall: isCall, balance: currentAsset.balance});
    expiryHolding.numOptions = nextIndex + 1;

    if (isCall) {
      expiryHolding.netCalls += currentAsset.balance;
    }
    if (currentAsset.balance < 0) {
      uint shortPos = (-currentAsset.balance).toUint256();
      holding.depegPenaltyPos += shortPos;
      expiryHolding.totalShortPositions += shortPos;
    }

    holding.expiryHoldings[expiryIndex] = expiryHolding;
    return holding;
  }

  /**
   * @dev Count how many market the user has
   */
  function _countMarketsAndParseCash(ISubAccounts.AssetBalance[] memory userBalances)
    internal
    view
    returns (uint marketCount, int cashBalance, uint trackedMarketBitMap)
  {
    ISubAccounts.AssetBalance memory currentAsset;

    // count how many unique markets there are
    for (uint i; i < userBalances.length; ++i) {
      currentAsset = userBalances[i];
      if (address(currentAsset.asset) == address(cashAsset)) {
        cashBalance = currentAsset.balance;
        continue;
      }

      // else, it must be perp or option for one of the registered assets

      // if marketId 1 is tracked, trackedMarketBitMap    = 0000..00010
      // if marketId 2 is tracked, trackedMarketBitMap    = 0000..00100
      // if both markets are tracked, trackedMarketBitMap = 0000..00110
      IMarginEngine.AssetDetail memory detail = marginEngine.assetDetails(userBalances[i].asset);
      uint marketBit = 1 << detail.marketId;
      if (trackedMarketBitMap & marketBit == 0) {
        marketCount++;
        trackedMarketBitMap |= marketBit;
      }
    }
  }
}
