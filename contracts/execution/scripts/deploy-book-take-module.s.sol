// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";

import {Matching} from "../src/Matching.sol";
import {BookTakeModule} from "../src/modules/BookTakeModule.sol";
import {IOnchainBookTake} from "../src/interfaces/IBookTakeModule.sol";
import {IMatching} from "../src/interfaces/IMatching.sol";
import {Utils} from "./utils.sol";

interface IBookSubAccounts {
    function subAccounts() external view returns (ISubAccounts);
}

/**
 * @title DeployBookTakeModule
 *
 * @dev Deploys BookTakeModule (src/modules/BookTakeModule.sol): a signed take on risk-core's OnchainBook for an
 *      account Matching holds, submitted by the venue's executor. It allows the two live books (risk-core
 *      deployments ONCHAIN_BOOK_V2.json for EURC-30NOV26, ONCHAIN_BOOK_CNGN.json for cNGN-30NOV26), which approves
 *      each on SubAccounts for the accounts the module holds during a take, then offers ownership to the vault.
 *
 *      The module is INERT until the vault runs the emitted batch: Matching refuses an action naming a module it
 *      has not allowed. Action 0 takes custody (acceptOwnership: setBookAllowed is onlyOwner, and a book it allows
 *      can move positions and cash in every account the module holds during a take); action 1 is the switch.
 *
 * Usage:
 *   PRIVATE_KEY=<deployer> forge script scripts/deploy-book-take-module.s.sol --rpc-url $BASE_RPC_URL --broadcast
 */
contract DeployBookTakeModule is Utils {
    string internal constant ARTIFACT_NAME = "BOOK_TAKE_MODULE";
    string internal constant VAULT_ACTIONS_NAME = "BOOK_TAKE_MODULE_VAULT_ACTIONS";

    /// @dev The vault recorded in risk-core/DEPLOYED_ADDRESSES.md: an anchor the chain is checked against, never adopted.
    address internal constant EXPECTED_VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;

    address internal matchingAddr;
    address internal vault;
    address internal deployer;
    address[] internal books;

    function run() external {
        _loadAddresses();
        _assertPreconditions();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);
        BookTakeModule module = deploy();
        vm.stopBroadcast();

        assertDeployment(module, deployer);
        _writeArtifacts(module);
    }

    /// @dev The deploy itself: the module, both books allowed, ownership offered to the vault. Public so the fork test
    ///      runs this exact sequence.
    function deploy() public returns (BookTakeModule module) {
        module = new BookTakeModule(IMatching(matchingAddr));
        for (uint256 i; i < books.length; ++i) {
            module.setBookAllowed(books[i], true);
        }
        module.transferOwnership(vault);
    }

    function loadAndCheck() public {
        _loadAddresses();
        _assertPreconditions();
    }

    function _loadAddresses() internal {
        matchingAddr = vm.parseJsonAddress(_readMatchingDeploymentFile("matching"), ".matching");
        delete books;
        books.push(vm.parseJsonAddress(_readRiskCoreDeploymentFile("ONCHAIN_BOOK_V2"), ".book"));
        books.push(vm.parseJsonAddress(_readRiskCoreDeploymentFile("ONCHAIN_BOOK_CNGN"), ".book"));
    }

    function _assertPreconditions() internal {
        if (matchingAddr.code.length == 0) revert("matching has no code - wrong chain?");
        vault = Matching(matchingAddr).owner();
        if (vault != EXPECTED_VAULT) revert("matching owner is not the recorded vault - ownership changed");
        ISubAccounts subAccounts = Matching(matchingAddr).subAccounts();
        for (uint256 i; i < books.length; ++i) {
            if (books[i].code.length == 0) revert("a book has no code");
            if (IBookSubAccounts(books[i]).subAccounts() != subAccounts) {
                revert("a book is on other SubAccounts than Matching");
            }
            if (!IOnchainBookTake(books[i]).markets(1).enabled) revert("a book's market 1 is not enabled");
        }
    }

    function assertDeployment(BookTakeModule module, address expectedDeployer) public view {
        if (address(module.matching()) != matchingAddr) revert("matching mismatch");
        ISubAccounts subAccounts = Matching(matchingAddr).subAccounts();
        for (uint256 i; i < books.length; ++i) {
            if (!module.allowedBooks(books[i])) revert("a book is not allowed");
            if (!subAccounts.isApprovedForAll(address(module), books[i])) {
                revert("a book is not approved on SubAccounts");
            }
        }
        if (Matching(matchingAddr).allowedModules(address(module))) {
            revert("module is already allowed on Matching - it must be inert until the vault batch");
        }
        if (module.pendingOwner() != vault) revert("pendingOwner is not the vault - ownership was not offered");
        if (module.owner() != expectedDeployer) revert("owner is not the deployer - unexpected ownership state");
    }

    function vaultActions(BookTakeModule module) public view returns (address[] memory to, bytes[] memory data) {
        to = new address[](2);
        data = new bytes[](2);
        to[0] = address(module);
        data[0] = abi.encodeWithSignature("acceptOwnership()");
        to[1] = matchingAddr;
        data[1] = abi.encodeWithSelector(Matching.setAllowedModule.selector, address(module), true);
    }

    function _writeArtifacts(BookTakeModule module) internal {
        string memory objKey = "book-take-module";
        vm.serializeAddress(objKey, "bookTake", address(module));
        vm.serializeAddress(objKey, "matching", matchingAddr);
        vm.serializeAddress(objKey, "deployer", deployer);
        vm.serializeUint(objKey, "deployBlock", block.number);
        string memory finalObj = vm.serializeAddress(objKey, "books", books);
        _writeToDeployments(ARTIFACT_NAME, finalObj);

        (address[] memory to, bytes[] memory data) = vaultActions(module);
        string[2] memory descriptions = [
            "bookTake.acceptOwnership() [CUSTODY - before the switch: the owner allows books, and an allowed book moves positions and cash in the accounts the module holds]",
            "matching.setAllowedModule(bookTake, true) [THE ENABLING SWITCH: Matching then runs signed book takes]"
        ];
        string memory json = "[";
        for (uint256 i; i < to.length; ++i) {
            json = string.concat(
                json,
                i == 0 ? "" : ",",
                '{"description":"',
                descriptions[i],
                '","caller":"vault","to":"',
                vm.toString(to[i]),
                '","value":"0","data":"',
                vm.toString(data[i]),
                '","digest":"',
                vm.toString(keccak256(abi.encodePacked(to[i], data[i]))),
                '"}'
            );
        }
        _writeToDeployments(VAULT_ACTIONS_NAME, string.concat(json, "]"));
        console2.log("BOOK_TAKE_MODULE_ADDRESS=%s", address(module));
    }

    function _readRiskCoreDeploymentFile(string memory fileName) internal view returns (string memory) {
        return vm.readFile(
            string.concat(
                vm.projectRoot(), "/../risk-core/deployments/", vm.toString(block.chainid), "/", fileName, ".json"
            )
        );
    }
}
