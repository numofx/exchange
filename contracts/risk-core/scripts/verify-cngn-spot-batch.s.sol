// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IStandardManager} from "../src/interfaces/IStandardManager.sol";
import {StandardManager} from "../src/risk-managers/StandardManager.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";
import {CNGNSpotBatch} from "./cngn-spot-batch.sol";
import {VmSafe} from "forge-std/Vm.sol";

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
 *   (default)              verify the committed artifact end to end
 *   RESUME=1               read postconditions from chain: done / pending / diverged per action
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

    if (vm.envOr("RESUME", uint(0)) == 1) {
      _reportProgress(ctx, to, data);
      return;
    }

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

  /// @dev Resume a partially-executed batch. The vault is an EOA, so the batch is 11 transactions
  ///      and a stop leaves real partial state; this reads each action's postcondition from chain
  ///      and says where to pick up.
  function _reportProgress(CNGNSpotBatch.Ctx memory ctx, address[] memory to, bytes[] memory data) internal view {
    CNGNSpotBatch.Status[] memory raw = CNGNSpotBatch.statuses(ctx);

    // action 5 can be settled from logs; action 6 cannot -- see _marginParamsLogged
    bool loggedFive = _marginParamsLogged(ctx);
    if (loggedFive && raw[5] == CNGNSpotBatch.Status.Ambiguous) raw[5] = CNGNSpotBatch.Status.Done;

    CNGNSpotBatch.Status[] memory st = CNGNSpotBatch.resolve(raw);
    (,, string[] memory descriptions) = CNGNSpotBatch.build(ctx);

    uint firstPending = type(uint).max;
    uint diverged;

    for (uint i = 0; i < st.length; ++i) {
      console2.log("  [%s] %s  %s", i, _label(st[i], raw[i]), descriptions[i]);
      console2.log("        digest %s", vm.toString(CNGNSpotBatch.actionHash(to[i], data[i])));

      if (st[i] == CNGNSpotBatch.Status.Diverged) diverged++;
      if (st[i] == CNGNSpotBatch.Status.Pending && i < firstPending) firstPending = i;
    }

    if (st[6] == CNGNSpotBatch.Status.Done && raw[6] == CNGNSpotBatch.Status.Ambiguous) {
      console2.log("");
      console2.log("Action 6 is inferred from nonce ordering (done*). OracleContingencySet carries no");
      console2.log("market id, so state and logs alone cannot settle it. For a positive read, decode");
      console2.log("the market id from the emitting transaction's calldata:");
      console2.log("  python3 scripts/ops/resolve_cngn_action6.py --from-block <n> --market-id %s", ctx.marketId);
    }

    console2.log("");
    if (diverged > 0) {
      console2.log("DIVERGED: %s action(s) disagree with chain state.", diverged);
      revert("chain state diverges from the batch - do not resume, investigate first");
    }
    if (firstPending == type(uint).max) {
      console2.log("COMPLETE: all 11 actions are done.");
      return;
    }

    console2.log("RESUME AT ACTION %s. Actions 0..%s are done.", firstPending, firstPending - 1);
    if (firstPending < 10) {
      console2.log("The venue is NOT live: the enabling switch is action 10 and it has not run.");
    }
  }

  /// @dev Settle action 5 from logs instead of inference. `BaseMarginParamsSet(uint marketId, uint
  ///      baseAssetMarginFactor, uint baseAssetIMScale)` carries the market id, so a matching event
  ///      is direct evidence the call landed.
  ///
  ///      Action 6 gets no such treatment: `OracleContingencySet(uint prepThreshold, uint
  ///      optionThreshold, uint baseThreshold, uint OCFactor)` omits the market id entirely, so a
  ///      log cannot be attributed to a market. It stays on nonce inference, which is why the
  ///      runbook requires the vault to send nothing else until action 10 confirms.
  ///
  ///      A miss NEVER downgrades a status. Public RPCs cap eth_getLogs ranges, so "no event in the
  ///      window" means "not found here", not "did not happen". Logs can only raise confidence.
  function _marginParamsLogged(CNGNSpotBatch.Ctx memory ctx) internal view returns (bool) {
    uint window = vm.envOr("LOG_SCAN_BLOCKS", uint(50_000));
    if (window == 0) return false;

    uint toBlock = block.number;
    uint fromBlock = vm.envOr("LOG_SCAN_FROM_BLOCK", uint(0));
    if (fromBlock == 0) fromBlock = toBlock > window ? toBlock - window : 0;

    bytes32[] memory topics = new bytes32[](1);
    topics[0] = keccak256("BaseMarginParamsSet(uint256,uint256,uint256)");

    try vm.eth_getLogs(fromBlock, toBlock, ctx.srm, topics) returns (VmSafe.EthGetLogs[] memory logs) {
      for (uint i = 0; i < logs.length; ++i) {
        (uint marketId, uint marginFactor, uint imScale) = abi.decode(logs[i].data, (uint, uint, uint));
        if (marketId == ctx.marketId && marginFactor == 0 && imScale == 0) {
          console2.log("  action 5 confirmed by BaseMarginParamsSet in block %s", logs[i].blockNumber);
          return true;
        }
      }
      console2.log("  no BaseMarginParamsSet for market %s in blocks %s..%s", ctx.marketId, fromBlock, toBlock);
      return false;
    } catch {
      console2.log("  eth_getLogs unavailable or range rejected - falling back to nonce inference");
      return false;
    }
  }

  /// @dev AMBIGUOUS is reported honestly rather than rounded to done. Actions 5 and 6 write
  ///      all-zeros, which is what an untouched market already reads, so state alone cannot tell
  ///      them apart. resolve() clears them only when a later action proves the batch got past them.
  function _label(CNGNSpotBatch.Status resolved, CNGNSpotBatch.Status raw) internal pure returns (string memory) {
    if (resolved == CNGNSpotBatch.Status.Diverged) return "DIVERGED";
    if (resolved == CNGNSpotBatch.Status.Done) {
      return raw == CNGNSpotBatch.Status.Ambiguous ? "done*   " : "done    ";
    }
    if (resolved == CNGNSpotBatch.Status.Ambiguous) return "unknown ";
    return "pending ";
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
