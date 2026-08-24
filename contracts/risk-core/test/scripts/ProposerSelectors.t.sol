// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {StandardManager} from "../../src/risk-managers/StandardManager.sol";
import {WrappedERC20Asset} from "../../src/assets/WrappedERC20Asset.sol";
import {ManagerWhitelist} from "../../src/assets/utils/ManagerWhitelist.sol";
import {LyraStaticSpotFeed} from "../../src/feeds/static/LyraStaticSpotFeed.sol";

interface IOwnable2StepSelectors {
  function acceptOwnership() external;
  function owner() external view returns (address);
}

/// @dev whitelistedManager is a public state variable, so its getter cannot be referenced as
///      ManagerWhitelist.whitelistedManager. Declared here to build the expected read call.
interface IManagerWhitelistGetter {
  function whitelistedManager(address manager) external view returns (bool);
}

/**
 * @dev Pins the raw selectors hardcoded in scripts/ops/propose_cngn_spot_batch.py.
 *
 *      That script dispatches on the WRITE selector of each batch action to choose which READ to
 *      make, so it can skip an action that already landed. Both halves are hex literals in Python
 *      with no compiler to check them, and the skip check swallows errors into "not landed" -- so a
 *      wrong selector degrades to re-proposing rather than crashing. Safe, but silent, and a
 *      silently-disarmed skip check is how an operator ends up approving the same action twice.
 *
 *      Two were wrong when first written from memory (stableFeed, borrowingEnabled).
 *
 *      These assert against the LIVE deployed contracts rather than against a signature string.
 *      Several of the reads are public state variables, whose getter selectors cannot be taken as
 *      `Type.member.selector` at all -- and asserting keccak of a signature I typed would only
 *      prove I typed it twice. Staticcalling the real bytecode and comparing to the typed getter
 *      proves the selector reaches the getter the script believes it does.
 */
contract FORK_TestProposerSelectors is Test {
  // writes: matched against the artifact's calldata to pick a branch
  bytes4 internal constant SEL_ACCEPT_OWNERSHIP = 0x79ba5097;
  bytes4 internal constant SEL_SET_STABLE_FEED = 0xbafb798d;
  bytes4 internal constant SEL_SET_BORROWING_ENABLED = 0xf1514a1a;
  bytes4 internal constant SEL_CREATE_MARKET = 0x54888f55;
  bytes4 internal constant SEL_SET_WHITELIST_MANAGER = 0xe64cc9da;

  // reads: the postcondition each branch checks
  bytes4 internal constant SEL_OWNER = 0x8da5cb5b;
  bytes4 internal constant SEL_STABLE_FEED = 0xf4d0508a;
  bytes4 internal constant SEL_BORROWING_ENABLED = 0xa35d1300;
  bytes4 internal constant SEL_LAST_MARKET_ID = 0x565eb87c;
  bytes4 internal constant SEL_WHITELISTED_MANAGER = 0x97d51c04;

  StandardManager internal srm;
  WrappedERC20Asset internal cngnAsset;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    string memory root = vm.projectRoot();
    srm = StandardManager(vm.parseJsonAddress(vm.readFile(string.concat(root, "/deployments/8453/core.json")), ".srm"));
    cngnAsset = WrappedERC20Asset(
      vm.parseJsonAddress(vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json")), ".base")
    );
  }

  function _read(address target, bytes memory data) internal view returns (bytes memory) {
    (bool ok, bytes memory ret) = target.staticcall(data);
    assertTrue(ok, "raw selector call failed against live bytecode");
    return ret;
  }

  function testWriteSelectorsMatchTheProposerDispatch() public {
    assertEq(IOwnable2StepSelectors.acceptOwnership.selector, SEL_ACCEPT_OWNERSHIP, "acceptOwnership");
    assertEq(StandardManager.setStableFeed.selector, SEL_SET_STABLE_FEED, "setStableFeed");
    assertEq(StandardManager.setBorrowingEnabled.selector, SEL_SET_BORROWING_ENABLED, "setBorrowingEnabled");
    assertEq(StandardManager.createMarket.selector, SEL_CREATE_MARKET, "createMarket");
    assertEq(ManagerWhitelist.setWhitelistManager.selector, SEL_SET_WHITELIST_MANAGER, "setWhitelistManager");
  }

  /// @dev each raw read selector must reach the getter the script assumes, on the real deployment
  function testReadSelectorsReachTheIntendedGettersOnLiveContracts() public {
    assertEq(
      abi.decode(_read(address(srm), abi.encodeWithSelector(SEL_STABLE_FEED)), (address)),
      address(srm.stableFeed()),
      "stableFeed selector"
    );
    assertEq(
      abi.decode(_read(address(srm), abi.encodeWithSelector(SEL_BORROWING_ENABLED)), (bool)),
      srm.borrowingEnabled(),
      "borrowingEnabled selector"
    );
    assertEq(
      abi.decode(_read(address(srm), abi.encodeWithSelector(SEL_LAST_MARKET_ID)), (uint)),
      srm.lastMarketId(),
      "lastMarketId selector"
    );
    assertEq(
      abi.decode(_read(address(srm), abi.encodeWithSelector(SEL_OWNER)), (address)), srm.owner(), "owner selector"
    );
    assertEq(
      abi.decode(_read(address(cngnAsset), abi.encodeWithSelector(SEL_WHITELISTED_MANAGER, address(srm))), (bool)),
      cngnAsset.whitelistedManager(address(srm)),
      "whitelistedManager selector"
    );
  }

  /// @dev the static feeds are read with the same owner() selector, so it must reach that getter
  ///      on LyraStaticSpotFeed too and not only on the manager
  function testOwnerSelectorReachesTheStaticFeedGetter() public {
    LyraStaticSpotFeed feed = new LyraStaticSpotFeed();
    assertEq(
      abi.decode(_read(address(feed), abi.encodeWithSelector(SEL_OWNER)), (address)), feed.owner(), "feed owner()"
    );
  }

  /// @dev the proposer builds whitelistedManager(address) by splicing its selector onto the SRM
  ///      word lifted out of setWhitelistManager's calldata. That only works because the manager
  ///      address is the first argument of both.
  function testWhitelistManagerArgumentLayoutSupportsTheSplice() public {
    address manager = address(0xBEEF);

    bytes memory write = abi.encodeCall(ManagerWhitelist.setWhitelistManager, (manager, true));
    bytes memory expected = abi.encodeCall(IManagerWhitelistGetter.whitelistedManager, (manager));

    bytes memory spliced = abi.encodePacked(SEL_WHITELISTED_MANAGER);
    for (uint i = 4; i < 36; ++i) {
      spliced = abi.encodePacked(spliced, write[i]);
    }

    assertEq(keccak256(spliced), keccak256(expected), "the splice must reproduce a real read call");
  }
}
