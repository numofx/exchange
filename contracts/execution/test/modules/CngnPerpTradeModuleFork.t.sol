// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {Matching} from "src/Matching.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {IMatching} from "src/interfaces/IMatching.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {IBaseManager} from "v2-core/src/interfaces/IBaseManager.sol";
import {IBaseLyraFeed} from "v2-core/src/interfaces/IBaseLyraFeed.sol";
import {BaseLyraFeed} from "v2-core/src/feeds/BaseLyraFeed.sol";
import {SubAccounts} from "v2-core/src/SubAccounts.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {DeployCngnPerpStack} from "v2-core/scripts/deploy-cngn-perp-stack.s.sol";
import {DeployCngnPerpTradeModule} from "../../scripts/deploy-cngn-perp-trade-module.s.sol";

/**
 * @title CngnPerpTradeModuleFork
 *
 * @dev Both deploy scripts, run on a Base fork against the live Matching and SubAccounts, then both
 *      vault batches executed as the vault, then real signed orders matched through
 *      Matching.verifyAndMatch the way the matcher submits them. What this proves that the
 *      risk-core fork tests cannot: that the venue's actual order path can trade the perp.
 *
 * Requires BASE_RPC_URL; skipped without it.
 */
contract CngnPerpTradeModuleForkTest is Test {
  address constant VAULT = 0x1dcA42ab54Bd3862853A821F84B29BF65245F435;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  /// USD per NGN; 10M NGN is $7,200 of notional.
  int constant PRICE = 0.00072e18;
  uint constant SIZE = 10_000_000e18;

  uint feedSignerPk = uint(keccak256("numo.cngn-perp.fork.feed-signer"));
  uint makerPk = uint(keccak256("numo.cngn-perp.fork.maker"));
  uint takerPk = uint(keccak256("numo.cngn-perp.fork.taker"));
  address feedSigner;
  address maker;
  address taker;
  address tradeExecutor = address(0xE1EC);

  SubAccounts subAccounts;
  Matching matching;
  DeployCngnPerpStack.Stack stack;
  DeployCngnPerpTradeModule moduleScript;
  DeployCngnPerpTradeModule.Params moduleParams;
  TradeModule module;

  uint makerAcc;
  uint takerAcc;
  uint nonce;

  function setUp() public {
    string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);

    feedSigner = vm.addr(feedSignerPk);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);

    string memory root = vm.projectRoot();
    subAccounts = SubAccounts(
      vm.parseJsonAddress(vm.readFile(string.concat(root, "/../risk-core/deployments/8453/core.json")), ".subAccounts")
    );
    matching =
      Matching(vm.parseJsonAddress(vm.readFile(string.concat(root, "/deployments/8453/matching.json")), ".matching"));

    _deployStackAsVault();
    _deployModuleAsVault();

    vm.prank(VAULT);
    matching.setTradeExecutor(tradeExecutor, true);

    makerAcc = _openFundedAccount(maker, 5_000e6);
    takerAcc = _openFundedAccount(taker, 5_000e6);
  }

  // ---------------------------------------------------------------------------------------------

  function testPerpFillsThroughMatchingWithFeedsOnTheFill() public {
    // No feed has ever been published: the only prices this fill sees are the ones it carries.
    _fill(0, _feedUpdates(uint(PRICE)));

    assertEq(_bal(address(stack.perp), takerAcc), int(SIZE), "taker long");
    assertEq(_bal(address(stack.perp), makerAcc), -int(SIZE), "maker short");
    (uint index,) = stack.indexFeed.getSpot();
    assertEq(index, uint(PRICE), "the fill's managerData set the index before the transfers");
  }

  function testFeeIsCollectedInBackedCashWithoutAnAllowance() public {
    int takerCash = _bal(address(stack.cash), takerAcc);
    // 25 bps of $7,200 = $18 taker fee; the vault-owned fee account never granted anything.
    _fill(18e18, _feedUpdates(uint(PRICE)));

    assertEq(_bal(address(stack.cash), stack.feeRecipientAccount), 18e18, "fee lands in the vault's account");
    assertEq(_bal(address(stack.cash), takerAcc), takerCash - 18e18, "taker pays it in cash");
  }

  function testFillAboveMarkMovesTheDifferenceInCash() public {
    // Traded 1% over mark: the long pays the difference to the short, in the stack's cash.
    int tradePrice = PRICE * 101 / 100;
    int takerCash = _bal(address(stack.cash), takerAcc);
    int makerCash = _bal(address(stack.cash), makerAcc);

    _fillAt(tradePrice, 0, _feedUpdates(uint(PRICE)));

    int delta = (tradePrice - PRICE) * int(SIZE) / 1e18; // $72
    assertEq(_bal(address(stack.cash), takerAcc), takerCash - delta, "long pays price-vs-mark");
    assertEq(_bal(address(stack.cash), makerAcc), makerCash + delta, "short receives it");
  }

  function testUnallowlistedModuleCannotTrade() public {
    vm.prank(VAULT);
    matching.setAllowedModule(address(module), false);

    // Built before expectRevert: it makes external calls, and expectRevert binds to the first one.
    bytes memory managerData = _feedUpdates(uint(PRICE));
    nonce++;
    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](2);
    bytes[] memory sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, taker, takerPk, PRICE);
    (actions[1], sigs[1]) = _sign(makerAcc, false, maker, makerPk, PRICE);
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: makerAcc, amountFilled: SIZE, price: PRICE, fee: 0});
    bytes memory orderData = abi.encode(
      ITradeModule.OrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: managerData})
    );

    vm.prank(tradeExecutor);
    vm.expectRevert(IMatching.M_OnlyAllowedModule.selector);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  // ---------------------------------------------------------------------------------------------
  // deployment, exactly as the two scripts do it, then the two vault batches
  // ---------------------------------------------------------------------------------------------

  function _deployStackAsVault() internal {
    DeployCngnPerpStack stackScript = new DeployCngnPerpStack();
    DeployCngnPerpStack.Params memory params = DeployCngnPerpStack.Params({
      subAccounts: address(subAccounts), usdc: USDC, vault: VAULT, feedSigner: feedSigner, perpOICap: 50_000_000e18
    });
    stack = stackScript.deployStack(params);
    _runVaultBatch(stackScript.vaultActionsJson(stack), stackScript.ownedContracts(stack).length);
  }

  function _deployModuleAsVault() internal {
    moduleScript = new DeployCngnPerpTradeModule();
    moduleParams = DeployCngnPerpTradeModule.Params({
      matching: address(matching),
      subAccounts: address(subAccounts),
      cash: address(stack.cash),
      srm: address(stack.srm),
      perp: address(stack.perp),
      feeRecipientAccount: stack.feeRecipientAccount,
      vault: VAULT
    });
    moduleScript.assertPreconditions(moduleParams);
    module = moduleScript.deployModule(moduleParams);
    moduleScript.assertModule(module, moduleParams);
    _runVaultBatch(moduleScript.vaultActionsJson(module, moduleParams), 2);
    assertEq(module.owner(), VAULT, "vault owns the module");
    assertTrue(matching.allowedModules(address(module)), "module allowlisted");
  }

  function _runVaultBatch(string memory json, uint count) internal {
    for (uint i = 0; i < count; i++) {
      string memory key = string.concat("[", vm.toString(i), "]");
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      assertEq(
        vm.parseJsonBytes32(json, string.concat(key, ".digest")), keccak256(abi.encodePacked(to, keccak256(data)))
      );
      vm.prank(VAULT);
      (bool ok,) = to.call(data);
      assertTrue(ok, "vault action failed");
    }
  }

  function _openFundedAccount(address owner, uint usdcAmount) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(stack.srm)));
    deal(USDC, address(this), usdcAmount);
    IERC20Metadata(USDC).approve(address(stack.cash), usdcAmount);
    stack.cash.deposit(accountId, usdcAmount);

    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // orders
  // ---------------------------------------------------------------------------------------------

  function _fill(uint takerFee, bytes memory managerData) internal {
    _fillAt(PRICE, takerFee, managerData);
  }

  function _fillAt(int price, uint takerFee, bytes memory managerData) internal {
    nonce++;
    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](2);
    bytes[] memory sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, true, taker, takerPk, price);
    (actions[1], sigs[1]) = _sign(makerAcc, false, maker, makerPk, price);

    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: makerAcc, amountFilled: SIZE, price: price, fee: 0});
    bytes memory orderData = abi.encode(
      ITradeModule.OrderData({takerAccount: takerAcc, takerFee: takerFee, fillDetails: fills, managerData: managerData})
    );

    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _sign(uint accountId, bool isBid, address owner, uint pk, int price)
    internal
    view
    returns (IActionVerifier.Action memory action, bytes memory signature)
  {
    action = IActionVerifier.Action({
      subaccountId: accountId,
      nonce: nonce,
      module: IMatchingModule(address(module)),
      data: abi.encode(
        ITradeModule.TradeData({
          asset: address(stack.perp),
          subId: 0,
          limitPrice: price,
          desiredAmount: int(SIZE),
          worstFee: 1e18,
          recipientId: accountId,
          isBid: isBid
        })
      ),
      expiry: block.timestamp + 1 days,
      owner: owner,
      signer: owner
    });
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(pk, MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(action)));
    signature = bytes.concat(r, s, bytes1(v));
  }

  // ---------------------------------------------------------------------------------------------
  // feeds, signed as the publishers sign them
  // ---------------------------------------------------------------------------------------------

  function _feedUpdates(uint index) internal returns (bytes memory) {
    vm.warp(block.timestamp + 1);
    IBaseManager.ManagerData[] memory updates = new IBaseManager.ManagerData[](4);
    updates[0] = IBaseManager.ManagerData(
      address(stack.indexFeed), _signed(stack.indexFeed, abi.encode(uint96(index), uint64(1e18)))
    );
    updates[1] =
      IBaseManager.ManagerData(address(stack.markFeed), _signed(stack.markFeed, abi.encode(int96(0), uint64(1e18))));
    updates[2] = IBaseManager.ManagerData(
      address(stack.impactAskFeed), _signed(stack.impactAskFeed, abi.encode(int96(0), uint64(1e18)))
    );
    updates[3] = IBaseManager.ManagerData(
      address(stack.impactBidFeed), _signed(stack.impactBidFeed, abi.encode(int96(0), uint64(1e18)))
    );
    return abi.encode(updates);
  }

  function _signed(BaseLyraFeed feed, bytes memory data) internal view returns (bytes memory) {
    IBaseLyraFeed.FeedData memory feedData = IBaseLyraFeed.FeedData({
      data: data,
      timestamp: uint64(block.timestamp),
      deadline: block.timestamp + 5,
      signers: new address[](1),
      signatures: new bytes[](1)
    });
    bytes32 structHash =
      keccak256(abi.encode(feed.FEED_DATA_TYPEHASH(), keccak256(feedData.data), feedData.deadline, feedData.timestamp));
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(feedSignerPk, MessageHashUtils.toTypedDataHash(feed.domainSeparator(), structHash));
    feedData.signatures[0] = bytes.concat(r, s, bytes1(v));
    feedData.signers[0] = feedSigner;
    return abi.encode(feedData);
  }

  function _bal(address asset, uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, IAsset(asset), 0);
  }
}
