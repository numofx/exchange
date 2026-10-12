// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "../../../../src/risk-managers/MarginEngine.sol";

contract MarginEnginePublic is MarginEngine {
  constructor(
    ISubAccounts subAccounts_,
    ICashAsset cashAsset_,
    IDutchAuction _dutchAuction,
    IMarginEnginePortfolioViewer _viewer
  ) MarginEngine(subAccounts_, cashAsset_, _dutchAuction, _viewer) {}

  function getMarginByBalances(ISubAccounts.AssetBalance[] memory balances, uint accountId)
    external
    view
    returns (int im, int mm, int mtm)
  {
    MarginEnginePortfolio memory portfolio =
      IMarginEnginePortfolioViewer(address(viewer)).arrangeMarginEnginePortfolio(balances);
    (im, mtm) = _getMarginAndMarkToMarket(accountId, portfolio, true);
    (mm,) = _getMarginAndMarkToMarket(accountId, portfolio, false);
  }
}
