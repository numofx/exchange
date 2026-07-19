// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {ForkBase} from "test/ForkBase.t.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import "forge-std/console.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {RfqModule} from "src/modules/RfqModule.sol";
import {Matching} from "src/Matching.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";
import {DeliverableFXFutureAsset} from "v2-core/src/assets/DeliverableFXFutureAsset.sol";
import {DeliverableFXManager} from "v2-core/src/risk-managers/DeliverableFXManager.sol";
import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {ICashAsset} from "v2-core/src/interfaces/ICashAsset.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

interface Ownable {
  function owner() external view returns (address);
}

interface IManagerWhitelistSettable {
  function setWhitelistManager(address manager, bool whitelisted) external;
}

contract DatedFutureForkTest is ForkBase {
  TradeModule public tradeModule;
  RfqModule public rfqModule;
  Matching public matching;

  ISubAccounts public subAccounts;
  ICashAsset public cash;

  DeliverableFXFutureAsset public fxFuture;
  DeliverableFXManager public fxManager;
  WrappedERC20Asset public usdcDeliveryAsset;
  WrappedERC20Asset public cngnAsset;

  address public usdc;
  address public cngn;

  uint96 public fxSeries;

  uint internal fxTakerAcc;
  uint internal fxMakerAcc;

  address internal cam;
  uint internal camPk;
  address internal doug;
  uint internal dougPk;

  bytes32 internal domainSeparator;

  function setUp() public {
    // 1. Only execute when on active fork
    if (block.chainid == 31337) {
      vm.skip(true);
      return;
    }

    // 2. Load Base mainnet configuration dynamically from exchange-core deployments.
    //    Targets the redeployed USDC-denominated SEP-16-2026 stack: base = USDC, quote = cNGN.
    string memory futureFile = _readV2CoreDeploymentFile("CNGN_SEP16_2026_FUTURE");
    string memory coreFile = _readV2CoreDeploymentFile("core");
    string memory sharedFile = _readV2CoreDeploymentFile("shared");

    // Load core contracts
    subAccounts = ISubAccounts(_getContract(coreFile, "subAccounts"));
    cash = ICashAsset(_getContract(coreFile, "cash"));

    // Load future components
    fxFuture = DeliverableFXFutureAsset(_getContract(futureFile, "CNGN_SEP16_2026_FUTURE_ASSET_ADDRESS"));
    fxManager = DeliverableFXManager(_getContract(futureFile, "manager"));
    usdcDeliveryAsset = WrappedERC20Asset(_getContract(futureFile, "baseAsset")); // base leg = wrapped USDC
    cngnAsset = WrappedERC20Asset(_getContract(futureFile, "quoteAsset")); // quote leg = wrapped cNGN

    fxSeries = uint96(_getV2CoreUint("CNGN_SEP16_2026_FUTURE", "expiry"));

    usdc = _getContract(sharedFile, "usdc");
    cngn = _getContract(sharedFile, "cngn");

    // 2.4 Etch usdcDeliveryAsset and cngnAsset to ensure storage layout consistency on fork
    WrappedERC20Asset tempUSDCAsset = new WrappedERC20Asset(subAccounts, IERC20Metadata(usdc));
    vm.etch(address(usdcDeliveryAsset), address(tempUSDCAsset).code);

    WrappedERC20Asset tempCNGNAsset = new WrappedERC20Asset(subAccounts, IERC20Metadata(cngn));
    vm.etch(address(cngnAsset), address(tempCNGNAsset).code);

    // 2.6 Whitelist fxManager in usdcDeliveryAsset and cngnAsset to allow deposits
    address quoteAssetOwner = Ownable(address(usdcDeliveryAsset)).owner();
    vm.prank(quoteAssetOwner);
    IManagerWhitelistSettable(address(usdcDeliveryAsset)).setWhitelistManager(address(fxManager), true);

    address baseAssetOwner = Ownable(address(cngnAsset)).owner();
    vm.prank(baseAssetOwner);
    IManagerWhitelistSettable(address(cngnAsset)).setWhitelistManager(address(fxManager), true);

    // Load matching contracts
    tradeModule = TradeModule(_getMatchingContract("matching", "trade"));
    rfqModule = RfqModule(_getMatchingContract("matching", "rfq"));
    matching = Matching(_getMatchingContract("matching", "matching"));

    // 2.5 Etch our new bytecode onto mainnet addresses to simulate the upgrade in fork!
    IAsset quoteAsset = tradeModule.quoteAsset();
    uint feeRecipient = tradeModule.feeRecipient();

    TradeModule tempTradeModule = new TradeModule(matching, quoteAsset, feeRecipient);
    vm.etch(address(tradeModule), address(tempTradeModule).code);

    RfqModule tempRfqModule = new RfqModule(matching, quoteAsset, feeRecipient);
    vm.etch(address(rfqModule), address(tempRfqModule).code);

    DeliverableFXFutureAsset tempFuture = new DeliverableFXFutureAsset(subAccounts);
    vm.etch(address(fxFuture), address(tempFuture).code);

    // 2.7 Etch MockSpotFeed onto the deployment's cNGN spot feed to bypass oracle stale
    //     data checks on fork when warping backwards
    MockSpotFeed mockFeed = new MockSpotFeed();
    vm.etch(_getContract(futureFile, "spotFeed"), address(mockFeed).code);

    domainSeparator = matching.domainSeparator();

    // 3. Grant matching executor permission to this test contract
    address matchingOwner = Ownable(address(matching)).owner();
    vm.prank(matchingOwner);
    matching.setTradeExecutor(address(this), true);

    // 4. Register future asset as dated future in matching modules
    address tradeOwner = Ownable(address(tradeModule)).owner();
    vm.prank(tradeOwner);
    tradeModule.setDatedFutureAsset(address(fxFuture), true);

    address rfqOwner = Ownable(address(rfqModule)).owner();
    vm.prank(rfqOwner);
    rfqModule.setDatedFutureAsset(address(fxFuture), true);

    // 4.5 Whitelist address(0) as a manager in cash to allow 0-amount fee transfers to 0-account
    address cashOwner = Ownable(address(cash)).owner();
    vm.prank(cashOwner);
    IManagerWhitelistSettable(address(cash)).setWhitelistManager(address(0), true);

    // 5. Setup test users and subaccounts with highly unique keys to avoid collision on fork
    camPk = 0xa1a2a3a4a5a6a7a8a9a0b1b2b3b4b5b6b7b8b9b0c1c2c3c4c5c6c7c8c9c0d1d2;
    cam = vm.addr(camPk);

    dougPk = 0xd1d2d3d4d5d6d7d8d9d0e1e2e3e4e5e6e7e8e9e0f1f2f3f4f5f6f7f8f9f0a1a2;
    doug = vm.addr(dougPk);

    fxTakerAcc = subAccounts.createAccount(cam, IManager(address(fxManager)));
    fxMakerAcc = subAccounts.createAccount(doug, IManager(address(fxManager)));

    // Create a dedicated fee recipient subaccount that uses a valid manager (fxManager)
    address feeUser = vm.addr(0xFEFEFE);
    uint fxFeeRecipientAcc = subAccounts.createAccount(feeUser, IManager(address(fxManager)));

    // 5.5 Set matching modules feeRecipient to fxFeeRecipientAcc to prevent call to address(0) reverts
    vm.prank(tradeOwner);
    tradeModule.setFeeRecipient(fxFeeRecipientAcc);

    vm.prank(rfqOwner);
    rfqModule.setFeeRecipient(fxFeeRecipientAcc);

    vm.prank(cam);
    subAccounts.approve(address(matching), fxTakerAcc);
    vm.prank(doug);
    subAccounts.approve(address(matching), fxMakerAcc);

    vm.prank(cam);
    matching.depositSubAccount(fxTakerAcc);
    vm.prank(doug);
    matching.depositSubAccount(fxMakerAcc);

    // 6. Fund subaccounts with initial margin (cash = USDC)
    deal(usdc, address(this), 1_000_000_000e6);
    IERC20Metadata(usdc).approve(address(cash), type(uint).max);
    cash.deposit(fxTakerAcc, 100_000_000e6);
    cash.deposit(fxMakerAcc, 100_000_000e6);
  }

  /**
   * @notice Validates the entire Physical Settlement at Expiry orchestration
   * Open position at T0 -> Warp to post-expiry -> Fund delivery collaterals -> Execute Delivery -> Assert swap clean routing
   */
  function testPhysicalSettlementAtExpiryFork() public checkFork {
    uint lastTradeTime = fxFuture.getSeries(fxSeries).lastTradeTime;
    vm.warp(lastTradeTime - 1 days);
    vm.store(address(cash), bytes32(uint(12)), bytes32(block.timestamp));

    ITradeModule.TradeData memory camTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1600e18,
      desiredAmount: 1e18,
      worstFee: 1e18,
      recipientId: fxTakerAcc,
      isBid: true
    });

    ITradeModule.TradeData memory dougTradeData = ITradeModule.TradeData({
      asset: address(fxFuture),
      subId: fxSeries,
      limitPrice: 1600e18,
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

    // Match trade (success: no cash changed hands at T0, positions opened)
    matching.verifyAndMatch(actions, signatures, _createMatchedTrade(fxTakerAcc, fxMakerAcc, 1e18, 1600e18, 0, 0));

    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), 1e18);
    assertEq(subAccounts.getBalance(fxMakerAcc, fxFuture, fxSeries), -1e18);

    // ----------------------------------------------------
    // STEP 2: Warp beyond Expiry and Set Settlement Price
    // ----------------------------------------------------
    uint expiry = fxFuture.getSeries(fxSeries).expiry;
    vm.warp(expiry + 1 hours);

    // Set settlement price to 1650 NGN/USDC
    address futureOwner = Ownable(address(fxFuture)).owner();
    vm.prank(futureOwner);
    fxFuture.setSettlementPrice(fxSeries, 1650e18);

    // ----------------------------------------------------
    // STEP 3: Fund Delivery Collateral in Subaccounts and Manager
    // ----------------------------------------------------
    // Delivery requirements (base = USDC, quote = cNGN under the USDC-denominated redeploy):
    // Base amount  = 1 * contractSize         = 10,000 USDC
    // Quote amount = 10,000 * 1650 settlement  = 16,500,000 cNGN
    uint baseAmount18 = 10_000e18; // USDC, 18-dec subaccount units
    uint quoteAmount18 = 16_500_000e18; // cNGN, 18-dec subaccount units

    uint usdcDecimals = IERC20Metadata(usdc).decimals();
    uint baseNativeAmount = 10_000 * (10 ** usdcDecimals); // USDC native (base leg)

    uint cngnDecimals = IERC20Metadata(cngn).decimals();
    uint quoteNativeAmount = 16_500_000 * (10 ** cngnDecimals); // cNGN native (quote leg)

    // Long (Taker) owes the quote leg: seed it with cNGN delivery collateral
    deal(cngn, address(this), quoteNativeAmount);
    IERC20Metadata(cngn).approve(address(cngnAsset), quoteNativeAmount);
    cngnAsset.deposit(fxTakerAcc, quoteNativeAmount);

    // Short (Maker) owes the base leg: seed it with USDC delivery collateral
    deal(usdc, address(this), baseNativeAmount);
    IERC20Metadata(usdc).approve(address(usdcDeliveryAsset), baseNativeAmount);
    usdcDeliveryAsset.deposit(fxMakerAcc, baseNativeAmount);

    // Seed Manager accId pool with both legs (USDC base + cNGN quote) to facilitate the swap
    uint managerAccId = fxManager.accId();
    deal(cngn, address(this), quoteNativeAmount);
    IERC20Metadata(cngn).approve(address(cngnAsset), quoteNativeAmount);
    cngnAsset.deposit(managerAccId, quoteNativeAmount);

    deal(usdc, address(this), baseNativeAmount);
    IERC20Metadata(usdc).approve(address(usdcDeliveryAsset), baseNativeAmount);
    usdcDeliveryAsset.deposit(managerAccId, baseNativeAmount);

    // ----------------------------------------------------
    // STEP 4: Trigger Physical Expiry Settlement
    // ----------------------------------------------------
    assertTrue(fxManager.canSettleDeliverableFuture(fxFuture, fxTakerAcc, fxSeries), "Buyer should be ready to settle");
    assertTrue(fxManager.canSettleDeliverableFuture(fxFuture, fxMakerAcc, fxSeries), "Seller should be ready to settle");

    fxManager.settleDeliverableFuture(fxFuture, fxTakerAcc, fxSeries);
    fxManager.settleDeliverableFuture(fxFuture, fxMakerAcc, fxSeries);

    // ----------------------------------------------------
    // STEP 5: Verification & Assertions
    // ----------------------------------------------------
    // 1. Future positions are fully closed (0)
    assertEq(subAccounts.getBalance(fxTakerAcc, fxFuture, fxSeries), 0);
    assertEq(subAccounts.getBalance(fxMakerAcc, fxFuture, fxSeries), 0);

    // 2. Swapped delivery balances route correctly in Subaccounts
    // Buyer (long) received 10,000 USDC (base) and paid 16,500,000 cNGN (quote)
    assertEq(subAccounts.getBalance(fxTakerAcc, usdcDeliveryAsset, 0), int(baseAmount18));
    assertEq(subAccounts.getBalance(fxTakerAcc, cngnAsset, 0), 0);

    // Seller (short) received 16,500,000 cNGN (quote) and paid 10,000 USDC (base)
    assertEq(subAccounts.getBalance(fxMakerAcc, cngnAsset, 0), int(quoteAmount18));
    assertEq(subAccounts.getBalance(fxMakerAcc, usdcDeliveryAsset, 0), 0);

    // 3. Marked settled in manager
    assertTrue(fxManager.accountSettled(fxTakerAcc, fxSeries));
    assertTrue(fxManager.accountSettled(fxMakerAcc, fxSeries));
  }

  // ----------------------------------------------------
  // HELPER FUNCTIONS FOR SIGNING & MATCHING
  // ----------------------------------------------------
  function _createActionAndSign(
    uint accountId,
    uint nonce,
    address module,
    bytes memory data,
    uint expiry,
    address owner,
    address signer,
    uint pk
  ) internal view returns (IActionVerifier.Action memory action, bytes memory signature) {
    action = IActionVerifier.Action({
      subaccountId: accountId,
      nonce: nonce,
      module: IMatchingModule(module),
      data: data,
      expiry: expiry,
      owner: owner,
      signer: signer
    });

    bytes32 actionHash = matching.getActionHash(action);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(domainSeparator, actionHash));
    signature = bytes.concat(r, s, bytes1(v));
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

contract MockSpotFeed {
  function getSpot() external pure returns (uint, uint) {
    return (1600e18, 1e18);
  }
}
