// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {Test, Vm} from "forge-std/Test.sol";

import {Matching} from "src/Matching.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {IBaseModule} from "src/interfaces/IBaseModule.sol";
import {IDepositModule} from "src/interfaces/IDepositModule.sol";

import {SubAccounts} from "v2-core/src/SubAccounts.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManagerWhitelist} from "v2-core/src/interfaces/IManagerWhitelist.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

/**
 * @title DepositModuleFork
 *
 * @dev The deposit path an API deposit would take, against the LIVE Base deployment: the deployed
 *      DepositModule, the live Matching, the perp CashAsset and the perp SRM -- nothing redeployed.
 *      Nothing in the repo showed this module had ever been used on Base, so this is the proof that
 *      a signed deposit opens and funds a perp account before any service code is written for it.
 *
 *      The only fork-local change is registering a test trade executor (verifyAndMatch is
 *      onlyTradeExecutor); the venue's real executor is a KMS key.
 *
 *      Pinned to a block: these describe the deployment as it stood, not whatever head is.
 *      Requires BASE_RPC_URL (archive); skipped without it.
 */
contract DepositModuleForkTest is Test {
  uint constant FORK_BLOCK = 52_386_000;

  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;
  /// The retired spot SRM: a real manager, just not the perp's.
  address constant OLD_SRM = 0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b;

  Matching matching;
  SubAccounts subAccounts;
  IMatchingModule depositModule;
  address perpCash;
  address perpSrm;
  address cngnEscrow;

  uint userPk = uint(keccak256("numo.deposit-module.fork.user"));
  uint otherPk = uint(keccak256("numo.deposit-module.fork.other"));
  address user;
  address other;
  address executor = address(0xE1EC);
  uint nonce = 1;

  function setUp() public {
    string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc, FORK_BLOCK);

    string memory root = vm.projectRoot();
    string memory m = vm.readFile(string.concat(root, "/deployments/8453/matching.json"));
    string memory perp = vm.readFile(string.concat(root, "/../risk-core/deployments/8453/CNGN_PERP_STACK.json"));
    string memory col = vm.readFile(string.concat(root, "/../risk-core/deployments/8453/CNGN_PERP_COLLATERAL.json"));
    matching = Matching(vm.parseJsonAddress(m, ".matching"));
    depositModule = IMatchingModule(vm.parseJsonAddress(m, ".deposit"));
    perpCash = vm.parseJsonAddress(perp, ".cash");
    perpSrm = vm.parseJsonAddress(perp, ".srm");
    cngnEscrow = vm.parseJsonAddress(col, ".escrow");
    subAccounts = SubAccounts(address(matching.subAccounts()));

    // The context this suite relies on, asserted rather than assumed.
    assertEq(address(depositModule), 0x6540f8d9Eb599b045C05E45cb6a5B1730a806658, "deployed DepositModule");
    assertTrue(matching.allowedModules(address(depositModule)), "Matching allows the DepositModule");

    user = vm.addr(userPk);
    other = vm.addr(otherPk);
    vm.prank(VAULT);
    matching.setTradeExecutor(executor, true);
    deal(USDC, user, 10_000e6);
  }

  // ------------------------------------------------------------------------------------------ a

  function testNewAccountOpensUnderThePerpSrmOwnedByTheActionOwner() public {
    _approve(user, 1_000e6);
    uint id = _deposit(0, user, userPk, 1_000e6, perpCash, perpSrm);

    assertEq(matching.subAccountToOwner(id), user, "Matching records action.owner");
    assertEq(subAccounts.ownerOf(id), address(matching), "custodied by Matching");
    assertEq(address(subAccounts.manager(id)), perpSrm, "under the perp SRM");
    assertEq(subAccounts.getBalance(id, IAsset(perpCash), 0), int(1_000e18), "1,000 USDC of perp cash, 18dp");
    assertEq(IERC20Metadata(USDC).balanceOf(user), 9_000e6, "pulled from the owner");
  }

  // ------------------------------------------------------------------------------------------ b

  function testDepositIntoAnExistingAccount() public {
    _approve(user, 1_500e6);
    uint id = _deposit(0, user, userPk, 1_000e6, perpCash, perpSrm);
    uint again = _deposit(id, user, userPk, 500e6, perpCash, perpSrm);

    assertEq(again, id, "no new account is opened");
    assertEq(subAccounts.getBalance(id, IAsset(perpCash), 0), int(1_500e18), "topped up");
    assertEq(subAccounts.ownerOf(id), address(matching), "returned to Matching custody");
    assertEq(matching.subAccountToOwner(id), user, "owner unchanged");
  }

  // ------------------------------------------------------------------------------------------ c

  function testPermitThenDepositWithNoPriorApprove() public {
    assertEq(IERC20Metadata(USDC).allowance(user, address(depositModule)), 0, "no prior approve");
    (uint8 v, bytes32 r, bytes32 s, uint deadline) = _signPermit(userPk, user, address(depositModule), 1_000e6);

    // Anyone may submit a permit; the executor would.
    vm.prank(executor);
    IERC20Permit(USDC).permit(user, address(depositModule), 1_000e6, deadline, v, r, s);
    uint id = _deposit(0, user, userPk, 1_000e6, perpCash, perpSrm);

    assertEq(subAccounts.getBalance(id, IAsset(perpCash), 0), int(1_000e18), "funded through the permit");
    assertEq(IERC20Metadata(USDC).allowance(user, address(depositModule)), 0, "the permit is spent");
  }

  // ------------------------------------------------------------------------------------------ d

  function testRevertsWithoutEnoughAllowance() public {
    _approve(user, 999e6);
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(0, user, userPk, 1_000e6, perpCash, perpSrm);
    vm.prank(executor);
    vm.expectRevert(); // USDC's own "transfer amount exceeds allowance"
    matching.verifyAndMatch(a, sig, "");
  }

  function testRevertsOnAReplayedNonce() public {
    _approve(user, 2_000e6);
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(0, user, userPk, 1_000e6, perpCash, perpSrm);
    vm.prank(executor);
    matching.verifyAndMatch(a, sig, "");
    vm.prank(executor);
    vm.expectRevert(IBaseModule.BM_NonceAlreadyUsed.selector);
    matching.verifyAndMatch(a, sig, "");
  }

  function testRevertsOnAnExpiredAction() public {
    _approve(user, 1_000e6);
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(0, user, userPk, 1_000e6, perpCash, perpSrm);
    vm.warp(a[0].expiry + 1);
    vm.prank(executor);
    vm.expectRevert(IActionVerifier.OV_ActionExpired.selector);
    matching.verifyAndMatch(a, sig, "");
  }

  function testRevertsWhenTheSignerIsNotTheOwnerOrASessionKey() public {
    _approve(user, 1_000e6);
    // Signed by `other`, claiming `user` as owner: user's USDC would be pulled on other's say-so.
    IActionVerifier.Action[] memory a = new IActionVerifier.Action[](1);
    a[0] = _action(0, user, other, 1_000e6, perpCash, perpSrm);
    bytes[] memory sig = new bytes[](1);
    sig[0] = _sign(a[0], otherPk);
    vm.prank(executor);
    vm.expectRevert(IActionVerifier.OV_SignerNotOwnerOrSessionKeyExpired.selector);
    matching.verifyAndMatch(a, sig, "");
  }

  function testRevertsWhenTheOwnerDoesNotOwnTheExistingAccount() public {
    _approve(user, 1_000e6);
    uint id = _deposit(0, user, userPk, 1_000e6, perpCash, perpSrm);
    deal(USDC, other, 1_000e6);
    _approve(other, 1_000e6);
    // `other` signs for itself, but names user's account.
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(id, other, otherPk, 1_000e6, perpCash, perpSrm);
    vm.prank(executor);
    vm.expectRevert(IActionVerifier.OV_InvalidActionOwner.selector);
    matching.verifyAndMatch(a, sig, "");
  }

  // ------------------------------------------------------------------------------------------ e
  // What the chain itself does with a policy violation. Neither the module nor Matching checks the
  // manager or the asset; the API pins both. These record where the chain is stricter than that
  // (the manager) and where it is not (the asset, the max sentinel), so the API's job is exact.

  /// The perp CashAsset whitelists managers: a deposit into an account opened under any other
  /// manager reverts in the asset, account creation included. Safe on chain, but the API rejects it
  /// up front so the caller gets a 400, not a simulated MW_UnknownManager.
  function testCashAssetRejectsADifferentManager() public {
    _approve(user, 1_000e6);
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(0, user, userPk, 1_000e6, perpCash, OLD_SRM);
    vm.prank(executor);
    vm.expectRevert(IManagerWhitelist.MW_UnknownManager.selector);
    matching.verifyAndMatch(a, sig, "");
  }

  function testContractAcceptsADifferentWrappedAsset() public {
    deal(CNGN, user, 1_000_000e6);
    vm.prank(user);
    IERC20Metadata(CNGN).approve(address(depositModule), 1_000_000e6);
    uint id = _deposit(0, user, userPk, 1_000_000e6, cngnEscrow, perpSrm);
    assertEq(subAccounts.getBalance(id, IAsset(cngnEscrow), 0), int(1_000_000e18), "cNGN escrow credited");
  }

  function testContractTreatsMaxAmountAsTheWholeBalance() public {
    _approve(user, type(uint).max);
    uint id = _deposit(0, user, userPk, type(uint).max, perpCash, perpSrm);
    assertEq(subAccounts.getBalance(id, IAsset(perpCash), 0), int(10_000e18), "the owner's entire balance");
    assertEq(IERC20Metadata(USDC).balanceOf(user), 0, "nothing left");
  }

  // ------------------------------------------------------------------------------------- helpers

  function _approve(address who, uint amount) internal {
    vm.prank(who);
    IERC20Metadata(USDC).approve(address(depositModule), amount);
  }

  function _action(uint subaccountId, address owner, address signer, uint amount, address asset, address manager)
    internal
    returns (IActionVerifier.Action memory)
  {
    return IActionVerifier.Action({
      subaccountId: subaccountId,
      nonce: nonce++,
      module: depositModule,
      data: abi.encode(IDepositModule.DepositData({amount: amount, asset: asset, managerForNewAccount: manager})),
      expiry: block.timestamp + 1 hours,
      owner: owner,
      signer: signer
    });
  }

  function _sign(IActionVerifier.Action memory action, uint pk) internal view returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(action)));
    return abi.encodePacked(r, s, v);
  }

  function _signed(uint subaccountId, address owner, uint pk, uint amount, address asset, address manager)
    internal
    returns (IActionVerifier.Action[] memory a, bytes[] memory sig)
  {
    a = new IActionVerifier.Action[](1);
    a[0] = _action(subaccountId, owner, owner, amount, asset, manager);
    sig = new bytes[](1);
    sig[0] = _sign(a[0], pk);
  }

  /// Submits one signed deposit and returns the account it credited, read from DepositedSubAccount
  /// for a new account -- the event an API would parse.
  function _deposit(uint subaccountId, address owner, uint pk, uint amount, address asset, address manager)
    internal
    returns (uint id)
  {
    (IActionVerifier.Action[] memory a, bytes[] memory sig) = _signed(subaccountId, owner, pk, amount, asset, manager);
    vm.recordLogs();
    vm.prank(executor);
    matching.verifyAndMatch(a, sig, "");
    if (subaccountId != 0) return subaccountId;

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 topic = keccak256("DepositedSubAccount(uint256,address)");
    for (uint i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(matching) && logs[i].topics[0] == topic) {
        assertEq(address(uint160(uint(logs[i].topics[2]))), owner, "event names the owner");
        return uint(logs[i].topics[1]);
      }
    }
    revert("no DepositedSubAccount from Matching");
  }

  function _signPermit(uint pk, address owner, address spender, uint value)
    internal
    view
    returns (uint8 v, bytes32 r, bytes32 s, uint deadline)
  {
    deadline = block.timestamp + 1 hours;
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        owner,
        spender,
        value,
        IERC20Permit(USDC).nonces(owner),
        deadline
      )
    );
    (v, r, s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(IERC20Permit(USDC).DOMAIN_SEPARATOR(), structHash));
  }
}
