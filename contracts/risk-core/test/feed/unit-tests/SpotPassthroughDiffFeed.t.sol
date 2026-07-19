// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {MockFeeds} from "../../shared/mocks/MockFeeds.sol";
import {SpotPassthroughDiffFeed} from "../../../src/feeds/SpotPassthroughDiffFeed.sol";

contract UNIT_SpotPassthroughDiffFeed is Test {
  MockFeeds internal spotFeed;
  SpotPassthroughDiffFeed internal diffFeed;

  function setUp() public {
    spotFeed = new MockFeeds();
    diffFeed = new SpotPassthroughDiffFeed(spotFeed);
  }

  function test_returnsUnderlyingSpotAndConfidence() public {
    spotFeed.setSpot(1386.962552e18, 0.99e18);

    (uint result, uint confidence) = diffFeed.getResult();

    assertEq(result, 1386.962552e18);
    assertEq(confidence, 0.99e18);
  }
}
