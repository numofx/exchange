// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {ISpotFeed} from "../interfaces/ISpotFeed.sol";
import {StreamsIndexAdapter} from "./StreamsIndexAdapter.sol";

/**
 * @title EurcIndexFeed
 * @notice The EURC/USDC index: base stream ÷ quote stream (EURC/USD ÷ USDC/USD = USDC per EURC), 18 dp.
 *         See docs/eurc-usdc-futures-spec.md, A2.3.
 * @dev    Reverts only when either stream's newest report is older than `indexMaxAge`. Divergence checks are
 *         off-chain alerts and never revert here. Only ever a `FutureAsset` index feed, never a market's spot feed:
 *         MarginEngine reads the spot feed for every margin check, and a revert there would stop liquidations.
 *         `indexMaxAge` is immutable: an owner who could set it could hold the index stale, or let a stale price
 *         settle. A change is a new feed, through the FutureAsset feed timelock.
 */
contract EurcIndexFeed is ISpotFeed {
  StreamsIndexAdapter public immutable adapter;
  uint public immutable indexMaxAge;

  error EIF_InvalidConfig();
  error EIF_NoReport();
  error EIF_Stale(bytes32 feedId, uint64 observedAt);

  constructor(StreamsIndexAdapter adapter_, uint indexMaxAge_) {
    if (address(adapter_) == address(0) || indexMaxAge_ == 0) revert EIF_InvalidConfig();
    adapter = adapter_;
    indexMaxAge = indexMaxAge_;
  }

  function getSpot() external view returns (uint spotPrice, uint confidence) {
    uint base = _fresh(adapter.baseFeedId());
    uint quote = _fresh(adapter.quoteFeedId());
    return (base * 1e18 / quote, 1e18);
  }

  function _fresh(bytes32 feedId) internal view returns (uint price) {
    uint64 observedAt;
    (price, observedAt) = adapter.latest(feedId);
    if (observedAt == 0) revert EIF_NoReport();
    // A report stamped ahead of the block (clock skew) counts as fresh.
    if (block.timestamp > observedAt && block.timestamp - observedAt > indexMaxAge) {
      revert EIF_Stale(feedId, observedAt);
    }
  }
}
