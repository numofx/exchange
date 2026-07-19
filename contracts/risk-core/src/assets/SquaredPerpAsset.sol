// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/utils/math/SafeCast.sol";
import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";

import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {PerpAsset} from "./PerpAsset.sol";

/**
 * @title SquaredPerpAsset
 * @author Lyra
 * @dev Perp variant that transforms spot and perp prices into squared prices while
 *      retaining the existing perp accounting, funding, and settlement flow.
 *      Prices are normalized back to 18 decimals via DecimalMath.
 */
contract SquaredPerpAsset is PerpAsset {
  using SafeCast for uint;
  using DecimalMath for uint;
  using SignedDecimalMath for int;

  constructor(ISubAccounts _subAccounts) PerpAsset(_subAccounts) {}

  function getIndexPrice() external view override returns (uint, uint) {
    if (isDisabled) {
      return (0, 1e18);
    }

    (uint spotPrice, uint confidence) = spotFeed.getSpot();
    return (_squarePrice(spotPrice), confidence);
  }

  function getPerpPrice() external view override returns (uint, uint) {
    if (isDisabled) {
      return (uint(frozenPerpPrice), 1e18);
    }

    (uint perpPrice, uint confidence) = perpFeed.getResult();
    return (_squarePrice(perpPrice), confidence);
  }

  function getImpactPrices() external view override returns (uint bid, uint ask) {
    (uint impactBidPrice, uint bidConfidence) = impactBidPriceFeed.getResult();
    (uint impactAskPrice, uint askConfidence) = impactAskPriceFeed.getResult();

    bid = _squarePrice(impactBidPrice);
    ask = _squarePrice(impactAskPrice);

    bidConfidence;
    askConfidence;
  }

  function _getPremium(int indexPrice) internal view override returns (int premium) {
    (uint impactAskPrice,) = impactAskPriceFeed.getResult();
    (uint impactBidPrice,) = impactBidPriceFeed.getResult();

    uint squaredAskPrice = _squarePrice(impactAskPrice);
    uint squaredBidPrice = _squarePrice(impactBidPrice);

    if (squaredAskPrice < squaredBidPrice) revert PA_InvalidImpactPrices();

    int bidDiff = squaredBidPrice.toInt256() - indexPrice;
    if (bidDiff < 0) bidDiff = 0;

    int askDiff = indexPrice - squaredAskPrice.toInt256();
    if (askDiff < 0) askDiff = 0;

    premium = (bidDiff - askDiff).divideDecimal(indexPrice);
  }

  function _getIndexPrice() internal view override returns (int) {
    if (isDisabled) {
      return 0;
    }

    (uint spotPrice,) = spotFeed.getSpot();
    return _squarePrice(spotPrice).toInt256();
  }

  function _getPerpPrice() internal view override returns (int) {
    if (isDisabled) {
      return frozenPerpPrice;
    }

    (uint perpPrice,) = perpFeed.getResult();
    return _squarePrice(perpPrice).toInt256();
  }

  function _squarePrice(uint price) internal pure returns (uint) {
    return price.multiplyDecimal(price);
  }
}
