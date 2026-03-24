// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "openzeppelin/utils/math/SafeCast.sol";
import "openzeppelin/utils/math/SignedMath.sol";

import "lyra-utils/decimals/DecimalMath.sol";
import "lyra-utils/decimals/SignedDecimalMath.sol";
import "lyra-utils/math/Black76.sol";

import {IStandardManager} from "../interfaces/IStandardManager.sol";

contract OptionMarginHelper {
  using SignedDecimalMath for int;
  using DecimalMath for uint;
  using SafeCast for uint;

  struct OptionComputationContext {
    uint expiry;
    uint spotPrice;
    uint forwardPrice;
    uint vol;
    bool isInitial;
  }

  struct IsolatedMarginInputs {
    IStandardManager.OptionMarginParams params;
    IStandardManager.Option optionPos;
    OptionComputationContext ctx;
  }

  struct ExpiryMarginInputs {
    IStandardManager.ExpiryHolding expiryHolding;
    IStandardManager.OptionMarginParams params;
    IStandardManager.OracleContingencyParams ocParams;
    uint spotPrice;
    uint forwardPrice;
    uint localMinConf;
    bool isInitial;
    uint[] vols;
  }

  function getIsolatedMargin(IsolatedMarginInputs calldata inputs) external view returns (int margin, int markToMarket) {
    return _getIsolatedMargin(inputs.params, inputs.optionPos, inputs.ctx);
  }

  function getExpiryMargin(ExpiryMarginInputs calldata inputs) external view returns (int expiryMargin, int expiryMtm) {
    if (inputs.vols.length != inputs.expiryHolding.options.length) revert IStandardManager.SRM_InvalidOptionMarginParams();

    int maxLossMargin = _getMaxLoss(inputs.expiryHolding, 0);
    int totalIsolatedMargin;

    for (uint j = 0; j < inputs.expiryHolding.options.length; ++j) {
      IStandardManager.Option calldata optionPos = inputs.expiryHolding.options[j];
      OptionComputationContext memory ctx = OptionComputationContext({
        expiry: inputs.expiryHolding.expiry,
        spotPrice: inputs.spotPrice,
        forwardPrice: inputs.forwardPrice,
        vol: inputs.vols[j],
        isInitial: inputs.isInitial
      });
      (int isolatedMargin, int markToMarket) = _getIsolatedMargin(inputs.params, optionPos, ctx);
      totalIsolatedMargin += isolatedMargin;
      expiryMtm += markToMarket;
      maxLossMargin = SignedMath.min(_getMaxLoss(inputs.expiryHolding, optionPos.strike), maxLossMargin);
    }

    if (inputs.expiryHolding.netCalls < 0) {
      uint unpairedScale = inputs.isInitial ? inputs.params.unpairedIMScale : inputs.params.unpairedMMScale;
      maxLossMargin += unpairedScale.multiplyDecimal(inputs.forwardPrice).toInt256().multiplyDecimal(
        inputs.expiryHolding.netCalls
      );
    }

    expiryMargin = SignedMath.max(totalIsolatedMargin, maxLossMargin);
    if (!inputs.isInitial) return (expiryMargin, expiryMtm);

    if (
      inputs.ocParams.optionThreshold != 0 && inputs.localMinConf < uint(inputs.ocParams.optionThreshold)
    ) {
      uint diff = 1e18 - inputs.localMinConf;
      uint penalty = diff.multiplyDecimal(inputs.ocParams.OCFactor).multiplyDecimal(inputs.spotPrice).multiplyDecimal(
        inputs.expiryHolding.totalShortPositions
      );
      expiryMargin -= penalty.toInt256();
    }
  }

  function getMaxLoss(IStandardManager.ExpiryHolding calldata expiryHolding, uint price) external pure returns (int payoff) {
    return _getMaxLoss(expiryHolding, price);
  }

  function _getMaxLoss(IStandardManager.ExpiryHolding calldata expiryHolding, uint price) internal pure returns (int payoff) {
    for (uint i = 0; i < expiryHolding.options.length; i++) {
      payoff += _getSettlementValue(
        expiryHolding.options[i].strike, expiryHolding.options[i].balance, price, expiryHolding.options[i].isCall
      );
    }

    return SignedMath.min(payoff, 0);
  }

  function _getIsolatedMargin(
    IStandardManager.OptionMarginParams calldata params,
    IStandardManager.Option calldata optionPos,
    OptionComputationContext memory ctx
  ) internal view returns (int margin, int markToMarket) {
    markToMarket =
      _getMarkToMarket(optionPos.balance, ctx.forwardPrice, optionPos.strike, ctx.expiry, ctx.vol, optionPos.isCall);

    if (optionPos.balance > 0) return (margin, markToMarket);

    if (optionPos.isCall) {
      margin =
        _getIsolatedMarginForCall(params, markToMarket, optionPos.strike, optionPos.balance, ctx.spotPrice, ctx.isInitial);
    } else {
      margin =
        _getIsolatedMarginForPut(params, markToMarket, optionPos.strike, optionPos.balance, ctx.spotPrice, ctx.isInitial);
    }
  }

  function _getIsolatedMarginForPut(
    IStandardManager.OptionMarginParams calldata params,
    int markToMarket,
    uint strike,
    int amount,
    uint spotPrice,
    bool isInitial
  ) internal pure returns (int) {
    int maintenanceMargin = SignedMath.min(
      params.mmPutSpotReq.multiplyDecimal(spotPrice).toInt256().multiplyDecimal(amount),
      params.MMPutMtMReq.toInt256().multiplyDecimal(markToMarket)
    ) + markToMarket;

    if (!isInitial) return maintenanceMargin;

    uint otmRatio;
    if (spotPrice > strike) {
      otmRatio = (spotPrice - strike).divideDecimal(spotPrice);
    }
    uint imMultiplier = params.minSpotReq;
    if (params.maxSpotReq > otmRatio && params.maxSpotReq - otmRatio > params.minSpotReq) {
      imMultiplier = params.maxSpotReq - otmRatio;
    }
    imMultiplier = imMultiplier.multiplyDecimal(spotPrice);

    return SignedMath.min(
      imMultiplier.toInt256().multiplyDecimal(amount) + markToMarket,
      maintenanceMargin.multiplyDecimal(params.mmOffsetScale.toInt256())
    );
  }

  function _getIsolatedMarginForCall(
    IStandardManager.OptionMarginParams calldata params,
    int markToMarket,
    uint strike,
    int amount,
    uint spotPrice,
    bool isInitial
  ) internal pure returns (int) {
    if (!isInitial) {
      int mmReqAdd = params.mmCallSpotReq.multiplyDecimal(spotPrice).toInt256().multiplyDecimal(amount);
      return markToMarket + mmReqAdd;
    }

    uint otmRatio;
    if (strike > spotPrice) {
      otmRatio = (strike - spotPrice).divideDecimal(spotPrice);
    }

    uint imMultiplier = params.minSpotReq;
    if (params.maxSpotReq > otmRatio && params.maxSpotReq - otmRatio > params.minSpotReq) {
      imMultiplier = params.maxSpotReq - otmRatio;
    }

    imMultiplier = imMultiplier.multiplyDecimal(spotPrice);
    return imMultiplier.toInt256().multiplyDecimal(amount) + markToMarket;
  }

  function _getMarkToMarket(int amount, uint forwardPrice, uint strike, uint expiry, uint vol, bool isCall)
    internal
    view
    returns (int value)
  {
    uint64 secToExpiry = expiry > block.timestamp ? uint64(expiry - block.timestamp) : 0;

    (uint call, uint put) = Black76.prices(
      Black76.Black76Inputs({
        timeToExpirySec: secToExpiry,
        volatility: vol.toUint128(),
        fwdPrice: forwardPrice.toUint128(),
        strikePrice: strike.toUint128(),
        discount: 1e18
      })
    );

    return (isCall ? call.toInt256() : put.toInt256()).multiplyDecimal(amount);
  }

  function _getSettlementValue(uint strikePrice, int balance, uint settlementPrice, bool isCall)
    internal
    pure
    returns (int)
  {
    int priceDiff = settlementPrice.toInt256() - strikePrice.toInt256();

    if (isCall && priceDiff > 0) {
      return priceDiff.multiplyDecimal(balance);
    } else if (!isCall && priceDiff < 0) {
      return -priceDiff.multiplyDecimal(balance);
    }
    return 0;
  }

}
