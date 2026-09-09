// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {SubAccounts} from "v2-core/src/SubAccounts.sol";
import {MockManager} from "v2-core/test/shared/mocks/MockManager.sol";

import {Matching} from "../../src/Matching.sol";
import {TradeModule} from "../../src/modules/TradeModule.sol";
import {IMatching} from "../../src/interfaces/IMatching.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {DeployWrappedQuoteTradeModule} from "../../scripts/deploy-wrapped-quote-trade-module.s.sol";

/// @dev Exposes the script's own precondition, so what runs here is the code that runs on Base and
///      not a restatement of it. The script's other preconditions read live deployments from disk;
///      this one is parameterised precisely so it can be driven against a real SubAccounts without
///      a fork, and therefore runs in plain `forge test`.
contract DeployWrappedQuotePreconditionHarness is DeployWrappedQuoteTradeModule {
  function checkFeeRecipient(ISubAccounts subAccounts, uint feeAccount, address expectedOwner, address expectedManager)
    external
    view
  {
    _assertFeeRecipient(subAccounts, feeAccount, expectedOwner, expectedManager);
  }

  /// @dev Drives the script's own ownership postcondition, not a copy of it.
  function checkOwnership(TradeModule module, address expectedVault, address expectedDeployer) external view {
    _assertOwnershipOffered(module, expectedVault, expectedDeployer);
  }
}

/**
 * @title WrappedQuoteDeployPreconditions
 *
 * @dev `TradeModule.quoteAsset` and `feeRecipient` are immutable, so the fee recipient the deploy
 *      script wires into the constructor cannot be corrected afterwards — a wrong id means
 *      redeploying the module and reissuing the whole vault batch. These tests pin the one
 *      precondition that stands between an off-chain-resolved id and that outcome.
 *
 * @dev The case that matters is testFeeRecipientRacedByAnotherEOAIsRejected. `createAccount` is
 *      permissionless and ids are `++lastAccountId` (SubAccounts.sol:96), global and sequential, so
 *      an id resolved by reading `lastAccountId` is only a prediction. A stranger's createAccount
 *      lands in front of yours and takes it. The resulting account passes a code-length test (a
 *      stranger EOA has no code) and passes the manager test (anyone may create under the SRM), so
 *      it is invisible to any check that does not name the owner it wants.
 */
contract WrappedQuoteDeployPreconditionsTest is Test {
  SubAccounts internal subAccounts;
  MockManager internal srm;
  MockManager internal otherManager;

  DeployWrappedQuotePreconditionHarness internal script;

  /// @dev stands in for 0x1dcA42ab54Bd3862853A821F84B29BF65245F435, the MPC vault that owns
  ///      Matching and the SRM on Base. An EOA (verified: `cast code` returns 0x), which is why it
  ///      can sign the setAssetAllowances of vault action 3 at all.
  address internal vault = makeAddr("vault");
  address internal stranger = makeAddr("stranger");

  function setUp() public {
    subAccounts = new SubAccounts("Numo Subaccounts", "NUMO");
    srm = new MockManager(address(subAccounts));
    otherManager = new MockManager(address(subAccounts));
    script = new DeployWrappedQuotePreconditionHarness();
  }

  /// @dev The intended shape: the vault owns the fee account, and it sits under the SRM.
  function testVaultOwnedFeeRecipientIsAccepted() public {
    uint feeAcc = subAccounts.createAccount(vault, IManager(address(srm)));
    script.checkFeeRecipient(subAccounts, feeAcc, vault, address(srm));
  }

  /**
   * @dev THE RACE. This is the assertion with teeth: every property the pre-fix check tested is
   *      satisfied here, and the account is still the wrong one.
   *
   *      The deployer reads lastAccountId, expects to be handed `expectedId`, and puts it in
   *      FEE_RECIPIENT_SUBACCOUNT. A stranger's createAccount mines first, so `expectedId` is
   *      theirs and the vault's account is one higher. Nothing about the stranger's account looks
   *      wrong from the outside — hence the two assertions below, which are the pre-fix check
   *      restated: it would have returned cleanly, the module would have been constructed against
   *      an account the vault does not control, and action 3 of the vault batch would be a call
   *      only the stranger could make.
   */
  function testFeeRecipientRacedByAnotherEOAIsRejected() public {
    uint expectedId = subAccounts.lastAccountId() + 1;

    // the race: someone else's createAccount takes the id, under the same manager
    uint racedId = subAccounts.createAccount(stranger, IManager(address(srm)));
    assertEq(racedId, expectedId, "the raced account must take the id the deployer resolved");

    // ... and it is indistinguishable to the checks that came before this one
    assertEq(subAccounts.ownerOf(expectedId).code.length, 0, "a stranger EOA has no code");
    assertEq(address(subAccounts.manager(expectedId)), address(srm), "and is managed by the SRM");

    // the account the deployer meant to use exists, one id later
    uint vaultAcc = subAccounts.createAccount(vault, IManager(address(srm)));
    assertEq(vaultAcc, expectedId + 1);

    vm.expectRevert(
      bytes("fee recipient is not owned by the vault - wrong id, or the id was raced by another createAccount")
    );
    script.checkFeeRecipient(subAccounts, expectedId, vault, address(srm));
  }

  /**
   * @dev The contract-owned case keeps its own message, because it has its own fix. Subaccount 1 on
   *      Base — the live module's feeRecipient — is owned AND managed by the StandardManager, which
   *      exposes no call reaching setAssetAllowances, so no sequencing or retry rescues it: it
   *      needs a different account entirely.
   */
  function testContractOwnedFeeRecipientIsRejectedWithItsOwnMessage() public {
    uint feeAcc = subAccounts.createAccount(address(srm), IManager(address(srm)));

    vm.expectRevert(
      bytes("fee recipient is contract-owned and can never grant an allowance - use a vault-owned subaccount")
    );
    script.checkFeeRecipient(subAccounts, feeAcc, vault, address(srm));
  }

  /// @dev An account the vault owns but that sits under some other manager still cannot be used:
  ///      the module's transfers would revert in ManagerWhitelist on the fee leg.
  function testFeeRecipientUnderTheWrongManagerIsRejected() public {
    uint feeAcc = subAccounts.createAccount(vault, IManager(address(otherManager)));

    vm.expectRevert(bytes("fee recipient is not managed by the SRM"));
    script.checkFeeRecipient(subAccounts, feeAcc, vault, address(srm));
  }

  /// @dev Subaccount 0 is not an account. Unset env would otherwise read as one.
  function testZeroFeeRecipientIsRejected() public {
    vm.expectRevert(bytes("FEE_RECIPIENT_SUBACCOUNT must be set"));
    script.checkFeeRecipient(subAccounts, 0, vault, address(srm));
  }

  // -------------------------------------------------------------------------------------------
  // ownership
  //
  // BaseModule is Ownable2Step with Ownable(msg.sender), so a freshly deployed module is owned by
  // the deployer EOA. onlyOwner on this module includes setDatedFutureAsset, and
  // TradeModule._addAssetTransfers sets amtQuote = 0 for a dated future while _fillLimitOrder
  // validates only fill.price against the signed limit. An owner who flags the base asset can
  // therefore take the base leg of any resting order for zero payment, through the ordinary venue.
  // The batch must hand custody over before it allowlists anything.
  // -------------------------------------------------------------------------------------------

  /// A real Matching, because BaseModule's constructor calls _matching.subAccounts().
  function _freshModule() internal returns (TradeModule) {
    Matching matching = new Matching(subAccounts);
    return new TradeModule(IMatching(address(matching)), IAsset(address(0xcafe)), 1);
  }

  function testOwnershipOfferedToTheVaultIsAccepted() public {
    TradeModule module = _freshModule();
    module.transferOwnership(vault);
    script.checkOwnership(module, vault, address(this));
  }

  /// The default path before the fix: MATCHING_OWNER unset meant no transfer at all, and the module
  /// would have gone live still owned by the deployer.
  function testModuleWithNoOwnershipOfferIsRejected() public {
    TradeModule module = _freshModule();
    vm.expectRevert(bytes("pendingOwner is not the vault - ownership was not offered"));
    script.checkOwnership(module, vault, address(this));
  }

  function testOwnershipOfferedToTheWrongAddressIsRejected() public {
    TradeModule module = _freshModule();
    module.transferOwnership(address(0xdead));
    vm.expectRevert(bytes("pendingOwner is not the vault - ownership was not offered"));
    script.checkOwnership(module, vault, address(this));
  }

  /// Ownable2Step means the offer alone does not move owner(). If it already had, something else
  /// accepted on the vault's behalf and the deployment is not in the state the batch assumes.
  function testOwnershipAlreadyTransferredIsRejected() public {
    TradeModule module = _freshModule();
    module.transferOwnership(vault);
    vm.prank(vault);
    module.acceptOwnership();
    vm.expectRevert(bytes("pendingOwner is not the vault - ownership was not offered"));
    script.checkOwnership(module, vault, address(this));
  }
}
