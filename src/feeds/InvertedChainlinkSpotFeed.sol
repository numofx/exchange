// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable2Step.sol";

import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {IAggregatorV3} from "./ChainlinkSpotFeed.sol";

/**
 * @title InvertedChainlinkSpotFeed
 * @notice Adapts a Chainlink feed quoted as base/quote into the inverse quote/base price.
 * @dev Returns 18 decimal prices and a fixed confidence of 1e18. An optional L2 sequencer
 *      uptime feed can be enabled to block reads while the sequencer is down or within
 *      a post-recovery grace period.
 */
contract InvertedChainlinkSpotFeed is Ownable2Step, ISpotFeed {
  uint private constant ONE = 1e18;

  IAggregatorV3 public immutable aggregator;
  IAggregatorV3 public immutable sequencerUptimeFeed;
  uint8 public immutable aggregatorDecimals;
  uint64 public heartbeat;
  uint64 public sequencerGracePeriod;

  error ICLF_DataTooOld();
  error ICLF_InvalidPrice();
  error ICLF_SequencerDown();
  error ICLF_GracePeriodNotOver();

  constructor(
    IAggregatorV3 aggregator_,
    IAggregatorV3 sequencerUptimeFeed_,
    uint64 heartbeat_,
    uint64 sequencerGracePeriod_
  ) Ownable(msg.sender) {
    aggregator = aggregator_;
    sequencerUptimeFeed = sequencerUptimeFeed_;
    aggregatorDecimals = aggregator_.decimals();
    heartbeat = heartbeat_;
    sequencerGracePeriod = sequencerGracePeriod_;
  }

  function setHeartbeat(uint64 newHeartbeat) external onlyOwner {
    heartbeat = newHeartbeat;
  }

  function setSequencerGracePeriod(uint64 newSequencerGracePeriod) external onlyOwner {
    sequencerGracePeriod = newSequencerGracePeriod;
  }

  function getSpot() external view returns (uint spotPrice, uint confidence) {
    _checkSequencer();

    (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();

    if (answer <= 0) revert ICLF_InvalidPrice();
    if (updatedAt + heartbeat < block.timestamp) revert ICLF_DataTooOld();

    uint normalizedAnswer = _normalizeTo18(uint(answer));
    spotPrice = (ONE * ONE) / normalizedAnswer;
    confidence = ONE;
  }

  function _normalizeTo18(uint answer) internal view returns (uint) {
    if (aggregatorDecimals < 18) {
      return answer * (10 ** (18 - aggregatorDecimals));
    }

    if (aggregatorDecimals > 18) {
      return answer / (10 ** (aggregatorDecimals - 18));
    }

    return answer;
  }

  function _checkSequencer() internal view {
    if (address(sequencerUptimeFeed) == address(0)) {
      return;
    }

    (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();

    if (answer != 0) revert ICLF_SequencerDown();
    if (startedAt + sequencerGracePeriod > block.timestamp) revert ICLF_GracePeriodNotOver();
  }
}
