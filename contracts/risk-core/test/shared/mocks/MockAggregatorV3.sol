// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

contract MockAggregatorV3 {
  uint8 public immutable decimals;
  int public answer;
  uint public updatedAt;

  constructor(uint8 decimals_) {
    decimals = decimals_;
  }

  function setLatestAnswer(int answer_, uint updatedAt_) external {
    answer = answer_;
    updatedAt = updatedAt_;
  }

  function latestRoundData() external view returns (uint80 roundId, int, uint startedAt, uint, uint80 answeredInRound) {
    return (1, answer, updatedAt, updatedAt, 1);
  }
}
