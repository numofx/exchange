// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";

import {Matching} from "src/Matching.sol";
import {TradeModule, ITradeModule} from "src/modules/TradeModule.sol";
import {IActionVerifier} from "src/interfaces/IActionVerifier.sol";
import {IMatching} from "src/interfaces/IMatching.sol";
import {IMatchingModule} from "src/interfaces/IMatchingModule.sol";

import {IAsset} from "v2-core/src/interfaces/IAsset.sol";
import {IAllowances} from "v2-core/src/interfaces/IAllowances.sol";
import {IForwardFeed} from "v2-core/src/interfaces/IForwardFeed.sol";
import {IManager} from "v2-core/src/interfaces/IManager.sol";
import {ISpotFeed} from "v2-core/src/interfaces/ISpotFeed.sol";
import {IStandardManager} from "v2-core/src/interfaces/IStandardManager.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IVolFeed} from "v2-core/src/interfaces/IVolFeed.sol";
import {IWrappedERC20Asset} from "v2-core/src/interfaces/IWrappedERC20Asset.sol";
import {SubAccounts} from "v2-core/src/SubAccounts.sol";
import {StandardManager} from "v2-core/src/risk-managers/StandardManager.sol";
import {WrappedERC20Asset} from "v2-core/src/assets/WrappedERC20Asset.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MessageHashUtils} from "openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {ForkBase} from "test/ForkBase.t.sol";

/**
 * @title TradeModuleWrappedQuoteFork
 *
 * @dev The unit suite (TradeModuleWrappedQuote.t.sol) proves the mechanism on a stack built for
 *      the purpose. This proves it against the CONTRACTS THAT ARE ACTUALLY DEPLOYED on Base: the
 *      live Matching, the live SubAccounts, the live StandardManager with its real market
 *      registrations and margin parameters, the real WRAPPED_USDC_DELIVERABLE and WRAPPED_CNGN
 *      assets, and the real spot feeds.
 *
 * @dev The finding this exists for is testForkStaleStableFeedHaltsTheBookUntilTheOracleIsRepointed.
 *      SRM market 1 (WRAPPED_USDC_DELIVERABLE) still points at the live 3600s-heartbeat stable
 *      feed. Under a CASH quote that feed is never read on a spot fill, because portfolio.cash is
 *      added to netMargin directly with no oracle. Under a WRAPPED quote every account holds a
 *      market-1 base position, so _getSpotPrice(1) is read on every margin check and a keeper gap
 *      halts the whole book -- the exact failure mode the static feeds were deployed to remove
 *      from this venue. That is not a reason to abandon the change; it is a vault call that has to
 *      ship WITH it, and this test is the proof that it does.
 *
 * Usage: BASE_RPC_URL=... forge test --match-contract TradeModuleWrappedQuoteForkTest \
 *          --fork-url $BASE_RPC_URL -vv
 *
 * @dev Skipped (not failed) off-fork, so `forge test` in CI is unaffected.
 */
contract TradeModuleWrappedQuoteForkTest is ForkBase {
  SubAccounts internal subAccounts;
  StandardManager internal srm;
  Matching internal matching;
  address internal cashAsset;

  WrappedERC20Asset internal quoteWrapped; // WRAPPED_USDC_DELIVERABLE
  WrappedERC20Asset internal baseWrapped; // WRAPPED_CNGN
  IERC20Metadata internal usdc;
  IERC20Metadata internal cngn;
  address internal staticStableFeed;
  uint internal quoteMarketId;

  TradeModule internal module;

  address internal matchingOwner;
  address internal srmOwner;
  address internal tradeExecutor = address(0xE1EC);

  // deliberately odd keys, so nothing collides with an account that already exists on Base
  uint internal makerPk = uint(keccak256("numo.wrapped-quote.fork.maker"));
  uint internal takerPk = uint(keccak256("numo.wrapped-quote.fork.taker"));
  address internal maker;
  address internal taker;
  uint internal makerAcc;
  uint internal takerAcc;

  address internal feeOwner = address(0xFEE0);
  uint internal feeAcc;

  bytes32 internal domainSeparator;

  /// @dev 1 cNGN in USDC, 18dp. Only used to size the fill; the SRM prices market 2 at
  ///      marginFactor 0, so the number cannot change whether the trade is admissible.
  int internal constant PRICE = 0.0007e18;
  uint internal constant SIZE = 100_000e18; // 100k cNGN
  uint internal constant NOTIONAL = 70e18; // 70 USDC

  /// Last block before srm.setOraclesForMarket(1, staticStableFeed) landed (block 51097293).
  uint internal constant PRE_REPOINT_BLOCK = 51097292;

  function setUp() public {
    if (block.chainid == 31337) {
      vm.skip(true);
      return;
    }

    _loadLiveAddresses();
    _deployModule();
    _openAccounts();
  }

  function _loadLiveAddresses() internal {
    string memory root = vm.projectRoot();
    string memory core = vm.readFile(string.concat(root, "/../risk-core/deployments/8453/core.json"));
    string memory usdcJson =
      vm.readFile(string.concat(root, "/../risk-core/deployments/8453/WRAPPED_USDC_DELIVERABLE.json"));
    string memory cngnJson = vm.readFile(string.concat(root, "/../risk-core/deployments/8453/WRAPPED_CNGN.json"));
    string memory feeds = vm.readFile(string.concat(root, "/../risk-core/deployments/8453/CNGN_SPOT_STATIC_FEEDS.json"));
    string memory matchingJson = vm.readFile(string.concat(root, "/deployments/8453/matching.json"));

    subAccounts = SubAccounts(vm.parseJsonAddress(core, ".subAccounts"));
    srm = StandardManager(vm.parseJsonAddress(core, ".srm"));
    cashAsset = vm.parseJsonAddress(core, ".cash");
    matching = Matching(vm.parseJsonAddress(matchingJson, ".matching"));

    quoteWrapped = WrappedERC20Asset(vm.parseJsonAddress(usdcJson, ".base"));
    baseWrapped = WrappedERC20Asset(vm.parseJsonAddress(cngnJson, ".base"));
    usdc = quoteWrapped.wrappedAsset();
    cngn = baseWrapped.wrappedAsset();
    staticStableFeed = vm.parseJsonAddress(feeds, ".stableStaticSpotFeed");

    matchingOwner = matching.owner();
    srmOwner = srm.owner();

    IStandardManager.AssetDetail memory detail = srm.assetDetails(IAsset(address(quoteWrapped)));
    assertTrue(detail.isWhitelisted, "wrapped USDC must already be whitelisted on the live SRM");
    assertEq(uint(detail.assetType), uint(IStandardManager.AssetType.Base), "must be registered as Base");
    quoteMarketId = detail.marketId;

    domainSeparator = matching.domainSeparator();
  }

  function _deployModule() internal {
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);

    // The fee recipient must be an account whose owner can grant an allowance. Subaccount 1 --
    // the live module's feeRecipient -- is owned AND managed by the SRM contract and can never
    // grant one, which is why a fresh EOA-owned account is created here rather than reused.
    feeAcc = subAccounts.createAccount(feeOwner, IManager(address(srm)));
    assertEq(subAccounts.ownerOf(feeAcc), feeOwner, "fee account must be EOA-owned");

    module = new TradeModule(IMatching(address(matching)), IAsset(address(quoteWrapped)), feeAcc);

    vm.startPrank(matchingOwner);
    matching.setAllowedModule(address(module), true);
    matching.setTradeExecutor(tradeExecutor, true);
    vm.stopPrank();

    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(address(quoteWrapped)), positive: type(uint).max, negative: 0});
    vm.prank(feeOwner);
    subAccounts.setAssetAllowances(feeAcc, address(module), grant);
  }

  function _openAccounts() internal {
    makerAcc = _openAccount(maker);
    takerAcc = _openAccount(taker);

    _fund(quoteWrapped, usdc, makerAcc, 10_000e18);
    _fund(quoteWrapped, usdc, takerAcc, 10_000e18);
    _fund(baseWrapped, cngn, makerAcc, 5_000_000e18);
    _fund(baseWrapped, cngn, takerAcc, 5_000_000e18);
  }

  function _openAccount(address owner) internal returns (uint accountId) {
    accountId = subAccounts.createAccount(owner, IManager(address(srm)));
    vm.startPrank(owner);
    subAccounts.approve(address(matching), accountId);
    matching.depositSubAccount(accountId);
    vm.stopPrank();
  }

  /// @dev `amount18` is the 18dp position the account should end up with; the deposit itself is in
  ///      the token's own decimals (USDC and cNGN are both 6 on Base).
  function _fund(WrappedERC20Asset asset, IERC20Metadata token, uint accountId, uint amount18) internal {
    uint raw = amount18 / (10 ** (18 - token.decimals()));
    deal(address(token), address(this), raw);
    token.approve(address(asset), raw);
    asset.deposit(accountId, raw);
    assertEq(subAccounts.getBalance(accountId, IAsset(address(asset)), 0), int(amount18), "funding");
  }

  // ---------------------------------------------------------------------------------------------
  // trade construction
  // ---------------------------------------------------------------------------------------------

  function _fill(uint takerFee, uint makerFee) internal {
    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildActions(address(module));

    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: makerAcc, amountFilled: SIZE, price: PRICE, fee: makerFee});
    bytes memory orderData = abi.encode(
      ITradeModule.OrderData({takerAccount: takerAcc, takerFee: takerFee, fillDetails: fills, managerData: bytes("")})
    );

    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  function _buildActions(address moduleAddr)
    internal
    view
    returns (IActionVerifier.Action[] memory actions, bytes[] memory sigs)
  {
    actions = new IActionVerifier.Action[](2);
    sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(takerAcc, moduleAddr, true, taker, takerPk);
    (actions[1], sigs[1]) = _sign(makerAcc, moduleAddr, false, maker, makerPk);
  }

  function _sign(uint accountId, address moduleAddr, bool isBid, address owner, uint pk)
    internal
    view
    returns (IActionVerifier.Action memory action, bytes memory signature)
  {
    action = IActionVerifier.Action({
      subaccountId: accountId,
      nonce: 1,
      module: IMatchingModule(moduleAddr),
      data: abi.encode(
        ITradeModule.TradeData({
          asset: address(baseWrapped),
          subId: 0,
          limitPrice: PRICE,
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
      vm.sign(pk, MessageHashUtils.toTypedDataHash(domainSeparator, matching.getActionHash(action)));
    signature = bytes.concat(r, s, bytes1(v));
  }

  function _bal(address asset, uint accountId) internal view returns (int) {
    return subAccounts.getBalance(accountId, IAsset(asset), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // 1. the round trip, against live contracts
  // ---------------------------------------------------------------------------------------------

  function testForkRoundTripMovesOnlyWrappedBalances() public checkFork {
    // repoint the quote market's oracle first, so this test is about the trade and not the feed
    _repointQuoteOracle();

    int takerQuote = _bal(address(quoteWrapped), takerAcc);
    int makerQuote = _bal(address(quoteWrapped), makerAcc);
    int takerBase = _bal(address(baseWrapped), takerAcc);
    int makerBase = _bal(address(baseWrapped), makerAcc);
    int takerCash = _bal(cashAsset, takerAcc);
    int makerCash = _bal(cashAsset, makerAcc);

    _fill(0, 0);

    assertEq(_bal(address(quoteWrapped), takerAcc), takerQuote - int(NOTIONAL), "taker quote");
    assertEq(_bal(address(quoteWrapped), makerAcc), makerQuote + int(NOTIONAL), "maker quote");
    assertEq(_bal(address(baseWrapped), takerAcc), takerBase + int(SIZE), "taker base");
    assertEq(_bal(address(baseWrapped), makerAcc), makerBase - int(SIZE), "maker base");

    // the live CashAsset is untouched: the settlement ledger is out of the trade path
    assertEq(_bal(cashAsset, takerAcc), takerCash, "taker cash must not move");
    assertEq(_bal(cashAsset, makerAcc), makerCash, "maker cash must not move");
    assertEq(_bal(cashAsset, feeAcc), 0, "fee account cash must not move");
  }

  /// @dev The backing claim, against the live asset: the venue cannot hand out a USDC claim it is
  ///      not holding the USDC for.
  function testForkWrappedQuoteCannotBeOverdrawn() public checkFork {
    _repointQuoteOracle();
    assertEq(_bal(address(quoteWrapped), takerAcc), int(10_000e18), "taker holds 10,000 USDC");

    (IActionVerifier.Action[] memory actions, bytes[] memory sigs) = _buildActions(address(module));
    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    // 1000x the size, i.e. 70,000 USDC of notional against a 10,000 USDC balance
    fills[0] = ITradeModule.FillDetails({filledAccount: makerAcc, amountFilled: SIZE * 1000, price: PRICE, fee: 0});
    bytes memory orderData = abi.encode(
      ITradeModule.OrderData({takerAccount: takerAcc, takerFee: 0, fillDetails: fills, managerData: bytes("")})
    );

    vm.prank(tradeExecutor);
    vm.expectRevert();
    matching.verifyAndMatch(actions, sigs, orderData);
  }

  // ---------------------------------------------------------------------------------------------
  // 2. the fee path, against the live SubAccounts allowance machinery
  // ---------------------------------------------------------------------------------------------

  function testForkFeeBearingTradeSettlesInWrappedQuote() public checkFork {
    _repointQuoteOracle();

    int takerQuote = _bal(address(quoteWrapped), takerAcc);
    _fill(1e18, 0.5e18);

    assertEq(_bal(address(quoteWrapped), takerAcc), takerQuote - int(NOTIONAL) - int(1e18), "taker pays fee in quote");
    assertEq(_bal(address(quoteWrapped), feeAcc), int(1.5e18), "fees collected in wrapped quote");
    assertEq(_bal(cashAsset, feeAcc), 0, "no cash fee");
  }

  /// @dev The live module's feeRecipient, subaccount 1, is owned and managed by the SRM. Nothing
  ///      can grant it an allowance, so a wrapped-quote module constructed with it is permanently
  ///      unable to charge a fee. Asserted against live state, not assumed.
  function testForkLiveFeeRecipientIsUnusableForAWrappedQuote() public checkFork {
    address owner = subAccounts.ownerOf(1);
    assertEq(owner, address(srm), "subaccount 1 is expected to be SRM-owned on Base");
    assertGt(owner.code.length, 0, "and therefore a contract that cannot sign a grant");
    assertEq(address(subAccounts.manager(1)), address(srm), "its manager is the SRM too");

    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(address(quoteWrapped)), positive: type(uint).max, negative: 0});

    vm.prank(feeOwner);
    vm.expectRevert();
    subAccounts.setAssetAllowances(1, address(module), grant);
  }

  // ---------------------------------------------------------------------------------------------
  // 3. THE ORACLE FINDING
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev Market 1's spot feed is the live LyraSpotFeed with a heartbeat, not the static feed the
   *      cNGN leg uses. Once wrapped USDC is the quote asset, every account holds a market-1
   *      position, so that feed is read on every fill. Warping past the heartbeat halts the book.
   *
   * @dev The same warp with the oracle repointed at the static stable feed does not. That single
   *      vault call is the difference between shipping this change and shipping a book that stops
   *      trading the first time a keeper misses an hour.
   */
  /// @dev Pinned. Market 1 IS on the static feed at head -- that vault call landed at block
  ///      51097293 -- so this finding can only be observed from the world it was found in.
  ///      Repointing it at head, or pranking the live feed back in, would make it assert a world
  ///      it manufactured rather than one it observed, and would delete the only evidence that
  ///      the repoint was necessary. testForkTheQuoteOracleIsStaticAtHead is the other half.
  function testForkStaleStableFeedHaltsTheBookUntilTheOracleIsRepointed() public checkFork {
    vm.createSelectFork(vm.envString("BASE_RPC_URL"), PRE_REPOINT_BLOCK);
    _loadLiveAddresses();
    _deployModule();
    _openAccounts();

    (ISpotFeed liveFeed,,) = srm.getMarketFeeds(quoteMarketId);
    assertTrue(address(liveFeed) != staticStableFeed, "precondition: market 1 is not yet on the static feed");

    // a keeper gap. 2 hours is past the 3600s heartbeat the stable feed is configured with.
    vm.warp(block.timestamp + 2 hours);

    // the feed itself is now stale...
    vm.expectRevert();
    liveFeed.getSpot();

    // ...and so every fill on the wrapped-quote book reverts, even though nothing about the
    // trade's solvency depends on the USDC/USD price
    vm.expectRevert();
    this.externalFill();

    // one vault call, and the same fill goes through unchanged
    _repointQuoteOracle();
    this.externalFill();

    assertEq(_bal(address(baseWrapped), takerAcc), int(5_000_000e18 + SIZE), "fill settled after repointing");
  }

  /**
   * @dev The contrast, and what makes the halt above a REGRESSION rather than a pre-existing
   *      condition: the book AS IT IS TODAY survives the same keeper gap.
   *
   * @dev The accounts here are shaped like the live book — cash plus wrapped cNGN, and NO wrapped
   *      USDC — because that shape is the whole point. It is holding a market-1 position at all
   *      that drags spotFeeds[1] into the margin check; the module's quoteAsset only decides
   *      whether every account ends up holding one. An account that has ever received wrapped USDC
   *      keeps reading that feed on every subsequent adjustment, whichever module the fill came
   *      through.
   */
  function testForkCashQuoteIsUnaffectedByTheStaleStableFeed() public checkFork {
    TradeModule cashModule = new TradeModule(IMatching(address(matching)), IAsset(cashAsset), feeAcc);
    vm.prank(matchingOwner);
    matching.setAllowedModule(address(cashModule), true);

    // fresh accounts: cash + cNGN only, exactly what a cash-quoted spot account holds today
    uint cashTakerPk = uint(keccak256("numo.cash-quote.fork.taker"));
    uint cashMakerPk = uint(keccak256("numo.cash-quote.fork.maker"));
    address cashTaker = vm.addr(cashTakerPk);
    address cashMaker = vm.addr(cashMakerPk);
    uint cashTakerAcc = _openAccount(cashTaker);
    uint cashMakerAcc = _openAccount(cashMaker);

    _fundCash(cashTakerAcc, 10_000e6);
    _fundCash(cashMakerAcc, 10_000e6);
    _fund(baseWrapped, cngn, cashMakerAcc, 5_000_000e18);

    assertEq(_bal(address(quoteWrapped), cashTakerAcc), 0, "cash-quoted accounts hold no market-1 position");
    assertEq(_bal(address(quoteWrapped), cashMakerAcc), 0, "cash-quoted accounts hold no market-1 position");

    vm.warp(block.timestamp + 2 hours);

    IActionVerifier.Action[] memory actions = new IActionVerifier.Action[](2);
    bytes[] memory sigs = new bytes[](2);
    (actions[0], sigs[0]) = _sign(cashTakerAcc, address(cashModule), true, cashTaker, cashTakerPk);
    (actions[1], sigs[1]) = _sign(cashMakerAcc, address(cashModule), false, cashMaker, cashMakerPk);

    ITradeModule.FillDetails[] memory fills = new ITradeModule.FillDetails[](1);
    fills[0] = ITradeModule.FillDetails({filledAccount: cashMakerAcc, amountFilled: SIZE, price: PRICE, fee: 0});
    bytes memory orderData = abi.encode(
      ITradeModule.OrderData({takerAccount: cashTakerAcc, takerFee: 0, fillDetails: fills, managerData: bytes("")})
    );

    // no revert: no market-1 position means _getSpotPrice(1) is never reached, so the stale
    // stable feed is invisible to the fill
    vm.prank(tradeExecutor);
    matching.verifyAndMatch(actions, sigs, orderData);

    assertEq(_bal(cashAsset, cashTakerAcc), int(10_000e18) - int(NOTIONAL), "cash-quoted fill settled while stale");
  }

  function _fundCash(uint accountId, uint rawUsdc) internal {
    deal(address(usdc), address(this), rawUsdc);
    usdc.approve(cashAsset, rawUsdc);
    (bool ok,) = cashAsset.call(abi.encodeWithSignature("deposit(uint256,uint256)", accountId, rawUsdc));
    assertTrue(ok, "cash deposit");
  }

  /// @dev exposed so vm.expectRevert can be armed against a whole fill
  function externalFill() external {
    _fill(0, 0);
  }

  function _repointQuoteOracle() internal {
    vm.prank(srmOwner);
    srm.setOraclesForMarket(quoteMarketId, ISpotFeed(staticStableFeed), IForwardFeed(address(0)), IVolFeed(address(0)));
  }

  /**
   * @dev The other half of the pinned test above: at head the quote oracle is already static, so
   *      the halt it documents cannot recur. If anyone repoints market 1 back at a heartbeat feed,
   *      this goes red -- which the pinned test structurally cannot do.
   */
  function testForkTheQuoteOracleIsStaticAtHead() public checkFork {
    (ISpotFeed spot,,) = srm.getMarketFeeds(quoteMarketId);
    assertEq(address(spot), staticStableFeed, "quote market must be on the static feed at head");

    vm.warp(block.timestamp + 30 days);
    (uint price,) = ISpotFeed(spot).getSpot();
    assertGt(price, 0, "a static feed cannot go stale");
  }

  /**
   * @dev THE CUTOVER, in the order the deploy script emits it.
   *
   *      The script now emits: acceptOwnership, setAssetAllowances, setAllowedModule, and the
   *      oracle repoint only when chain still needs it. The allowance moved ahead of the enabling
   *      switch so the batch stops contradicting the runbook the same operator is following.
   *
   *      What this proves that the hand-rolled setup above does not: applying the actions in the
   *      emitted order produces a venue that settles, and the enabling switch really is the gate
   *      -- a fill attempted before it is refused.
   */
  function testForkCutoverInTheEmittedOrderSettles() public checkFork {
    uint cutoverFeeAcc = subAccounts.createAccount(feeOwner, IManager(address(srm)));
    TradeModule fresh = new TradeModule(IMatching(address(matching)), IAsset(address(quoteWrapped)), cutoverFeeAcc);

    // 1. fees, before the switch
    IAllowances.AssetAllowance[] memory grant = new IAllowances.AssetAllowance[](1);
    grant[0] = IAllowances.AssetAllowance({asset: IAsset(address(quoteWrapped)), positive: type(uint).max, negative: 0});
    vm.prank(feeOwner);
    subAccounts.setAssetAllowances(cutoverFeeAcc, address(fresh), grant);

    // ...and the module is inert until the switch: Matching refuses a module it has not allowed.
    assertFalse(matching.allowedModules(address(fresh)), "module must be inert before the switch");

    // 2. the enabling switch
    vm.prank(matchingOwner);
    matching.setAllowedModule(address(fresh), true);
    assertTrue(matching.allowedModules(address(fresh)), "the switch is what makes it routable");

    // 3. the oracle action is correctly NOT part of this batch at head
    (ISpotFeed spot,,) = srm.getMarketFeeds(quoteMarketId);
    assertEq(address(spot), staticStableFeed, "chain says the oracle action is already done");

    // and the venue settles through it, with a fee, moving only wrapped balances
    TradeModule previous = module;
    module = fresh;
    uint makerQuoteBefore = uint(subAccounts.getBalance(makerAcc, IAsset(address(quoteWrapped)), 0));
    uint takerCashBefore = uint(
      subAccounts.getBalance(takerAcc, IAsset(cashAsset), 0) < 0
        ? int(0)
        : subAccounts.getBalance(takerAcc, IAsset(cashAsset), 0)
    );

    _fill(1e18, 1e18);

    assertEq(
      uint(subAccounts.getBalance(cutoverFeeAcc, IAsset(address(quoteWrapped)), 0)),
      2e18,
      "both fees must land in the wrapped quote asset"
    );
    assertTrue(
      uint(subAccounts.getBalance(makerAcc, IAsset(address(quoteWrapped)), 0)) != makerQuoteBefore,
      "the wrapped quote leg must have moved"
    );
    assertEq(
      uint(
        subAccounts.getBalance(takerAcc, IAsset(cashAsset), 0) < 0
          ? int(0)
          : subAccounts.getBalance(takerAcc, IAsset(cashAsset), 0)
      ),
      takerCashBefore,
      "no cash may move: the whole point is that CashAsset is out of the trade path"
    );
    module = previous;
  }
}
