// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SubAccounts} from "../../src/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {CashAsset} from "../../src/assets/CashAsset.sol";
import {MarginEngine} from "../../src/risk-managers/MarginEngine.sol";
import {IAsset} from "../../src/interfaces/IAsset.sol";
import {IManager} from "../../src/interfaces/IManager.sol";
import {IFutureAssetV3} from "../../src/interfaces/IFutureAssetV3.sol";

/**
 * Phase 0 of the on-chain FIFO book scope (docs/onchain-fifo-book-scope.md): what settling a take's fills costs on
 * the live MarginEngine v2, as one batch per counterparty (OnchainBook._settle today) against one batch for the
 * whole take. A FIFO book multiplies counterparties per take, so this decides its counterparty cap, and whether
 * batching or an engine change is the lever.
 *
 * Each case is its own test so every account starts cold, as in a real take. The test contract owns the taker and
 * the makers (an owner moves its own accounts with no allowance), so nothing but SubAccounts, the engine, the future
 * and the cash is exercised. Each maker sells the taker one cNGN-30NOV26 contract at the index, the taker paying the
 * 15 bps fee to account 22, as a take does. Gas is logged; read it with -vv. Requires BASE_RPC_URL.
 */
contract SettlementBatchGasFork is Test {
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  IFutureAssetV3 constant FUTURE = IFutureAssetV3(0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75);
  uint96 constant SUB_ID = 1796047200; // cNGN-30NOV26
  MarginEngine constant ENGINE = MarginEngine(0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950);
  CashAsset constant CASH = CashAsset(0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272);
  uint constant FEE_ACCOUNT = 22;
  uint constant CONTRACT = 1e18;

  /// @dev Pinned (CLAUDE.md): 2026-11-19 ~05:40 UTC, cNGN-30NOV26 trading on MarginEngine v2.
  uint constant FORK_BLOCK = 59_357_000;

  SubAccounts subAccounts;
  uint price;
  uint taker;
  uint[] makers;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    subAccounts = SubAccounts(address(ENGINE.subAccounts()));
    (price,) = FUTURE.indexFeed().getSpot();
    taker = _account(20_000e6);
    for (uint i; i < 8; ++i) {
      makers.push(_account(1_000e6));
    }
  }

  function _account(uint usdc) internal returns (uint acc) {
    acc = subAccounts.createAccount(address(this), IManager(address(ENGINE)));
    deal(USDC, address(this), usdc);
    IERC20Metadata(USDC).approve(address(CASH), usdc);
    CASH.deposit(acc, usdc);
  }

  function _fill(uint maker) internal view returns (ISubAccounts.AssetTransfer memory) {
    return ISubAccounts.AssetTransfer({
      fromAcc: maker,
      toAcc: taker,
      asset: IAsset(address(FUTURE)),
      subId: SUB_ID,
      amount: int(CONTRACT),
      assetData: bytes32(price)
    });
  }

  function _fee() internal view returns (ISubAccounts.AssetTransfer memory) {
    // 15 bps of one contract's notional (1,000,000 cNGN at the index)
    return ISubAccounts.AssetTransfer({
      fromAcc: taker,
      toAcc: FEE_ACCOUNT,
      asset: IAsset(address(CASH)),
      subId: 0,
      amount: int(price * 1_000_000 * 15 / 10_000),
      assetData: bytes32(0)
    });
  }

  /// One batch per counterparty, each with its fill and the taker's fee: OnchainBook._settle, N times.
  function _perCounterparty(uint n) internal returns (uint gasUsed) {
    uint start = gasleft();
    for (uint i; i < n; ++i) {
      ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](2);
      batch[0] = _fill(makers[i]);
      batch[1] = _fee();
      subAccounts.submitTransfers(batch, "");
    }
    gasUsed = start - gasleft();
    _assertSettled(n);
  }

  /// Every fill and its fee in one batch: the engine sees each account once.
  function _oneBatch(uint n) internal returns (uint gasUsed) {
    ISubAccounts.AssetTransfer[] memory batch = new ISubAccounts.AssetTransfer[](2 * n);
    for (uint i; i < n; ++i) {
      batch[2 * i] = _fill(makers[i]);
      batch[2 * i + 1] = _fee();
    }
    uint start = gasleft();
    subAccounts.submitTransfers(batch, "");
    gasUsed = start - gasleft();
    _assertSettled(n);
  }

  function _assertSettled(uint n) internal view {
    assertEq(subAccounts.getBalance(taker, IAsset(address(FUTURE)), SUB_ID), int(n * CONTRACT), "taker long n");
    for (uint i; i < n; ++i) {
      assertEq(subAccounts.getBalance(makers[i], IAsset(address(FUTURE)), SUB_ID), -int(CONTRACT), "maker short 1");
    }
  }

  function testPerCounterparty1() public {
    console.log("per-counterparty, 1 maker:", _perCounterparty(1));
  }

  function testPerCounterparty2() public {
    console.log("per-counterparty, 2 makers:", _perCounterparty(2));
  }

  function testPerCounterparty4() public {
    console.log("per-counterparty, 4 makers:", _perCounterparty(4));
  }

  function testPerCounterparty8() public {
    console.log("per-counterparty, 8 makers:", _perCounterparty(8));
  }

  function testOneBatch1() public {
    console.log("one batch, 1 maker:", _oneBatch(1));
  }

  function testOneBatch2() public {
    console.log("one batch, 2 makers:", _oneBatch(2));
  }

  function testOneBatch4() public {
    console.log("one batch, 4 makers:", _oneBatch(4));
  }

  function testOneBatch8() public {
    console.log("one batch, 8 makers:", _oneBatch(8));
  }
}
