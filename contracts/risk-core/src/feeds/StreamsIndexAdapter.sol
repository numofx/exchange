// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {IDataReceiver} from "../interfaces/IDataReceiver.sol";

/// @dev Chainlink Data Streams verifier proxy (`VerifierProxy 2.0.0` on Base). `verify` returns the signed report data.
interface IStreamsVerifierProxy {
  function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory);
}

/**
 * @title StreamsIndexAdapter
 * @notice Verifies Chainlink Data Streams V3 reports for a base and a quote stream and keeps the newest of each.
 *         See docs/eurc-usdc-futures-spec.md, A2.2.
 * @dev    - Anyone may post: the verifier authenticates the report, so the caller is irrelevant. Reports arrive
 *           directly or through a manager's `managerData` (`IDataReceiver`).
 *         - Newest-report-only: a report no newer than the stored one for its stream is skipped, not reverted, so a
 *           report posted first by someone else cannot make a trade carrying an attached report fail.
 *         - No owner and nothing settable. A different verifier or stream is a new adapter.
 *         - Fees fail closed: `verify` is called with no value and the adapter holds no tokens or approvals, so a
 *           fee manager that charges makes verification revert rather than spend anything.
 */
contract StreamsIndexAdapter is IDataReceiver {
  /// @dev Data Streams report schema V3 (crypto streams), as returned by `verify`.
  struct ReportV3 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 benchmarkPrice;
    int192 bid;
    int192 ask;
  }

  struct Latest {
    uint192 price;
    uint64 observedAt;
  }

  IStreamsVerifierProxy public immutable verifierProxy;
  /// @dev Fee token named in `parameterPayload`. Never approved or held: it only lets a charging fee manager decode
  ///      the payload and then fail on the missing allowance.
  address public immutable feeToken;
  bytes32 public immutable baseFeedId;
  bytes32 public immutable quoteFeedId;

  mapping(bytes32 feedId => Latest) internal _latest;

  event ReportAccepted(bytes32 indexed feedId, uint price, uint64 observedAt);
  event ReportSkipped(bytes32 indexed feedId, uint64 observedAt, uint64 storedObservedAt);

  error SIA_InvalidConfig();
  error SIA_UnknownFeed(bytes32 feedId);
  error SIA_InvalidPrice();
  error SIA_FeedMismatch();

  constructor(IStreamsVerifierProxy verifierProxy_, address feeToken_, bytes32 baseFeedId_, bytes32 quoteFeedId_) {
    if (
      address(verifierProxy_) == address(0) || baseFeedId_ == bytes32(0) || quoteFeedId_ == bytes32(0)
        || baseFeedId_ == quoteFeedId_
    ) revert SIA_InvalidConfig();
    verifierProxy = verifierProxy_;
    feeToken = feeToken_;
    baseFeedId = baseFeedId_;
    quoteFeedId = quoteFeedId_;
  }

  /// @param data abi.encode(bytes[] fullReports), each a `fullReport` as served by the Data Streams API.
  function acceptData(bytes calldata data) external {
    bytes[] memory reports = abi.decode(data, (bytes[]));
    for (uint i; i < reports.length; ++i) {
      _post(reports[i]);
    }
  }

  function postReports(bytes[] calldata reports) external {
    for (uint i; i < reports.length; ++i) {
      _post(reports[i]);
    }
  }

  /// @return price 18 dp, 0 if no report yet
  /// @return observedAt the report's `observationsTimestamp`, 0 if no report yet
  function latest(bytes32 feedId) external view returns (uint price, uint64 observedAt) {
    Latest memory l = _latest[feedId];
    return (l.price, l.observedAt);
  }

  function _post(bytes memory fullReport) internal {
    // Skip without paying for verification when the embedded report is not newer. The embedded fields are only used
    // to skip; what is stored comes from the verifier's output.
    (, bytes memory embedded) = abi.decode(fullReport, (bytes32[3], bytes));
    ReportV3 memory unverified = abi.decode(embedded, (ReportV3));
    _checkFeed(unverified.feedId);
    uint64 stored = _latest[unverified.feedId].observedAt;
    if (unverified.observationsTimestamp <= stored) {
      emit ReportSkipped(unverified.feedId, unverified.observationsTimestamp, stored);
      return;
    }

    ReportV3 memory report = abi.decode(verifierProxy.verify(fullReport, abi.encode(feeToken)), (ReportV3));
    if (report.feedId != unverified.feedId || report.observationsTimestamp != unverified.observationsTimestamp) {
      revert SIA_FeedMismatch();
    }
    if (report.benchmarkPrice <= 0) revert SIA_InvalidPrice();

    _latest[report.feedId] = Latest(uint192(report.benchmarkPrice), report.observationsTimestamp);
    emit ReportAccepted(report.feedId, uint(uint192(report.benchmarkPrice)), report.observationsTimestamp);
  }

  function _checkFeed(bytes32 feedId) internal view {
    if (feedId != baseFeedId && feedId != quoteFeedId) revert SIA_UnknownFeed(feedId);
  }
}
