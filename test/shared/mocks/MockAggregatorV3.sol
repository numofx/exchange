// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

contract MockAggregatorV3 {
  uint8 public immutable decimals;
  int256 public answer;
  uint256 public updatedAt;

  constructor(uint8 decimals_) {
    decimals = decimals_;
  }

  function setLatestAnswer(int256 answer_, uint256 updatedAt_) external {
    answer = answer_;
    updatedAt = updatedAt_;
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256, uint256 startedAt, uint256, uint80 answeredInRound)
  {
    return (1, answer, updatedAt, updatedAt, 1);
  }
}
