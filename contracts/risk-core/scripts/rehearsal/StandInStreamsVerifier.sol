// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

/**
 * @title StandInStreamsVerifier
 * @notice TESTNET ONLY. Stands in for Chainlink's Data Streams VerifierProxy in the Base Sepolia rehearsal of the
 *         EURC v3 series (spec A1.2), where we hold no testnet Data Streams credentials. Its constructor refuses Base
 *         mainnet, and the deploy script refuses any verifier but Chainlink's there (checkParams, assertDeployment).
 * @dev    Same call and same encoding as the real proxy, so StreamsIndexAdapter runs unchanged: `verify(fullReport,
 *         parameterPayload)` takes `abi.encode(bytes32[3] reportContext, bytes reportData, bytes32[] rs, bytes32[] ss,
 *         bytes32 rawVs)` and returns `reportData`. The signature check is Chainlink's for one signer: ecrecover of
 *         keccak256(abi.encodePacked(keccak256(reportData), reportContext)) with v = uint8(rawVs[0]) + 27. Reports are
 *         signed by the rehearsal's own key (services/perp-feeds standInReportSource). Charges nothing.
 */
contract StandInStreamsVerifier {
  address public immutable signer;

  error SISV_Mainnet();
  error SISV_BadSignature();

  constructor(address _signer) {
    if (block.chainid == 8453) revert SISV_Mainnet();
    signer = _signer;
  }

  function verify(bytes calldata fullReport, bytes calldata) external payable returns (bytes memory) {
    (bytes32[3] memory context, bytes memory reportData, bytes32[] memory rs, bytes32[] memory ss, bytes32 rawVs) =
      abi.decode(fullReport, (bytes32[3], bytes, bytes32[], bytes32[], bytes32));
    if (rs.length != 1 || ss.length != 1) revert SISV_BadSignature();
    bytes32 h = keccak256(abi.encodePacked(keccak256(reportData), context));
    address recovered = ecrecover(h, uint8(rawVs[0]) + 27, rs[0], ss[0]);
    if (recovered == address(0) || recovered != signer) revert SISV_BadSignature();
    return reportData;
  }

  function typeAndVersion() external pure returns (string memory) {
    return "StandInStreamsVerifier 1.0.0 (testnet only)";
  }
}
