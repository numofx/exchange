// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IMarginEngine} from "./IMarginEngine.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";

import {IBasePortfolioViewer} from "../interfaces/IBasePortfolioViewer.sol";

/**
 * @title IMarginEnginePortfolioViewer
 * @notice view function for MarginEngine
 * @author Lyra
 */
interface IMarginEnginePortfolioViewer is IBasePortfolioViewer {
  function getMarginEnginePortfolio(uint accountId) external view returns (IMarginEngine.MarginEnginePortfolio memory);

  function arrangeMarginEnginePortfolio(ISubAccounts.AssetBalance[] memory assets)
    external
    view
    returns (IMarginEngine.MarginEnginePortfolio memory);
}
