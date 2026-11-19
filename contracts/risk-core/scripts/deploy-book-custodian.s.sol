// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {BookCustodian} from "../src/periphery/BookCustodian.sol";

import {Utils} from "./utils.sol";

interface ICustodianDeployBook {
  function subAccounts() external view returns (ISubAccounts);
  function cash() external view returns (IAsset);
  function owner() external view returns (address);
}

interface ICustodianDeployEngine {
  function subAccounts() external view returns (ISubAccounts);
}

interface ICustodianDeployAsset {
  function subAccounts() external view returns (ISubAccounts);
  function whitelistedManager(address manager) external view returns (bool);
  function wrappedAsset() external view returns (address);
}

/**
 * @title DeployBookCustodian
 *
 * @dev Deploys BookCustodian (src/periphery/BookCustodian.sol, docs/book-custodian-spec.md), owned by the vault from
 *      the constructor: no acceptOwnership, no vault batch. The initial allowlist is set at construction (there are
 *      no accounts to protect yet); everything later goes through the 48 h queue:
 *        - Manager: MarginEngine v2 (MARGIN_ENGINE_V2.json)
 *        - Books: the EURC v2 book and the cNGN book (ONCHAIN_BOOK_V2.json, ONCHAIN_BOOK_CNGN.json)
 *        - Deposit assets: cash (USDC) and the EURC asset (EURC_SPOT.json escrow), each whitelisted on engine v2
 *      No modules and no key modules. Nothing uses the custodian until the services and app do.
 *
 * Usage:
 *   PRIVATE_KEY=<deployer> forge script scripts/deploy-book-custodian.s.sol --rpc-url $BASE_RPC_URL --broadcast
 */
contract DeployBookCustodian is Utils {
  string internal constant ARTIFACT_NAME = "BOOK_CUSTODIAN";

  /// @dev The vault recorded in DEPLOYED_ADDRESSES.md: an anchor the chain is checked against, never adopted.
  address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

  address internal subAccounts;
  address internal cash;
  address internal engine;
  address[] internal books;
  address[] internal assets;
  address internal deployer;

  function run() external {
    loadAndCheck();
    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    deployer = vm.addr(deployerPrivateKey);
    uint deployerNonce = vm.getNonce(deployer);
    vm.startBroadcast(deployerPrivateKey);
    BookCustodian custodian = deploy();
    vm.stopBroadcast();
    assertDeployment(custodian);
    _writeArtifact(custodian, deployerNonce);
  }

  function loadAndCheck() public {
    engine = vm.parseJsonAddress(_readDeploymentFile("MARGIN_ENGINE_V2"), ".manager");
    cash = vm.parseJsonAddress(_readDeploymentFile("MARGIN_ENGINE_V2"), ".cash");
    delete books;
    books.push(vm.parseJsonAddress(_readDeploymentFile("ONCHAIN_BOOK_V2"), ".book"));
    books.push(vm.parseJsonAddress(_readDeploymentFile("ONCHAIN_BOOK_CNGN"), ".book"));
    delete assets;
    assets.push(cash);
    assets.push(vm.parseJsonAddress(_readDeploymentFile("EURC_SPOT"), ".escrow"));
    subAccounts = address(ICustodianDeployEngine(engine).subAccounts());

    if (engine.code.length == 0) revert("engine has no code - wrong chain?");
    for (uint i; i < books.length; ++i) {
      if (books[i].code.length == 0) revert("a book has no code");
      if (address(ICustodianDeployBook(books[i]).subAccounts()) != subAccounts) {
        revert("a book is on other SubAccounts");
      }
      if (address(ICustodianDeployBook(books[i]).cash()) != cash) revert("a book charges fees in another cash");
      if (ICustodianDeployBook(books[i]).owner() != EXPECTED_VAULT) revert("a book is not owned by the vault");
    }
    for (uint i; i < assets.length; ++i) {
      if (address(ICustodianDeployAsset(assets[i]).subAccounts()) != subAccounts) {
        revert("an asset is on other SubAccounts");
      }
      if (!ICustodianDeployAsset(assets[i]).whitelistedManager(engine)) {
        revert("an asset is not whitelisted on engine v2");
      }
      if (ICustodianDeployAsset(assets[i]).wrappedAsset() == address(0)) revert("an asset wraps nothing");
    }
  }

  /// @dev The deploy itself. Public so the fork test runs this exact sequence.
  function deploy() public returns (BookCustodian custodian) {
    (BookCustodian.Kind[] memory kinds, address[] memory targets) = initialAllowlist();
    custodian = new BookCustodian(ISubAccounts(subAccounts), IAsset(cash), EXPECTED_VAULT, kinds, targets);
  }

  function initialAllowlist() public view returns (BookCustodian.Kind[] memory kinds, address[] memory targets) {
    uint n = 1 + books.length + assets.length;
    kinds = new BookCustodian.Kind[](n);
    targets = new address[](n);
    (kinds[0], targets[0]) = (BookCustodian.Kind.Manager, engine);
    for (uint i; i < books.length; ++i) {
      (kinds[1 + i], targets[1 + i]) = (BookCustodian.Kind.Book, books[i]);
    }
    for (uint i; i < assets.length; ++i) {
      (kinds[1 + books.length + i], targets[1 + books.length + i]) = (BookCustodian.Kind.Asset, assets[i]);
    }
  }

  function assertDeployment(BookCustodian c) public view {
    if (address(c.subAccounts()) != subAccounts) revert("subAccounts mismatch");
    if (address(c.cash()) != cash) revert("cash mismatch");
    if (c.owner() != EXPECTED_VAULT) revert("owner is not the vault");
    if (c.pendingOwner() != address(0)) revert("a pending owner is set");
    if (c.paused()) revert("paused at deploy");
    if (!c.allowed(BookCustodian.Kind.Manager, engine)) revert("engine not allowed");
    for (uint i; i < books.length; ++i) {
      if (!c.allowed(BookCustodian.Kind.Book, books[i])) revert("a book is not allowed");
      if (c.allowed(BookCustodian.Kind.Module, books[i]) || c.allowed(BookCustodian.Kind.KeyModule, books[i])) {
        revert("a book is allowed as a module");
      }
    }
    for (uint i; i < assets.length; ++i) {
      if (!c.allowed(BookCustodian.Kind.Asset, assets[i])) revert("an asset is not allowed");
    }
    if (c.DELAY() != 48 hours || c.GRACE() != 7 days) revert("timelock constants");
  }

  function _writeArtifact(BookCustodian c, uint deployerNonce) internal {
    string memory k = "book-custodian";
    vm.serializeAddress(k, "custodian", address(c));
    vm.serializeAddress(k, "subAccounts", subAccounts);
    vm.serializeAddress(k, "cash", cash);
    vm.serializeAddress(k, "owner", EXPECTED_VAULT);
    vm.serializeAddress(k, "engine", engine);
    vm.serializeAddress(k, "books", books);
    vm.serializeAddress(k, "assets", assets);
    vm.serializeAddress(k, "deployer", deployer);
    vm.serializeUint(k, "deployerNonce", deployerNonce);
    string memory out = vm.serializeUint(k, "deployBlock", block.number);
    _writeToDeployments(ARTIFACT_NAME, out);
  }
}
