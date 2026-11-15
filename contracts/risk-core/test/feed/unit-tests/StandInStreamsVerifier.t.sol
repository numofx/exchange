// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {StreamsIndexAdapter, IStreamsVerifierProxy} from "../../../src/feeds/StreamsIndexAdapter.sol";
import {StandInStreamsVerifier} from "../../../scripts/rehearsal/StandInStreamsVerifier.sol";

/// The Sepolia rehearsal's stand-in for Chainlink's verifier (spec A1.2): the real adapter accepts what our key signed,
/// and nothing else. services/perp-feeds standInReportSource signs the same way; the rehearsal is the cross-check.
contract StandInStreamsVerifierTest is Test {
  bytes32 constant EURC = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb;
  bytes32 constant USDC = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992;
  uint constant SIGNER_PK = 0xA11CE;

  StandInStreamsVerifier verifier;
  StreamsIndexAdapter adapter;

  function setUp() public {
    vm.chainId(84532);
    vm.warp(1_790_000_000);
    verifier = new StandInStreamsVerifier(vm.addr(SIGNER_PK));
    adapter = new StreamsIndexAdapter(IStreamsVerifierProxy(address(verifier)), address(0x11), EURC, USDC);
  }

  function _signed(uint pk, bytes32 feedId, uint observedAt, int price) internal pure returns (bytes memory) {
    StreamsIndexAdapter.ReportV3 memory r = StreamsIndexAdapter.ReportV3({
      feedId: feedId,
      validFromTimestamp: uint32(observedAt),
      observationsTimestamp: uint32(observedAt),
      nativeFee: 0,
      linkFee: 0,
      expiresAt: uint32(observedAt + 1 days),
      benchmarkPrice: int192(price),
      bid: int192(price),
      ask: int192(price)
    });
    bytes memory data = abi.encode(r);
    bytes32[3] memory ctx = [bytes32(uint(1)), bytes32(uint(2)), bytes32(uint(3))];
    (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked(keccak256(data), ctx)));
    bytes32[] memory rs = new bytes32[](1);
    bytes32[] memory ss = new bytes32[](1);
    rs[0] = rr;
    ss[0] = s;
    // rawVs packs one recovery byte per signer, the first signer's in the most significant byte (Chainlink's layout)
    return abi.encode(ctx, data, rs, ss, bytes32(uint(v - 27) << 248));
  }

  function _post(bytes memory report) internal {
    bytes[] memory reports = new bytes[](1);
    reports[0] = report;
    adapter.postReports(reports);
  }

  function testTheAdapterAcceptsWhatOurKeySigned() public {
    _post(_signed(SIGNER_PK, EURC, block.timestamp, 1.16e18));
    (uint price, uint64 at) = adapter.latest(EURC);
    assertEq(price, 1.16e18);
    assertEq(at, block.timestamp);
  }

  function testAnotherKeyIsRefused() public {
    vm.expectRevert(StandInStreamsVerifier.SISV_BadSignature.selector);
    _post(_signed(0xB0B, EURC, block.timestamp, 1.16e18));
  }

  function testATamperedReportIsRefused() public {
    bytes memory report = _signed(SIGNER_PK, EURC, block.timestamp, 1.16e18);
    (bytes32[3] memory ctx, bytes memory data, bytes32[] memory rs, bytes32[] memory ss, bytes32 vs) =
      abi.decode(report, (bytes32[3], bytes, bytes32[], bytes32[], bytes32));
    StreamsIndexAdapter.ReportV3 memory r = abi.decode(data, (StreamsIndexAdapter.ReportV3));
    r.benchmarkPrice = 1.5e18; // the price moved after signing
    vm.expectRevert(StandInStreamsVerifier.SISV_BadSignature.selector);
    _post(abi.encode(ctx, abi.encode(r), rs, ss, vs));
  }

  function testItCannotBeDeployedOnBaseMainnet() public {
    vm.chainId(8453);
    vm.expectRevert(StandInStreamsVerifier.SISV_Mainnet.selector);
    new StandInStreamsVerifier(vm.addr(SIGNER_PK));
  }
}
