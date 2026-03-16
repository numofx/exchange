// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {ISpotDiffFeed} from "../interfaces/ISpotDiffFeed.sol";
import {ISpotFeed} from "../interfaces/ISpotFeed.sol";

/**
 * @title SpotPassthroughDiffFeed
 * @notice Minimal `ISpotDiffFeed` adapter that returns the underlying spot price unchanged.
 * @dev Useful when a perp should bootstrap with mark and impact prices equal to index.
 */
contract SpotPassthroughDiffFeed is ISpotDiffFeed {
  ISpotFeed public immutable override spotFeed;

  constructor(ISpotFeed spotFeed_) {
    spotFeed = spotFeed_;
  }

  function getResult() external view returns (uint result, uint confidence) {
    return spotFeed.getSpot();
  }
}
