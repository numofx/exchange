// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../../src/SubAccounts.sol";
import "../../src/assets/CashAsset.sol";
import "../../src/assets/WrappedERC20Asset.sol";
import "../../src/interfaces/IAsset.sol";
import "../../src/interfaces/ISpotFeed.sol";
import "../../src/interfaces/IStandardManager.sol";
import "../../src/interfaces/IWrappedERC20Asset.sol";
import "../../src/risk-managers/StandardManager.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @dev Replays deployments/8453/CNGN_SPOT_SRM_VAULT_ACTIONS.json against live Base state as the admin
 *      vault, then trades USDCcNGN-SPOT under the SRM the way the venue would. This validates the exact
 *      calldata the vault is asked to sign, not a re-derivation of it.
 */
contract FORK_TestCNGNSpotOnSRMBase is Test {
  uint internal constant VAULT_ACTION_COUNT = 9;
  uint internal constant CNGN_PER_USDC = 1500e18;

  address internal vault;

  SubAccounts internal subAccounts;
  CashAsset internal cash;
  StandardManager internal srm;
  WrappedERC20Asset internal cngnAsset;
  ISpotFeed internal cngnSpotFeed;
  ISpotFeed internal stableFeed;

  IERC20Metadata internal usdc;
  IERC20Metadata internal cngn;

  address internal dfxManager;
  uint internal marketId;

  address internal alice = address(0xaa02);
  address internal bob = address(0xbb02);
  uint internal aliceAcc;
  uint internal bobAcc;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));

    string memory root = vm.projectRoot();
    string memory coreJson = vm.readFile(string.concat(root, "/deployments/8453/core.json"));
    string memory sharedJson = vm.readFile(string.concat(root, "/deployments/8453/shared.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/deployments/8453/WRAPPED_CNGN.json"));
    string memory futureJson = vm.readFile(string.concat(root, "/deployments/8453/CNGN_SEP16_2026_FUTURE.json"));

    subAccounts = SubAccounts(vm.parseJsonAddress(coreJson, ".subAccounts"));
    cash = CashAsset(vm.parseJsonAddress(coreJson, ".cash"));
    srm = StandardManager(vm.parseJsonAddress(coreJson, ".srm"));
    stableFeed = ISpotFeed(vm.parseJsonAddress(coreJson, ".stableFeed"));
    usdc = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".usdc"));
    cngn = IERC20Metadata(vm.parseJsonAddress(sharedJson, ".cngn"));
    cngnAsset = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    cngnSpotFeed = ISpotFeed(vm.parseJsonAddress(cngnJson, ".spotFeed"));
    dfxManager = vm.parseJsonAddress(futureJson, ".manager");

    vault = srm.owner();
    assertEq(cngnAsset.owner(), vault, "srm and wrapped cngn must share an owner for one vault batch");

    marketId = srm.lastMarketId() + 1;
    _executeVaultActions();

    aliceAcc = subAccounts.createAccountWithApproval(alice, address(this), srm);
    bobAcc = subAccounts.createAccountWithApproval(bob, address(this), srm);

    deal(address(usdc), address(this), 1_000_000 * 1e6);
    deal(address(cngn), address(this), 1_000_000_000e6);
    usdc.approve(address(cash), type(uint).max);
    cngn.approve(address(cngnAsset), type(uint).max);

    // the live feeds are keeper-driven; pin them so the fork does not depend on keeper liveness
    _mockSpot(cngnSpotFeed, CNGN_PER_USDC, 1e18);
    _mockSpot(stableFeed, 1e18, 1e18);
  }

  /// @dev the vault batch registers the market and leaves the deliverable stack intact
  function testFork_VaultActionsRegisterSpotMarket() public {
    assertEq(address(srm.assetMap(marketId, IStandardManager.AssetType.Base)), address(cngnAsset));

    (uint marginFactor, uint imScale) = srm.baseMarginParams(marketId);
    assertEq(marginFactor, 0, "cngn must contribute no margin");
    assertEq(imScale, 0);

    assertFalse(srm.borrowingEnabled(), "borrowing must be off");
    assertTrue(cngnAsset.whitelistedManager(address(srm)), "srm must be whitelisted on wrapped cngn");
    // the deliverable stack keeps working if a dated series is ever relisted
    assertTrue(cngnAsset.whitelistedManager(dfxManager), "dfx manager must stay whitelisted");
  }

  /// @dev buy leg funded by cash on hand settles
  function testFork_FundedSpotBuySettles() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    // alice pays 1,000 cash for 1.5m cNGN at 1500
    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);

    assertEq(_cngnBalance(aliceAcc), 1_500_000e18);
    assertEq(subAccounts.getBalance(aliceAcc, cash, 0), 9_000e18);
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 1_000e18);
  }

  /// @dev buy leg beyond cash on hand is refused: the cNGN being bought gives no margin credit
  function testFork_UnfundedSpotBuyReverts() public {
    _fundCash(aliceAcc, 1_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    vm.expectRevert(IStandardManager.SRM_NoNegativeCash.selector);
    _spotTrade(bobAcc, 3_000_000e18, aliceAcc, 2_000e18);
  }

  /// @dev sell leg works from an account holding no cash at all
  function testFork_SellingCNGNFromCashFreeAccountSettles() public {
    _fundCash(aliceAcc, 10_000 * 1e6);
    _fundCNGN(bobAcc, 15_000_000e18);

    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 0);
    _spotTrade(bobAcc, 1_500_000e18, aliceAcc, 1_000e18);
    assertEq(subAccounts.getBalance(bobAcc, cash, 0), 1_000e18);
  }

  /// @dev there is no short side: the wrapped asset refuses to go negative
  function testFork_CannotSellMoreCNGNThanHeld() public {
    _fundCash(aliceAcc, 100_000 * 1e6);
    _fundCNGN(bobAcc, 1_500_000e18);

    vm.expectRevert(IWrappedERC20Asset.WERC_CannotBeNegative.selector);
    _spotTrade(bobAcc, 3_000_000e18, aliceAcc, 2_000e18);
  }

  /// @dev a cNGN-only holder can always withdraw: zero margin credit is not a lock-up
  function testFork_CanWithdrawCNGNWithNoCash() public {
    _fundCNGN(bobAcc, 1_500_000e18);

    vm.prank(bob);
    cngnAsset.withdraw(bobAcc, 1_500_000e6, bob);

    assertEq(_cngnBalance(bobAcc), 0);
  }

  /// @dev replay the artifact the vault is asked to sign, in order, as the vault
  function _executeVaultActions() internal {
    string memory actionsJson =
      vm.readFile(string.concat(vm.projectRoot(), "/deployments/8453/CNGN_SPOT_SRM_VAULT_ACTIONS.json"));

    for (uint i = 0; i < VAULT_ACTION_COUNT; ++i) {
      string memory idx = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(actionsJson, string.concat(idx, ".to"));
      bytes memory data = vm.parseJsonBytes(actionsJson, string.concat(idx, ".data"));

      vm.prank(vault);
      (bool ok,) = to.call(data);
      assertTrue(
        ok, string.concat("vault action failed: ", vm.parseJsonString(actionsJson, string.concat(idx, ".description")))
      );
    }
  }

  function _fundCash(uint accountId, uint underlyingUsdc) internal {
    cash.deposit(accountId, underlyingUsdc);
  }

  /// @dev takes the 18-decimal sub-account amount; cNGN is 6dp on Base
  function _fundCNGN(uint accountId, uint amount18) internal {
    cngnAsset.deposit(accountId, amount18 / (10 ** (18 - cngn.decimals())));
  }

  /// @dev the venue's spot fill: cNGN one way, internal cash the other
  function _spotTrade(uint cngnFrom, uint cngnAmount, uint cashFrom, uint cashAmount) internal {
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](2);
    batch[0] = ISubAccounts.AssetTransfer({
      fromAcc: cngnFrom, toAcc: cashFrom, asset: cngnAsset, subId: 0, amount: int(cngnAmount), assetData: bytes32(0)
    });
    batch[1] = ISubAccounts.AssetTransfer({
      fromAcc: cashFrom, toAcc: cngnFrom, asset: cash, subId: 0, amount: int(cashAmount), assetData: bytes32(0)
    });
    subAccounts.submitTransfers(batch, "");
  }

  function _cngnBalance(uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, cngnAsset, 0);
  }

  function _mockSpot(ISpotFeed feed, uint price, uint confidence) internal {
    vm.mockCall(address(feed), abi.encodeCall(ISpotFeed.getSpot, ()), abi.encode(price, confidence));
  }
}
