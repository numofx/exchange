// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "./OnchainBook.t.sol";
import {IOnchainBook} from "../../src/interfaces/IOnchainBook.sol";

/// @dev The kit's interface (spec C4.4) is the contract's ABI: same selectors, event topics and error selectors, and a
///      caller holding only IOnchainBook gets the contract's answers.
contract OnchainBookKitTest is OnchainBookBase {
  function testSelectorsMatchTheContract() public view {
    assertEq(IOnchainBook.take.selector, book.take.selector, "take");
    assertEq(IOnchainBook.quote.selector, book.quote.selector, "quote");
    assertEq(IOnchainBook.markets.selector, book.markets.selector, "markets");
    assertEq(IOnchainBook.makers.selector, book.makers.selector, "makers");
    assertEq(IOnchainBook.splines.selector, book.splines.selector, "splines");
    assertEq(IOnchainBook.isSelfPriced.selector, book.isSelfPriced.selector, "isSelfPriced");
    assertEq(IOnchainBook.maxSelfPricedTtl.selector, book.maxSelfPricedTtl.selector, "maxSelfPricedTtl");
    assertEq(IOnchainBook.priorityTaxRate.selector, book.priorityTaxRate.selector, "priorityTaxRate");
    assertEq(IOnchainBook.subAccounts.selector, book.subAccounts.selector, "subAccounts");
    assertEq(IOnchainBook.cash.selector, book.cash.selector, "cash");
  }

  function testEventsAndErrorsMatchTheContract() public {
    assertEq(IOnchainBook.Fill.selector, OnchainBook.Fill.selector, "Fill");
    assertEq(IOnchainBook.TakeExecuted.selector, OnchainBook.TakeExecuted.selector, "TakeExecuted");
    assertEq(IOnchainBook.MakerSkipped.selector, OnchainBook.MakerSkipped.selector, "MakerSkipped");
    bytes4[10] memory i = [
      IOnchainBook.OB_InvalidMarket.selector,
      IOnchainBook.OB_MarketDisabled.selector,
      IOnchainBook.OB_TradingClosed.selector,
      IOnchainBook.OB_Expired.selector,
      IOnchainBook.OB_NotAuthorized.selector,
      IOnchainBook.OB_TakerAllowanceTooLow.selector,
      IOnchainBook.OB_FeeTooHigh.selector,
      IOnchainBook.OB_BelowMinFill.selector,
      IOnchainBook.OB_SelfTrade.selector,
      IOnchainBook.OB_GasFloor.selector
    ];
    bytes4[10] memory c = [
      OnchainBook.OB_InvalidMarket.selector,
      OnchainBook.OB_MarketDisabled.selector,
      OnchainBook.OB_TradingClosed.selector,
      OnchainBook.OB_Expired.selector,
      OnchainBook.OB_NotAuthorized.selector,
      OnchainBook.OB_TakerAllowanceTooLow.selector,
      OnchainBook.OB_FeeTooHigh.selector,
      OnchainBook.OB_BelowMinFill.selector,
      OnchainBook.OB_SelfTrade.selector,
      OnchainBook.OB_GasFloor.selector
    ];
    for (uint k; k < 10; ++k) {
      assertEq(i[k], c[k]);
    }
  }

  /// Through the interface alone: read the market, quote, take, and see the same numbers.
  function testACallerWithOnlyTheInterfaceQuotesAndTakes() public {
    IOnchainBook ib = IOnchainBook(address(book));
    IOnchainBook.MarketView memory mv = ib.markets(mkt);
    assertEq(mv.future, address(future));
    assertEq(mv.subId, subId);
    assertEq(mv.lotSize, LOT);
    assertEq(mv.tickSize, TICK);
    assertEq(mv.takerFeeRate, FEE_RATE);
    assertEq(mv.lastTradeTime, expiry - 30 minutes);
    assertTrue(mv.enabled);
    assertEq(ib.makers(mkt).length, 2);
    assertEq(ib.splines(mkt, aliceAcc).owner, alice);

    IOnchainBook.TakeOrder memory o = IOnchainBook.TakeOrder({
      marketId: mkt,
      takerAccountId: bobAcc,
      isBuy: true,
      amount: 1500 * LOT,
      limitPrice: 2e18,
      minFill: 0,
      maxFee: 1_000e18,
      deadline: uint64(block.timestamp),
      maxLevels: 20,
      selfTradeMode: IOnchainBook.SelfTradeMode.Abort,
      managerData: ""
    });
    (uint qFilled, uint qAvg, uint qFee, uint makerCount) = ib.quote(o);
    assertEq(makerCount, 2);

    vm.expectEmit(true, true, false, true, address(book));
    emit IOnchainBook.TakeExecuted(mkt, bobAcc, true, qFilled, qAvg, qFee);
    vm.prank(bob);
    (uint filled, uint avg) = ib.take(o, "");
    assertEq(filled, qFilled);
    assertEq(avg, qAvg);
  }
}
