// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

interface IActionReplay {
  struct Action {
    uint subaccountId;
    uint nonce;
    address module;
    bytes data;
    uint expiry;
    address owner;
    address signer;
  }

  function verifyAndMatch(Action[] calldata actions, bytes[] calldata signatures, bytes calldata actionData) external;
}

contract ReplayAPRFailureTest is Test {
  address internal constant MATCHING = 0x1599636347FD5bA1fBE21D58AfE0b8B9cbe283FF;
  address internal constant MODULE = 0x0AAE65AaA66Fe7f54486cDbD007956d3De611990;
  address internal constant OWNER_SIGNER = 0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310;
  address internal constant ASSET = 0xCE2846771074E20fEc739CF97a60E6075D1E464b;

  bytes4 internal constant TM_PRICE_TOO_LOW = 0xe30b762a;

  function testReplayVerifyAndMatchPayload_Reverts_TMPriceTooLow() external {
    IActionReplay.Action[] memory actions = new IActionReplay.Action[](2);
    actions[0] = IActionReplay.Action({
      subaccountId: 7,
      nonce: 1776948685656546,
      module: MODULE,
      data: hex"000000000000000000000000ce2846771074e20fec739cf97a60e6075d1e464b0000000000000000000000000000000000000000000000000000000069f29b8000000000000000000000000000000000000000000000004b6800ba2a885c000000000000000000000000000000000000000000000000000000038d7ea4c68000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000001",
      expiry: 1776952286,
      owner: OWNER_SIGNER,
      signer: OWNER_SIGNER
    });
    actions[1] = IActionReplay.Action({
      subaccountId: 6,
      nonce: 1776948685656545,
      module: MODULE,
      data: hex"000000000000000000000000ce2846771074e20fec739cf97a60e6075d1e464b0000000000000000000000000000000000000000000000000000000069f29b8000000000000000000000000000000000000000000000004b5a200376e0f8000000000000000000000000000000000000000000000000000000038d7ea4c68000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000",
      expiry: 1776952285,
      owner: OWNER_SIGNER,
      signer: OWNER_SIGNER
    });

    bytes[] memory signatures = new bytes[](2);
    signatures[0] =
      hex"a03a0a65b10a11d107d6e82a70fdf4abbc8293dbbdb6c15df668d086aeb34e0f40d0d9753cfb4af58ab2726224a646ee423f520dfdb9a8ad25d9590d2797e79a1b";
    signatures[1] =
      hex"571bd5d29fb5c51f07d9807ce3495be51d61e349428f39514be1acb58c7a84a509708300943a84ffc752d9b307c9aacb3f701665303727d675b7692d443640491b";

    bytes memory actionData =
      hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000000056e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    _logDecodedOrderShapes(actions, actionData);

    vm.expectRevert(TM_PRICE_TOO_LOW);
    vm.prank(OWNER_SIGNER);
    IActionReplay(MATCHING).verifyAndMatch(actions, signatures, actionData);
  }

  function _logDecodedOrderShapes(IActionReplay.Action[] memory actions, bytes memory actionData) internal view {
    OrderDataLocal memory orderData = abi.decode(actionData, (OrderDataLocal));

    TradeData memory taker = abi.decode(actions[0].data, (TradeData));
    TradeData memory maker = abi.decode(actions[1].data, (TradeData));

    console2.log("matching", MATCHING);
    console2.log("module", MODULE);
    console2.log("asset", ASSET);
    console2.log("taker_subaccount", actions[0].subaccountId);
    console2.log("maker_subaccount", actions[1].subaccountId);
    console2.log("owner_signer", OWNER_SIGNER);
    console2.log("taker_nonce", actions[0].nonce);
    console2.log("maker_nonce", actions[1].nonce);
    console2.log("taker_expiry", actions[0].expiry);
    console2.log("maker_expiry", actions[1].expiry);
    console2.log("taker_is_bid", taker.isBid);
    console2.log("maker_is_bid", maker.isBid);
    console2.log("taker_limit_price", uint(taker.limitPrice));
    console2.log("maker_limit_price", uint(maker.limitPrice));
    console2.log("taker_desired_amount", uint(taker.desiredAmount));
    console2.log("maker_desired_amount", uint(maker.desiredAmount));
    console2.log("fill_price", uint(orderData.fillDetails[0].price));
    console2.log("fill_amount", orderData.fillDetails[0].amountFilled);
    console2.log("taker_fee", orderData.takerFee);
    console2.log("taker_account", orderData.takerAccount);
    console2.log("manager_data_len", orderData.managerData.length);
  }
}

struct TradeData {
  address asset;
  uint subId;
  int limitPrice;
  int desiredAmount;
  uint worstFee;
  uint recipientId;
  bool isBid;
}

struct FillDetails {
  uint filledAccount;
  uint amountFilled;
  int price;
  uint fee;
}

struct OrderDataLocal {
  uint takerAccount;
  uint takerFee;
  FillDetails[] fillDetails;
  bytes managerData;
}
