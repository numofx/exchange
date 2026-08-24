// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {Utils} from "../../scripts/utils.sol";

/// @dev exposes the two write paths so the gate can be exercised directly
contract WriteGateHarness is Utils {
  function writeGuarded(string memory name, string memory content) external {
    _writeToDeployments(name, content);
  }

  function writeGenerated(string memory name, string memory content) external {
    _writeGeneratedArtifact(name, content);
  }
}

/**
 * @dev A `forge script` with no --broadcast still runs the whole script body, so before this gate a
 *      dry run left a deployments artifact full of simulated addresses. Nothing downstream can tell
 *      those from real ones -- register-cngn-spot-srm.s.sol reads CNGN_SPOT_STATIC_FEEDS.json and
 *      would generate a vault batch pointing at contracts that exist nowhere.
 *
 *      `forge test` is not a broadcast context either, which makes these assertions possible: the
 *      guarded path must refuse here for the same reason it refuses in a dry run. That also stops a
 *      test from ever clobbering a real deployment artifact.
 */
contract TestDeploymentWriteGate is Test {
  WriteGateHarness internal harness;
  string internal dir;

  function setUp() public {
    harness = new WriteGateHarness();
    dir = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "/");
  }

  function _path(string memory name) internal view returns (string memory) {
    return string.concat(dir, name, ".json");
  }

  function testGuardedWriteIsRefusedOutsideABroadcast() public {
    string memory name = "WRITE_GATE_GUARDED_PROBE";
    string memory path = _path(name);
    // clear rather than assert: a leftover from an earlier run must not be reported as this
    // test's own failure
    if (vm.exists(path)) {
      vm.removeFile(path);
    }

    harness.writeGuarded(name, '{"simulated":true}');

    assertFalse(
      vm.exists(path), "a non-broadcast run wrote a deployments artifact - a dry run would record simulated addresses"
    );
  }

  /// @dev the escape hatch still works, or the calldata generator would silently stop producing
  ///      the artifact the vault signs from
  function testGeneratedArtifactWriteIsNotGated() public {
    string memory name = "WRITE_GATE_GENERATED_PROBE";
    string memory path = _path(name);
    if (vm.exists(path)) {
      vm.removeFile(path);
    }

    harness.writeGenerated(name, '{"generated":true}');

    assertTrue(vm.exists(path), "scripts that deploy nothing must still be able to write");
    // vm.writeJson pretty-prints, so compare parsed content rather than bytes
    assertTrue(vm.parseJsonBool(vm.readFile(path), ".generated"), "content must round-trip");

    vm.removeFile(path);
    assertFalse(vm.exists(path));
  }
}
