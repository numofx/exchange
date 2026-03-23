// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import "lyra-utils/encoding/OptionEncoding.sol";
import "lyra-utils/arrays/UnorderedMemoryArray.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {ISRMPortfolioViewer} from "../interfaces/ISRMPortfolioViewer.sol";
import {ICashAsset} from "../interfaces/ICashAsset.sol";
import {IPerpAsset} from "../interfaces/IPerpAsset.sol";
import {IOptionAsset} from "../interfaces/IOptionAsset.sol";
import {IDatedFutureAsset} from "../interfaces/IDatedFutureAsset.sol";
import {IDeliverableFXFutureAsset} from "../interfaces/IDeliverableFXFutureAsset.sol";
import {IStandardManager} from "../interfaces/IStandardManager.sol";
import {BasePortfolioViewer} from "./BasePortfolioViewer.sol";

/**
 * @title SRMPortfolioViewer
 * @author Lyra
 * @notice Read only contract that helps with converting portfolio and balances
 */
contract SRMPortfolioViewer is BasePortfolioViewer, ISRMPortfolioViewer {
  using SafeCast for uint;
  using SafeCast for int;
  using UnorderedMemoryArray for uint[];

  ///@dev Standard manager contract where we read the assetDetails from
  IStandardManager public standardManager;

  constructor(ISubAccounts _subAccounts, ICashAsset _cash) BasePortfolioViewer(_subAccounts, _cash) {}

  /**
   * @dev update the standard manager contract
   */
  function setStandardManager(IStandardManager srm) external onlyOwner {
    standardManager = srm;
  }

  /**
   * @dev get the portfolio struct for standard risk manager
   */
  function getSRMPortfolio(uint accountId) external view returns (IStandardManager.StandardManagerPortfolio memory) {
    return arrangeSRMPortfolio(subAccounts.getAccountBalances(accountId));
  }

  /**
   * @notice Arrange balances into standard manager portfolio struct
   * @param assets Array of balances for given asset and subId.
   */
  function arrangeSRMPortfolio(ISubAccounts.AssetBalance[] memory assets)
    public
    view
    returns (IStandardManager.StandardManagerPortfolio memory)
  {
    (uint marketCount, int cashBalance, uint marketBitMap) = _countMarketsAndParseCash(assets);

    IStandardManager.StandardManagerPortfolio memory portfolio = IStandardManager.StandardManagerPortfolio({
      cash: cashBalance,
      marketHoldings: new IStandardManager.MarketHolding[](marketCount)
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
        IStandardManager.MarketHolding memory holding,
        uint[] memory seenExpires,
        uint[] memory expiryOptionCounts,
        uint numExpires,
        uint numFutures,
        uint numDeliverableFutures
      ) = _scanMarketAssets(assets, marketId);

      holding.marketId = marketId;
      holding.expiryHoldings = new IStandardManager.ExpiryHolding[](numExpires);
      holding.futurePositions = new IStandardManager.FuturePosition[](numFutures);
      holding.deliverableFuturePositions =
        new IStandardManager.DeliverableFuturePosition[](numDeliverableFutures);

      for (uint j; j < numExpires; j++) {
        holding.expiryHoldings[j].expiry = seenExpires[j];
        holding.expiryHoldings[j].options = new IStandardManager.Option[](expiryOptionCounts[j]);
      }

      portfolio.marketHoldings[i] = _populateMarketDerivatives(holding, assets, marketId, seenExpires, numExpires);
    }
    return portfolio;
  }

  function _scanMarketAssets(ISubAccounts.AssetBalance[] memory assets, uint marketId)
    internal
    view
    returns (
      IStandardManager.MarketHolding memory holding,
      uint[] memory seenExpires,
      uint[] memory expiryOptionCounts,
      uint numExpires,
      uint numFutures,
      uint numDeliverableFutures
    )
  {
    seenExpires = new uint[](assets.length);
    expiryOptionCounts = new uint[](assets.length);

    for (uint j; j < assets.length; j++) {
      ISubAccounts.AssetBalance memory currentAsset = assets[j];
      if (currentAsset.asset == cashAsset) continue;

      IStandardManager.AssetDetail memory detail = standardManager.assetDetails(currentAsset.asset);
      if (detail.marketId != marketId) continue;

      if (detail.assetType == IStandardManager.AssetType.Perpetual) {
        holding.perp = IPerpAsset(address(currentAsset.asset));
        holding.perpPosition = currentAsset.balance;
        holding.depegPenaltyPos += SignedMath.abs(currentAsset.balance);
      } else if (detail.assetType == IStandardManager.AssetType.DatedFuture) {
        holding.datedFuture = IDatedFutureAsset(address(currentAsset.asset));
        numFutures++;
        holding.depegPenaltyPos += SignedMath.abs(currentAsset.balance);
      } else if (detail.assetType == IStandardManager.AssetType.DeliverableFXFuture) {
        holding.deliverableFuture = IDeliverableFXFutureAsset(address(currentAsset.asset));
        numDeliverableFutures++;
        holding.depegPenaltyPos += SignedMath.abs(currentAsset.balance);
      } else if (detail.assetType == IStandardManager.AssetType.Option) {
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
    IStandardManager.MarketHolding memory holding,
    ISubAccounts.AssetBalance[] memory assets,
    uint marketId,
    uint[] memory seenExpires,
    uint numExpires
  ) internal view returns (IStandardManager.MarketHolding memory) {
    uint nextFutureIndex = 0;
    uint nextDeliverableFutureIndex = 0;

    for (uint j; j < assets.length; j++) {
      ISubAccounts.AssetBalance memory currentAsset = assets[j];
      if (currentAsset.asset == cashAsset) continue;

      IStandardManager.AssetDetail memory detail = standardManager.assetDetails(currentAsset.asset);
      if (detail.marketId != marketId) continue;

      if (detail.assetType == IStandardManager.AssetType.Option) {
        holding = _appendOptionPosition(holding, currentAsset, seenExpires, numExpires);
      } else if (detail.assetType == IStandardManager.AssetType.DatedFuture) {
        holding.futurePositions[nextFutureIndex] =
          IStandardManager.FuturePosition({subId: currentAsset.subId, balance: currentAsset.balance});
        nextFutureIndex++;
      } else if (detail.assetType == IStandardManager.AssetType.DeliverableFXFuture) {
        holding.deliverableFuturePositions[nextDeliverableFutureIndex] =
          IStandardManager.DeliverableFuturePosition({subId: currentAsset.subId, balance: currentAsset.balance});
        nextDeliverableFutureIndex++;
      }
    }

    return holding;
  }

  function _appendOptionPosition(
    IStandardManager.MarketHolding memory holding,
    ISubAccounts.AssetBalance memory currentAsset,
    uint[] memory seenExpires,
    uint numExpires
  ) internal pure returns (IStandardManager.MarketHolding memory) {
    (uint expiry, uint strike, bool isCall) = OptionEncoding.fromSubId(uint96(currentAsset.subId));
    uint expiryIndex = seenExpires.findInArray(expiry, numExpires).toUint256();
    IStandardManager.ExpiryHolding memory expiryHolding = holding.expiryHoldings[expiryIndex];
    uint nextIndex = expiryHolding.numOptions;
    expiryHolding.options[nextIndex] = IStandardManager.Option({strike: strike, isCall: isCall, balance: currentAsset.balance});
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
      IStandardManager.AssetDetail memory detail = standardManager.assetDetails(userBalances[i].asset);
      uint marketBit = 1 << detail.marketId;
      if (trackedMarketBitMap & marketBit == 0) {
        marketCount++;
        trackedMarketBitMap |= marketBit;
      }
    }
  }
}
