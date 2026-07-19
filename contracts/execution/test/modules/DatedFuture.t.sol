// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {MatchingBase} from "test/shared/MatchingBase.t.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import "forge-std/console.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";
import {DeliverableFXFutureAsset} from "v2-core/src/assets/DeliverableFXFutureAsset.sol";
import {DeliverableFXManager} from "v2-core/src/risk-managers/DeliverableFXManager.sol";
import {MockERC20} from "v2-core/test/shared/mocks/MockERC20.sol";
import {MockFeeds} from "v2-core/test/shared/mocks/MockFeeds.sol";
import {MockDutchAuction} from "v2-core/test/risk-managers/mocks/MockDutchAuction.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {ICashAsset} from "v2-core/src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "v2-core/src/interfaces/IDutchAuction.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";

contract DatedFutureTest is MatchingBase {
  DeliverableFXManager public fxManager;
  WrappedERC20Asset public usdcDeliveryAsset;
  WrappedERC20Asset public cngnAsset;
  DeliverableFXFutureAsset public fxFuture;
  MockFeeds public cngnFeed;
  MockERC20 public cngn;

  uint internal fxTakerAcc;
  uint internal fxMakerAcc;

  uint96 internal fxSeries;
  uint internal fxExpiry;
  uint internal fxLastTradeTime;

  uint internal constant MARK0 = 1500e18;
  uint internal constant CONTRACT_SIZE = 10_000e18;
  // absorbs the few-wei integer-division rounding in the VM blend/sync path
  uint internal constant VM_TOL = 1e9;

  /// @dev USDC (1e18) variation margin realised per contract when a position is marked
  /// between `tradePrice` and the 1500 mark, converting at the trade price. Mirrors
  /// DeliverableFXFutureAsset's USDC-denominated accrual: |tradePrice - mark| * size / tradePrice.
  function _perContractVM(uint tradePrice) internal pure returns (uint) {
    uint diff = tradePrice > MARK0 ? tradePrice - MARK0 : MARK0 - tradePrice;
    return diff * CONTRACT_SIZE / tradePrice;
  }

  function setUp() public override {
    super.setUp();

    // 1. Deploy deliverable future components using already deployed subAccounts and cash (USDC) from MatchingBase
    cngn = new MockERC20("cNGN", "cNGN");
    usdcDeliveryAsset = new WrappedERC20Asset(subAccounts, usdc); // usdc is from MatchingBase/PMRMTestBase
    cngnAsset = new WrappedERC20Asset(subAccounts, cngn);
    fxFuture = new DeliverableFXFutureAsset(subAccounts);

    fxManager = new DeliverableFXManager(
      subAccounts,
      cash, // cash mock from MatchingBase/PMRMTestBase
      auction, // auction mock from MatchingBase/PMRMTestBase
      viewer // viewer from MatchingBase/PMRMTestBase
    );

    usdcDeliveryAsset.setWhitelistManager(address(fxManager), true);
    cngnAsset.setWhitelistManager(address(fxManager), true);
    fxFuture.setWhitelistManager(address(fxManager), true);

    usdcDeliveryAsset.setTotalPositionCap(fxManager, 1e36);
    cngnAsset.setTotalPositionCap(fxManager, 1e36);
    fxFuture.setTotalPositionCap(fxManager, 1e36);

    cngnFeed = new MockFeeds();
    cngnFeed.setSpot(1500e18, 1e18); // 1500 cNGN per USDC

    fxManager.setProduct(fxFuture, usdcDeliveryAsset, cngnAsset, cngnFeed);
    fxManager.setMarginParams(0.1e18, 0.075e18);

    // 2. Set up the future series (1 contract = 10,000 USDC)
    fxExpiry = block.timestamp + 21 days;
    fxLastTradeTime = fxExpiry - 1 days;
    fxSeries = fxFuture.createSeries(
      uint64(fxExpiry),
      uint64(fxLastTradeTime),
      address(usdcDeliveryAsset),
      address(cngnAsset),
      10_000e18, // contract size
      0.001e18,
      1e18,
      1500e18 // initial mark price
    );

    // 3. Register the future asset in the matching engine as a dated future
    tradeModule.setDatedFutureAsset(address(fxFuture), true);
    rfqModule.setDatedFutureAsset(address(fxFuture), true);

    // 4. Create two new subaccounts using the fxManager
    fxTakerAcc = subAccounts.createAccount(cam, IManager(address(fxManager)));
    fxMakerAcc = subAccounts.createAccount(doug, IManager(address(fxManager)));

    // Approve matching to spend their positions
    vm.prank(cam);
    subAccounts.approve(address(matching), fxTakerAcc);
    vm.prank(doug);
    subAccounts.approve(address(matching), fxMakerAcc);

    // Deposit subaccounts into matching
    vm.prank(cam);
    matching.depositSubAccount(fxTakerAcc);
    vm.prank(doug);
    matching.depositSubAccount(fxMakerAcc);

    // Fund accounts with initial margin (cash = USDC)
    usdc.mint(address(this), 1_000_000_000e18);
    usdc.approve(address(cash), type(uint).max);
    cash.deposit(fxTakerAcc, 100_000_000e18);
    cash.deposit(fxMakerAcc, 100_000_000e18);
  }

  /**
   * @notice 1. Symmetrical Zero-Cost Test
   * Explicitly asserts that the cashAsset.balanceOf for both Maker and Taker stays exactly identical before and after a matched trade at T0.
   */
  function testSymmetricalZeroCost() public {
    // Cam (Taker) wants to buy 1 contract at 1500e18 NGN/USDC (equal to mark price)
    ITradeModule.TradeData memory camTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1500e18,
      desiredAmount: 1e18,
      worstFee: 1e18,
      recipientId: fxTakerAcc,
      isBid: true
    });

    // Doug (Maker) wants to sell 1 contract at 1500e18 NGN/USDC
    ITradeModule.TradeData memory dougTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1500e18,
      desiredAmount: 1e18,
      worstFee: 1e18,
      recipientId: fxMakerAcc,
      isBid: false
    });

    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](2);
    bytes[] memory signatures = new bytes[](2);

    (actions[0], signatures[0]) = _createActionAndSign(
      fxTakerAcc, 0, address(tradeModule), abi.encode(camTradeData), block.timestamp + 1 days, cam, cam, camPk
    );
    (actions[1], signatures[1]) = _createActionAndSign(
      fxMakerAcc, 0, address(tradeModule), abi.encode(dougTradeData), block.timestamp + 1 days, doug, doug, dougPk
    );

    // Record cash balances before trade
    int camCashBefore = subAccounts.getBalance(fxTakerAcc, cash, 0);
    int dougCashBefore = subAccounts.getBalance(fxMakerAcc, cash, 0);

    // Execute trade match
    bytes memory encodedAction = _createMatchedTrade(fxTakerAcc, fxMakerAcc, 1e18, 1500e18, 0, 0);
    _verifyAndMatch(actions, signatures, encodedAction);

    // Record cash balances after trade
    int camCashAfter = subAccounts.getBalance(fxTakerAcc, cash, 0);
    int dougCashAfter = subAccounts.getBalance(fxMakerAcc, cash, 0);

    // ASSERT: Symmetrical Zero-Cost at T_0 (No USDC cash changed hands)
    assertEq(camCashAfter, camCashBefore);
    assertEq(dougCashAfter, dougCashBefore);

    // ASSERT: Position was successfully opened
    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), 1e18);
    assertEq(subAccounts.getBalance(fxMakerAcc, fxFuture, fxSeries), -1e18);
  }

  /**
   * @notice 2. Slippage and Fast Execution Tests
   * Validate multiple dated future trades hit the order book at different prices within the same block (P_0A, P_0B, P_0C).
   * Ensure position-weighted average accountLastCumulativeVM scales monotonically without truncation or precision issues.
   */
  function testSlippageAndFastExecution() public {
    // We will match 3 consecutive trades in the same block for the Taker:
    // Trade A: Buy 1 contract at 1550e18
    // Trade B: Buy 2 contracts at 1600e18
    // Trade C: Buy 3 contracts at 1650e18

    // Record cash balances before trade
    int camCashBefore = subAccounts.getBalance(fxTakerAcc, cash, 0);
    int dougCashBefore = subAccounts.getBalance(fxMakerAcc, cash, 0);

    // Trade A
    {
      ITradeModule.TradeData memory camDataA = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1550e18,
        desiredAmount: 1e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: true
      });
      ITradeModule.TradeData memory dougDataA = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1550e18,
        desiredAmount: 1e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: false
      });

      IActionVerifier.Action[] memory actionsA = new IActionVerifier.Action[](2);
      bytes[] memory signaturesA = new bytes[](2);
      (actionsA[0], signaturesA[0]) = _createActionAndSign(
        fxTakerAcc, 0, address(tradeModule), abi.encode(camDataA), block.timestamp + 1 days, cam, cam, camPk
      );
      (actionsA[1], signaturesA[1]) = _createActionAndSign(
        fxMakerAcc, 0, address(tradeModule), abi.encode(dougDataA), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actionsA, signaturesA, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 1e18, 1550e18, 0, 0));
    }

    // Trade B
    {
      ITradeModule.TradeData memory camDataB = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1600e18,
        desiredAmount: 2e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: true
      });
      ITradeModule.TradeData memory dougDataB = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1600e18,
        desiredAmount: 2e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: false
      });

      IActionVerifier.Action[] memory actionsB = new IActionVerifier.Action[](2);
      bytes[] memory signaturesB = new bytes[](2);
      (actionsB[0], signaturesB[0]) = _createActionAndSign(
        fxTakerAcc, 1, address(tradeModule), abi.encode(camDataB), block.timestamp + 1 days, cam, cam, camPk
      );
      (actionsB[1], signaturesB[1]) = _createActionAndSign(
        fxMakerAcc, 1, address(tradeModule), abi.encode(dougDataB), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actionsB, signaturesB, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 2e18, 1600e18, 0, 0));
    }

    // Trade C
    {
      ITradeModule.TradeData memory camDataC = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1650e18,
        desiredAmount: 3e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: true
      });
      ITradeModule.TradeData memory dougDataC = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1650e18,
        desiredAmount: 3e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: false
      });

      IActionVerifier.Action[] memory actionsC = new IActionVerifier.Action[](2);
      bytes[] memory signaturesC = new bytes[](2);
      (actionsC[0], signaturesC[0]) = _createActionAndSign(
        fxTakerAcc, 2, address(tradeModule), abi.encode(camDataC), block.timestamp + 1 days, cam, cam, camPk
      );
      (actionsC[1], signaturesC[1]) = _createActionAndSign(
        fxMakerAcc, 2, address(tradeModule), abi.encode(dougDataC), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actionsC, signaturesC, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 3e18, 1650e18, 0, 0));
    }

    // Record cash balances after trades
    int camCashAfter = subAccounts.getBalance(fxTakerAcc, cash, 0);
    int dougCashAfter = subAccounts.getBalance(fxMakerAcc, cash, 0);

    // ASSERT: VM is denominated in USDC by converting each lot at its own trade price.
    // Taker bought 1@1550, 2@1600, 3@1650, all above the 1500 mark, so each lot loses
    //   amount * (price - 1500) * size / price:
    //   1*(1550-1500)*S/1550 + 2*(1600-1500)*S/1600 + 3*(1650-1500)*S/1650
    //   ~= 322.58 + 1250 + 2727.27 ~= 4299.85 USDC (not the raw 7,000,000 cNGN-notional).
    int takerLoss = int(1 * _perContractVM(1550e18) + 2 * _perContractVM(1600e18) + 3 * _perContractVM(1650e18));
    assertApproxEqAbs(camCashAfter, camCashBefore - takerLoss, VM_TOL);
    assertApproxEqAbs(dougCashAfter, dougCashBefore + takerLoss, VM_TOL);

    // Positions must be exact
    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), 6e18);
    assertEq(subAccounts.getBalance(fxMakerAcc, fxFuture, fxSeries), -6e18);

    // accountLastCumulativeVM is synchronized to 0 at end of tx
    assertEq(fxFuture.accountLastCumulativeVM(fxTakerAcc, fxSeries), 0);
  }

  /**
   * @notice 4. Partial Reduction and Reversal VM Realization Test
   * Open long position -> Partially reduce it -> Reverse to short -> Verify VM is realized perfectly at each step
   */
  function testPartialReductionAndReversal() public {
    int camCashStart = subAccounts.getBalance(fxTakerAcc, cash, 0);

    // Step 1: Open long position of 10 contracts at 1600e18
    {
      ITradeModule.TradeData memory camData1 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1600e18,
        desiredAmount: 10e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: true
      });
      ITradeModule.TradeData memory dougData1 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1600e18,
        desiredAmount: 10e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: false
      });

      IActionVerifier.Action[] memory actions1 = new IActionVerifier.Action[](2);
      bytes[] memory signatures1 = new bytes[](2);
      (actions1[0], signatures1[0]) = _createActionAndSign(
        fxTakerAcc, 0, address(tradeModule), abi.encode(camData1), block.timestamp + 1 days, cam, cam, camPk
      );
      (actions1[1], signatures1[1]) = _createActionAndSign(
        fxMakerAcc, 0, address(tradeModule), abi.encode(dougData1), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actions1, signatures1, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 10e18, 1600e18, 0, 0));
    }

    // After Step 1: Taker bought 10 contracts at 1600 (mark = 1500), converting at 1600.
    // Taker loss = 10 * (1600 - 1500) * S / 1600 = 6,250 USDC.
    int camCashStep1 = subAccounts.getBalance(fxTakerAcc, cash, 0);
    assertApproxEqAbs(camCashStep1, camCashStart - int(10 * _perContractVM(1600e18)), VM_TOL);

    // Step 2: Partially reduce position by selling 4 contracts at 1700e18 (leaving +6 contracts)
    {
      ITradeModule.TradeData memory camData2 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1700e18,
        desiredAmount: 4e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: false
      });
      ITradeModule.TradeData memory dougData2 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1700e18,
        desiredAmount: 4e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: true
      });

      IActionVerifier.Action[] memory actions2 = new IActionVerifier.Action[](2);
      bytes[] memory signatures2 = new bytes[](2);
      (actions2[0], signatures2[0]) = _createActionAndSign(
        fxTakerAcc, 1, address(tradeModule), abi.encode(camData2), block.timestamp + 1 days, cam, cam, camPk
      );
      (actions2[1], signatures2[1]) = _createActionAndSign(
        fxMakerAcc, 1, address(tradeModule), abi.encode(dougData2), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actions2, signatures2, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 4e18, 1700e18, 0, 0));
    }

    // After Step 2: Cam sold 4 contracts at 1700 (above the 1500 mark), realising USDC VM of
    // +4 * (1700 - 1500) * S / 1700 ~= +4,705.88 USDC on the reduced lot.
    // Net vs start = -6,250 + 4,705.88 ~= -1,544.12 USDC.
    int camCashStep2 = subAccounts.getBalance(fxTakerAcc, cash, 0);
    assertApproxEqAbs(
      camCashStep2, camCashStart - int(10 * _perContractVM(1600e18)) + int(4 * _perContractVM(1700e18)), VM_TOL
    );
    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), 6e18);

    // Step 3: Reverse position by selling 10 contracts at 1800e18 (leaving -4 contracts short)
    {
      ITradeModule.TradeData memory camData3 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1800e18,
        desiredAmount: 10e18,
        worstFee: 1e18,
        recipientId: fxTakerAcc,
        isBid: false
      });
      ITradeModule.TradeData memory dougData3 = ITradeModule.TradeData({
        asset: address(fxFuture),
        subId: fxSeries,
        limitPrice: 1800e18,
        desiredAmount: 10e18,
        worstFee: 1e18,
        recipientId: fxMakerAcc,
        isBid: true
      });

      IActionVerifier.Action[] memory actions3 = new IActionVerifier.Action[](2);
      bytes[] memory signatures3 = new bytes[](2);
      (actions3[0], signatures3[0]) = _createActionAndSign(
        fxTakerAcc, 2, address(tradeModule), abi.encode(camData3), block.timestamp + 1 days, cam, cam, camPk
      );
      (actions3[1], signatures3[1]) = _createActionAndSign(
        fxMakerAcc, 2, address(tradeModule), abi.encode(dougData3), block.timestamp + 1 days, doug, doug, dougPk
      );
      _verifyAndMatch(actions3, signatures3, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 10e18, 1800e18, 0, 0));
    }

    // After Step 3: sold 10 @1800, closing the remaining 6 longs and opening 4 shorts. Every
    // contract is marked at 1800 vs the 1500 mark and converted at 1800, so the step realises
    //   +10 * (1800 - 1500) * S / 1800 ~= +16,666.67 USDC.
    // Net vs start = -1,544.12 + 16,666.67 ~= +15,122.55 USDC.
    int camCashStep3 = subAccounts.getBalance(fxTakerAcc, cash, 0);
    assertApproxEqAbs(
      camCashStep3,
      camCashStart - int(10 * _perContractVM(1600e18)) + int(4 * _perContractVM(1700e18))
        + int(10 * _perContractVM(1800e18)),
      VM_TOL
    );
    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), -4e18);
  }

  /**
   * @notice 3. The "Immediate Liquidation" Check
   * Tests opening a position at markPrice, then applying a post-match price drop that immediately triggers margin failure.
   * Verify that the account immediately fails margin health checks due to the new entryVM baseline,
   * even before any VM settlements or sweeps occur.
   */
  function testImmediateLiquidationCheck() public {
    // Open a long position at the current mark price of 1500e18.
    // 10,000 contracts so the post-drop USDC VM loss exceeds the 100,000,000 USDC collateral
    // (at 10 contracts the USDC-denominated loss would be only ~200,000 USDC, not enough).
    ITradeModule.TradeData memory camTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1500e18,
      desiredAmount: 10_000e18, // 10,000 contracts
      worstFee: 1e18,
      recipientId: fxTakerAcc,
      isBid: true
    });

    ITradeModule.TradeData memory dougTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1500e18,
      desiredAmount: 10_000e18,
      worstFee: 1e18,
      recipientId: fxMakerAcc,
      isBid: false
    });

    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](2);
    bytes[] memory signatures = new bytes[](2);

    (actions[0], signatures[0]) = _createActionAndSign(
      fxTakerAcc, 0, address(tradeModule), abi.encode(camTradeData), block.timestamp + 1 days, cam, cam, camPk
    );
    (actions[1], signatures[1]) = _createActionAndSign(
      fxMakerAcc, 0, address(tradeModule), abi.encode(dougTradeData), block.timestamp + 1 days, doug, doug, dougPk
    );

    // Taker has deposited 100,000,000 USDC (100M) in setUp.
    // Execute trade match at 1500e18 (succeeds perfectly)
    _verifyAndMatch(actions, signatures, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 10_000e18, 1500e18, 0, 0));

    // Force a disastrous price drop to 500e18.
    // USDC-denominated unrealized loss = 10,000 * (1500 - 500) * 10,000 / 500 = 200,000,000 USDC,
    // which exceeds the 100,000,000 USDC collateral, so the account is insolvent.
    fxFuture.setMarkPrice(fxSeries, uint64(block.timestamp + 1), 500e18);

    // Verify taker is immediately subject to liquidation (margin <= 0)
    int margin = fxManager.getMargin(fxTakerAcc, true);
    assertTrue(margin < 0, "Taker should have negative margin immediately");
  }

  function _createMatchedTrade(
    uint takerAccount,
    uint makerAcc,
    uint amountFilled,
    int price,
    uint takerFee,
    uint makerFee
  ) internal pure returns (bytes memory) {
    ITradeModule.FillDetails memory fillDetails = ITradeModule.FillDetails({
      filledAccount: makerAcc, amountFilled: amountFilled, price: price, fee: makerFee
    });

    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = fillDetails;

    ITradeModule.OrderData memory orderData = ITradeModule.OrderData({
      takerAccount: takerAccount, takerFee: takerFee, fillDetails: fills, managerData: bytes("")
    });

    return abi.encode(orderData);
  }
}
