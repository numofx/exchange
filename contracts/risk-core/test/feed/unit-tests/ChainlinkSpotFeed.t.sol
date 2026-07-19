// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../src/feeds/ChainlinkSpotFeed.sol";
import "../../shared/mocks/MockAggregatorV3.sol";

contract UNIT_ChainlinkSpotFeed is Test {
  MockAggregatorV3 aggregator;
  ChainlinkSpotFeed feed;

  function setUp() public {
    vm.warp(7 days);
    aggregator = new MockAggregatorV3(8);
    feed = new ChainlinkSpotFeed(IAggregatorV3(address(aggregator)), 1 hours);
  }

  function testConvertsAggregatorDecimalsTo18() public {
    aggregator.setLatestAnswer(95_000 * 1e8, block.timestamp);

    (uint spot, uint confidence) = feed.getSpot();

    assertEq(spot, 95_000e18);
    assertEq(confidence, 1e18);
  }

  function testRevertsWhenDataIsStale() public {
    aggregator.setLatestAnswer(95_000 * 1e8, block.timestamp - 1 hours - 1);

    vm.expectRevert(ChainlinkSpotFeed.CLF_DataTooOld.selector);
    feed.getSpot();
  }
}
