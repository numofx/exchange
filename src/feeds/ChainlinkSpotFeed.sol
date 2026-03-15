// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable2Step.sol";

import {ISpotFeed} from "../interfaces/ISpotFeed.sol";

interface IAggregatorV3 {
  function decimals() external view returns (uint8);
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title ChainlinkSpotFeed
 * @notice Adapts a Chainlink AggregatorV3 price feed into the local ISpotFeed interface.
 * @dev Returns 18 decimal prices and a fixed confidence of 1e18.
 */
contract ChainlinkSpotFeed is Ownable2Step, ISpotFeed {
  IAggregatorV3 public immutable aggregator;
  uint8 public immutable aggregatorDecimals;
  uint64 public heartbeat;

  error CLF_InvalidPrice();
  error CLF_DataTooOld();

  constructor(IAggregatorV3 aggregator_, uint64 heartbeat_) Ownable(msg.sender) {
    aggregator = aggregator_;
    aggregatorDecimals = aggregator_.decimals();
    heartbeat = heartbeat_;
  }

  function setHeartbeat(uint64 newHeartbeat) external onlyOwner {
    heartbeat = newHeartbeat;
  }

  function getSpot() external view returns (uint spotPrice, uint confidence) {
    (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();

    if (answer <= 0) revert CLF_InvalidPrice();
    if (updatedAt + heartbeat < block.timestamp) revert CLF_DataTooOld();

    uint unsignedAnswer = uint(answer);
    if (aggregatorDecimals < 18) {
      spotPrice = unsignedAnswer * (10 ** (18 - aggregatorDecimals));
    } else if (aggregatorDecimals > 18) {
      spotPrice = unsignedAnswer / (10 ** (aggregatorDecimals - 18));
    } else {
      spotPrice = unsignedAnswer;
    }

    confidence = 1e18;
  }
}
