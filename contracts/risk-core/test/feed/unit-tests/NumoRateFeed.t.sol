// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "../../../src/feeds/NumoRateFeed.sol";

import "./NumoFeedTestUtils.sol";

contract UNIT_NumoRateFeed is NumoFeedTestUtils {
  NumoRateFeed feed;

  // signer
  uint private pk;
  address private pkOwner;

  uint referenceTime;
  uint64 defaultExpiry;

  function setUp() public {
    feed = new NumoRateFeed();

    // set signer
    pk = 0xBEEF;
    pkOwner = vm.addr(pk);

    vm.warp(block.timestamp + 365 days);
    referenceTime = block.timestamp;
    defaultExpiry = uint64(referenceTime + 365 days);

    feed.addSigner(pkOwner, true);
  }

  function testCanAddSigner() public {
    address alice = address(0xaaaa);
    feed.addSigner(alice, true);
    assertEq(feed.isSigner(alice), true);
  }

  function testCanPassInDataAndUpdateRateFeed() public {
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    feed.acceptData(_signFeedData(feed, pk, feedData));

    (int rate, uint confidence) = feed.getInterestRate(defaultExpiry);

    assertEq(rate, int(-0.1e18));
    assertEq(confidence, 1e18);
  }

  function testCantPassInInvalidConfidence() public {
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    feedData.data = abi.encode(defaultExpiry, -0.1e18, 1.01e18);
    bytes memory data = _signFeedData(feed, pk, feedData);

    vm.expectRevert(INumoRateFeed.LRF_InvalidConfidence.selector);
    feed.acceptData(data);
  }

  function testCannotUpdateRateFeedFromInvalidSigner() public {
    // we don't whitelist the pk owner this time
    feed.addSigner(pkOwner, false);

    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    bytes memory data = _signFeedData(feed, pk, feedData);

    vm.expectRevert(IBaseNumoFeed.BLF_InvalidSigner.selector);
    feed.acceptData(data);
  }

  function testCannotUpdateRateFeedAfterDeadline() public {
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    bytes memory data = _signFeedData(feed, pk, feedData);

    vm.warp(block.timestamp + 10);

    vm.expectRevert(IBaseNumoFeed.BLF_DataExpired.selector);
    feed.acceptData(data);
  }

  function testCannotSetRateInTheFuture() public {
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    feedData.timestamp = uint64(block.timestamp + 1000);

    bytes memory data = _signFeedData(feed, pk, feedData);

    vm.expectRevert(IBaseNumoFeed.BLF_InvalidTimestamp.selector);
    feed.acceptData(data);
  }

  function testIgnoreUpdateIfOlderDataIsPushed() public {
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    feed.acceptData(_signFeedData(feed, pk, feedData));

    // this data has the same timestamp, so it will be ignored
    feedData.data = abi.encode(defaultExpiry, 0.1e18, 1.01e18);
    feed.acceptData(_signFeedData(feed, pk, feedData));

    (int rate, uint confidence) = feed.getInterestRate(defaultExpiry);
    assertEq(rate, -0.1e18);
    assertEq(confidence, 1e18);
  }

  function testCannotSubmitPriceWithReplacedSigner() public {
    // use a different private key to sign the data but still specify pkOwner as signer
    uint pk2 = 0xBEEF2222;

    // replace pkOwner with random signer address
    IBaseNumoFeed.FeedData memory feedData = _getDefaultRateData();
    feedData.signers[0] = pkOwner;
    bytes memory data = _signFeedData(feed, pk2, feedData);

    vm.expectRevert(IBaseNumoFeed.BLF_InvalidSignature.selector);
    feed.acceptData(data);
  }

  function _getDefaultRateData() internal view returns (IBaseNumoFeed.FeedData memory feedData) {
    // expiry, rate, confidence
    bytes memory rateData = abi.encode(defaultExpiry, -0.1e18, 1e18);

    return IBaseNumoFeed.FeedData({
      data: rateData,
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
  }
}
