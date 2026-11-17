// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import {IOnchainBook} from "../../src/interfaces/IOnchainBook.sol";
import {
  DeltaHedgedEurcVault,
  IMorphoLite,
  ICLPoolLite,
  MorphoMarketParams
} from "../../examples/DeltaHedgedEurcVault.sol";

interface IMorphoLive {
  function idToMarketParams(bytes32 id) external view returns (address, address, address, address, uint);
  function supply(MorphoMarketParams memory p, uint assets, uint shares, address onBehalf, bytes memory data)
    external
    returns (uint, uint);
}

/**
 * The kit's example against what is deployed, at head: the v2 OnchainBook (EURC-30NOV26, our self-priced maker #58),
 * the existing Morpho Blue EURC/USDC market (Chainlink EURC/USD oracle, 86% LLTV), and the Aerodrome Slipstream pool.
 * Nothing is created but the vault; no reports are attached. The mainnet run's sizes: 5 USDC equity, 5 borrowed.
 *
 * At head, so it needs a live quote and a fresh index on the book (the maker refreshes every ~25 s, the keeper posts
 * the reports). Requires BASE_RPC_URL.
 */
contract DeltaHedgedEurcVaultLiveFork is Test {
  address constant BOOK = 0x83C5741a24d57189379E1215F7A22d9f048E89d5;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
  address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
  address constant AERO_EURC_USDC_TS1 = 0xc5E51044eB7318950B1aFb044FccFb25782C48c1;
  bytes32 constant MARKET_ID = 0xa04698b2865b19f7bdabff052ec1221a1048ad76a001743fa75faabd7ef3a8b3;

  DeltaHedgedEurcVault vault;
  MorphoMarketParams lending;
  address owner = address(0x0a1e);
  uint constant START = 30e6;

  function setUp() public {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    (address loan, address coll, address oracle, address irm, uint lltv) =
      IMorphoLive(MORPHO).idToMarketParams(MARKET_ID);
    lending = MorphoMarketParams(loan, coll, oracle, irm, lltv);
    assertEq(loan, USDC);
    assertEq(coll, EURC);

    // The mainnet run supplies its own loan rather than borrow the market's few dollars from someone else.
    deal(USDC, owner, START + 10e6);
    vm.startPrank(owner);
    IERC20(USDC).approve(MORPHO, 10e6);
    IMorphoLive(MORPHO).supply(lending, 10e6, 0, owner, "");
    vm.stopPrank();

    vault = new DeltaHedgedEurcVault(
      IOnchainBook(BOOK), 1, IMorphoLite(MORPHO), lending, ICLPoolLite(AERO_EURC_USDC_TS1), owner
    );
    vm.startPrank(owner);
    IERC20(USDC).approve(address(vault), type(uint).max);
    vault.depositMargin(START - 10e6);
    vm.stopPrank();
  }

  function _hedge(bool shorting) internal pure returns (DeltaHedgedEurcVault.Hedge memory) {
    return DeltaHedgedEurcVault.Hedge({limitPrice: shorting ? 1.08e18 : 1.12e18, maxFee: 1e18, reports: ""});
  }

  function testOpenCloseAndWithdrawOnTheDeployedStack() public {
    uint g = gasleft();
    vm.prank(owner);
    (uint bought, uint shortFilled) =
      vault.open(DeltaHedgedEurcVault.Open({equity: 5e6, borrow: 5e6, minEurc: 8.8e6, hedge: _hedge(true)}));
    console.log("open gas:", g - gasleft());
    console.log("  EURC bought (6 dp):", bought);
    console.log("  short (position units):", shortFilled);
    assertGt(shortFilled, 0);
    int d = vault.delta();
    assertLt(d < 0 ? -d : d, 1e6, "delta-neutral to a lot");

    g = gasleft();
    vm.prank(owner);
    uint out = vault.close(DeltaHedgedEurcVault.Close({hedge: _hedge(false), flash: 6e6, minUsdcOut: 4e6}));
    console.log("close gas:", g - gasleft());
    console.log("  USDC back from the position:", out);

    (, uint128 borrowShares, uint128 collateral) = IMorphoLite(MORPHO).position(vault.lendingId(), address(vault));
    assertEq(borrowShares, 0, "debt repaid");
    assertEq(collateral, 0, "collateral withdrawn");
    assertEq(vault.delta(), 0);
    assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
    assertEq(IERC20(EURC).balanceOf(address(vault)), 0);

    int cashLeft = vault.subAccounts().getBalance(vault.accountId(), IOnchainBook(BOOK).cash(), 0);
    vm.prank(owner);
    vault.withdrawMargin(uint(cashLeft) / 1e12);

    uint endBal = IERC20(USDC).balanceOf(owner);
    console.log("owner USDC: start", START, "end", endBal);
    console.log("  cost (6 dp):", START - endBal);
    assertGt(endBal, START - 1e6, "the round trip costs under 1 USDC");
  }

  function testCloseRefusesALongAndOnlyTheOwnerCloses() public {
    vm.expectRevert(DeltaHedgedEurcVault.NotOwner.selector);
    vault.close(DeltaHedgedEurcVault.Close({hedge: _hedge(false), flash: 1, minUsdcOut: 0}));
    vm.expectRevert(DeltaHedgedEurcVault.NotOwner.selector);
    vault.withdrawMargin(1);
  }
}
