// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBookFork.t.sol";
import {IOnchainBook} from "../../src/interfaces/IOnchainBook.sol";
import {
  DeltaHedgedEurcVault,
  IMorphoLite,
  ICLPoolLite,
  MorphoMarketParams
} from "../../examples/DeltaHedgedEurcVault.sol";

/// @dev Morpho Blue reads collateral price x 1e36 (adjusted for decimals: both tokens have 6, so index x 1e18).
contract FixedMorphoOracle {
  uint public price;

  constructor(uint p) {
    price = p;
  }
}

interface IMorphoAdmin {
  function createMarket(MorphoMarketParams memory p) external;
  function supply(MorphoMarketParams memory p, uint assets, uint shares, address onBehalf, bytes memory data)
    external
    returns (uint, uint);
  function supplyCollateral(MorphoMarketParams memory p, uint assets, address onBehalf, bytes memory data) external;
}

/**
 * The kit's example (spec C4.4) on the live Base stack at the book fork's block: Morpho Blue's real contract (a market
 * created here, EURC collateral / USDC loan, the enabled adaptive IRM and 86% LLTV, a fixed oracle at the index), the
 * real Aerodrome Slipstream EURC/USDC pool (tick spacing 1, the deepest), and the OnchainBook on the live MarginEngine v2
 * and FutureAsset v3 with Chainlink-verified reports. One transaction: flash loan, swap, collateral, borrow, short.
 *
 * Requires BASE_RPC_URL.
 */
contract OnchainBookKitFork is OnchainBookForkBase {
  address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
  address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
  address constant ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
  address constant AERO_EURC_USDC_TS1 = 0xc5E51044eB7318950B1aFb044FccFb25782C48c1;

  DeltaHedgedEurcVault vault;
  MorphoMarketParams lending;
  address owner = address(0x0a1e);

  function setUp() public override {
    super.setUp();
    _makers(3, 5); // 3,000 lots a side: enough for the short

    lending = MorphoMarketParams({
      loanToken: USDC,
      collateralToken: EURC,
      oracle: address(new FixedMorphoOracle(index * 1e18)),
      irm: ADAPTIVE_IRM,
      lltv: 0.86e18
    });
    IMorphoAdmin(MORPHO).createMarket(lending);
    address lender = address(0x1e9d);
    deal(USDC, lender, 50_000e6);
    vm.startPrank(lender);
    IERC20Metadata(USDC).approve(MORPHO, type(uint).max);
    IMorphoAdmin(MORPHO).supply(lending, 50_000e6, 0, lender, "");
    vm.stopPrank();

    vault = new DeltaHedgedEurcVault(
      IOnchainBook(address(book)), mkt, IMorphoLite(MORPHO), lending, ICLPoolLite(AERO_EURC_USDC_TS1), owner
    );
    deal(USDC, owner, 3_000e6);
    vm.startPrank(owner);
    IERC20Metadata(USDC).approve(address(vault), type(uint).max);
    vault.depositMargin(1_000e6);
    vm.stopPrank();
  }

  function _hedge(bool shorting, bytes memory reps) internal view returns (DeltaHedgedEurcVault.Hedge memory) {
    return DeltaHedgedEurcVault.Hedge({
      limitPrice: shorting ? index * 98 / 100 : index * 102 / 100, maxFee: 100e18, reports: reps
    });
  }

  function testOneTransactionOpensADeltaNeutralLeveragedBasis() public {
    DeltaHedgedEurcVault.Open memory p = DeltaHedgedEurcVault.Open({
      equity: 1_000e6,
      borrow: 1_200e6,
      minEurc: 2_200e6 * 1e18 / index * 98 / 100, // 2% under the index
      hedge: _hedge(true, reports)
    });
    uint g = gasleft();
    vm.prank(owner);
    (uint bought, uint shortFilled) = vault.open(p);
    g -= gasleft();
    console.log("open: flash loan + Aerodrome swap + Morpho collateral and borrow + book short:", g);
    console.log("  EURC bought (6 dp):", bought);
    console.log("  short filled (position units):", shortFilled);

    assertGe(bought, p.minEurc);
    (,, uint128 collateral) = IMorphoLite(MORPHO).position(vault.lendingId(), address(vault));
    assertEq(collateral, bought, "all the EURC is collateral");
    int d = vault.delta();
    assertLt(d < 0 ? -d : d, 1e6, "delta-neutral to within one lot (1 EURC)");
    assertGe(d, 0, "the short is rounded down, never over-hedged");
    assertEq(IERC20Metadata(USDC).balanceOf(address(vault)), 0, "flash loan repaid from the borrow; nothing idle");
    assertEq(IERC20Metadata(EURC).balanceOf(address(vault)), 0);
  }

  /// Collateral added from outside (anyone may supply on the vault's behalf) puts delta back; rehedge shorts it away.
  function testRehedgeBringsDeltaBackAfterTheCollateralMoves() public {
    vm.prank(owner);
    vault.open(DeltaHedgedEurcVault.Open({equity: 1_000e6, borrow: 1_000e6, minEurc: 0, hedge: _hedge(true, reports)}));

    vm.prank(owner);
    (uint none,) = vault.rehedge(_hedge(true, ""));
    assertEq(none, 0, "already hedged: nothing to do");

    deal(EURC, address(this), 300e6);
    IERC20Metadata(EURC).approve(MORPHO, 300e6);
    IMorphoAdmin(MORPHO).supplyCollateral(lending, 300e6, address(vault), "");
    assertGt(vault.delta(), 299e6);

    vm.prank(owner);
    (uint filled,) = vault.rehedge(_hedge(true, ""));
    assertEq(filled, 300 * LOT);
    int d = vault.delta();
    assertLt(d < 0 ? -d : d, 1e6);
  }

  /// The whole transaction is one unit: a hedge the book cannot fill (limit above every bid) undoes the swap, the
  /// collateral and the loan.
  function testAnUnfillableHedgeUndoesEverything() public {
    DeltaHedgedEurcVault.Hedge memory h = _hedge(true, reports);
    h.limitPrice = index * 2;
    vm.prank(owner);
    vm.expectRevert(OnchainBook.OB_BelowMinFill.selector);
    vault.open(DeltaHedgedEurcVault.Open({equity: 1_000e6, borrow: 1_000e6, minEurc: 0, hedge: h}));
    (,, uint128 collateral) = IMorphoLite(MORPHO).position(vault.lendingId(), address(vault));
    assertEq(collateral, 0);
    assertEq(IERC20Metadata(USDC).balanceOf(owner), 2_000e6);
  }

  /// Mid-open (the flag set, as during a re-entry), only Morpho itself gets past the check. Slot 5 is `flashMode`: the
  /// Morpho-pranked call below gets past it (and fails decoding), which proves the slot.
  function testDuringOpenOnlyMorphoCanCallBack() public {
    vm.store(address(vault), bytes32(uint(5)), bytes32(uint(1)));
    vm.expectRevert(DeltaHedgedEurcVault.NotCallback.selector);
    vault.onMorphoFlashLoan(1, "");
    vm.prank(MORPHO);
    (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.onMorphoFlashLoan, (1, "")));
    assertFalse(ok);
    assertTrue(ret.length < 4 || bytes4(ret) != DeltaHedgedEurcVault.NotCallback.selector, "Morpho is past the check");
  }

  function testOnlyMorphoInsideOpenAndOnlyThePoolCanCallBack() public {
    vm.expectRevert(DeltaHedgedEurcVault.NotCallback.selector);
    vault.onMorphoFlashLoan(1, "");
    vm.prank(MORPHO);
    vm.expectRevert(DeltaHedgedEurcVault.NotCallback.selector);
    vault.onMorphoFlashLoan(1, "");
    vm.expectRevert(DeltaHedgedEurcVault.NotCallback.selector);
    vault.uniswapV3SwapCallback(0, 1, "");
    vm.expectRevert(DeltaHedgedEurcVault.NotOwner.selector);
    vault.rehedge(_hedge(true, ""));
  }
}
