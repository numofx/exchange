// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../../src/feeds/InvertedChainlinkSpotFeed.sol";
import "../../shared/mocks/MockAggregatorV3.sol";

contract UNIT_InvertedChainlinkSpotFeed is Test {
  MockAggregatorV3 aggregator;
  MockAggregatorV3 sequencerFeed;
  InvertedChainlinkSpotFeed feed;

  function setUp() public {
    vm.warp(7 days);
    aggregator = new MockAggregatorV3(8);
    sequencerFeed = new MockAggregatorV3(0);
    feed = new InvertedChainlinkSpotFeed(IAggregatorV3(address(aggregator)), IAggregatorV3(address(0)), 1 hours, 1 hours);
  }

  function testInvertsAggregatorDecimalsTo18() public {
    aggregator.setLatestAnswer(72_100, block.timestamp);

    (uint spot, uint confidence) = feed.getSpot();

    assertEq(spot, 1386962552011095700416);
    assertEq(confidence, 1e18);
  }

  function testRevertsWhenDataIsStale() public {
    aggregator.setLatestAnswer(72_100, block.timestamp - 1 hours - 1);

    vm.expectRevert(InvertedChainlinkSpotFeed.ICLF_DataTooOld.selector);
    feed.getSpot();
  }

  function testRevertsWhenSequencerIsDown() public {
    feed = new InvertedChainlinkSpotFeed(
      IAggregatorV3(address(aggregator)), IAggregatorV3(address(sequencerFeed)), 1 hours, 1 hours
    );
    aggregator.setLatestAnswer(72_100, block.timestamp);
    sequencerFeed.setLatestAnswer(1, block.timestamp - 2 hours);

    vm.expectRevert(InvertedChainlinkSpotFeed.ICLF_SequencerDown.selector);
    feed.getSpot();
  }

  function testRevertsDuringSequencerGracePeriod() public {
    feed = new InvertedChainlinkSpotFeed(
      IAggregatorV3(address(aggregator)), IAggregatorV3(address(sequencerFeed)), 1 hours, 1 hours
    );
    aggregator.setLatestAnswer(72_100, block.timestamp);
    sequencerFeed.setLatestAnswer(0, block.timestamp);

    vm.expectRevert(InvertedChainlinkSpotFeed.ICLF_GracePeriodNotOver.selector);
    feed.getSpot();
  }
}
