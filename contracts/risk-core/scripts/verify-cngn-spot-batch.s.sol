// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";
import {CNGNSpotBatch} from "./cngn-spot-batch.sol";

/**
 * @dev Verifies what will actually be signed.
 *
 * @dev The vault `0x1dcA42…F435` is an EOA (codesize 0), not a Safe. There is no MultiSend and no
 *      single proposed payload: the batch is eleven separate transactions, each approved on its own.
 *      So the unit of verification is one `(to, data)` pair — exactly what an MPC signer displays —
 *      and this script gives you the digest of each so you can compare them one at a time.
 *
 * @dev Two independent checks, because they catch different things:
 *
 *      1. ARTIFACT INTEGRITY. Each entry's recorded `digest` is recomputed from that entry's own
 *         `to` and `data`. Catches a JSON edited after generation.
 *
 *      2. ARTIFACT AUTHENTICITY. The batch is rebuilt from CNGNSpotBatch against LIVE chain state
 *         and compared byte-for-byte to the artifact. Catches a JSON that is internally consistent
 *         but was generated against a different world — a market id that has since moved, a feed
 *         that was redeployed, a cap derived from stale supply.
 *
 *      Check 1 alone is worthless against a competent edit: whoever changes `data` can recompute the
 *      digest. Check 2 is the one with teeth, and it is why this reads the chain.
 *
 * Usage:
 *   MODE unset          verify the committed artifact end to end
 *   ACTION_TO/ACTION_DATA  identify a single pending transaction before approving it
 *
 *   forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $BASE_RPC_URL
 *   ACTION_TO=0x… ACTION_DATA=0x… forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $BASE_RPC_URL
 */
contract VerifyCNGNSpotBatch is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_SPOT_SRM_VAULT_ACTIONS";

  function run() external view {
    CNGNSpotBatch.Ctx memory ctx = _liveCtx();
    (address[] memory to, bytes[] memory data,) = CNGNSpotBatch.build(ctx);

    bytes memory single = vm.envOr("ACTION_DATA", bytes(""));
    if (single.length > 0) {
      _identifySingleAction(to, data, vm.envAddress("ACTION_TO"), single);
      return;
    }

    _verifyArtifact(to, data);
  }

  /// @dev answers the only question a signer has while staring at a pending transaction: "is this
  ///      one of mine, and which?" Anything that is not an exact (to, data) match is rejected —
  ///      a matching target with altered calldata is the case this exists to catch.
  function _identifySingleAction(address[] memory to, bytes[] memory data, address actionTo, bytes memory actionData)
    internal
    pure
  {
    bytes32 digest = CNGNSpotBatch.actionHash(actionTo, actionData);
    console2.log("pending tx digest:", vm.toString(digest));

    for (uint i = 0; i < to.length; ++i) {
      if (CNGNSpotBatch.actionHash(to[i], data[i]) == digest) {
        console2.log("MATCH: this is action %s of 11.", i);
        console2.log("Approve it only if actions 0..%s are already mined, in order.", i == 0 ? 0 : i - 1);
        return;
      }
    }

    revert("NO MATCH - this transaction is not in the batch. Do not sign it.");
  }

  function _verifyArtifact(address[] memory to, bytes[] memory data) internal view {
    string memory artifact = _readDeploymentFile(ARTIFACT_NAME);

    for (uint i = 0; i < to.length; ++i) {
      string memory idx = string.concat("[", vm.toString(i), "]");
      address artifactTo = vm.parseJsonAddress(artifact, string.concat(idx, ".to"));
      bytes memory artifactData = vm.parseJsonBytes(artifact, string.concat(idx, ".data"));
      bytes32 recorded = vm.parseJsonBytes32(artifact, string.concat(idx, ".digest"));
      string memory value = vm.parseJsonString(artifact, string.concat(idx, ".value"));

      // 1. integrity: the recorded digest describes this entry
      require(CNGNSpotBatch.actionHash(artifactTo, artifactData) == recorded, "digest does not match entry");

      // 2. authenticity: the entry is what the library builds against live state
      require(artifactTo == to[i], "artifact target differs from live-derived batch");
      require(keccak256(artifactData) == keccak256(data[i]), "artifact calldata differs from live-derived batch");

      // every action in this batch moves no ether; a non-zero value is never correct here
      require(keccak256(bytes(value)) == keccak256(bytes("0")), "action carries non-zero value");

      console2.log("  [%s] ok  %s", i, vm.toString(recorded));
    }

    console2.log("");
    console2.log("artifact matches live-derived batch. batch hash:");
    console2.log(vm.toString(CNGNSpotBatch.hash(_liveCtx())));
  }

  /// @dev rebuild the context from the chain, not from the artifact: reading the ctx back out of the
  ///      file being verified would make the comparison circular
  function _liveCtx() internal view returns (CNGNSpotBatch.Ctx memory) {
    Deployment memory deployment = _loadDeployment();

    string memory cngnJson = _readDeploymentFile("CNGN");
    string memory feeds = _readDeploymentFile("CNGN_SPOT_STATIC_FEEDS");

    address wrappedCngn = vm.parseJsonAddress(cngnJson, ".base");
    address cngnToken = vm.parseJsonAddress(cngnJson, ".wrappedAsset");

    uint marketId = vm.envOr("CNGN_MARKET_ID", uint(0));
    if (marketId == 0) marketId = deployment.srm.lastMarketId() + 1;

    uint pct = vm.envOr("CNGN_SPOT_CAP_PCT", uint(10));
    uint supply18 = IERC20Like(cngnToken).totalSupply() * (10 ** (18 - IERC20Like(cngnToken).decimals()));
    uint baseCap = vm.envOr("CNGN_SPOT_BASE_CAP", uint(0));
    if (baseCap == 0) baseCap = supply18 * pct / 100;

    return CNGNSpotBatch.Ctx({
      srm: address(deployment.srm),
      wrappedCngn: wrappedCngn,
      cngnFeed: vm.parseJsonAddress(feeds, ".cngnStaticSpotFeed"),
      stableFeed: vm.parseJsonAddress(feeds, ".stableStaticSpotFeed"),
      marketId: marketId,
      baseCap: baseCap
    });
  }
}

interface IERC20Like {
  function totalSupply() external view returns (uint);
  function decimals() external view returns (uint8);
}
