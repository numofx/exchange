// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {SubAccounts} from "../src/SubAccounts.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {MarginEnginePortfolioViewer} from "../src/risk-managers/MarginEnginePortfolioViewer.sol";
import {OracleDataSubmitter} from "../src/periphery/OracleDataSubmitter.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {ICashAsset} from "../src/interfaces/ICashAsset.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {IForwardFeed} from "../src/interfaces/IForwardFeed.sol";
import {IVolFeed} from "../src/interfaces/IVolFeed.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {EurcIndexFeed} from "../src/feeds/EurcIndexFeed.sol";

import {MockERC20} from "../test/shared/mocks/MockERC20.sol";
import {MockCash} from "../test/shared/mocks/MockCash.sol";
import {MockFeeds} from "../test/shared/mocks/MockFeeds.sol";
import {MockDutchAuction} from "../test/risk-managers/mocks/MockDutchAuction.sol";

import {DeployEurcFutureV3} from "./deploy-eurc-future-v3.s.sol";
import {StandInStreamsVerifier} from "./rehearsal/StandInStreamsVerifier.sol";

/**
 * @title RehearseEurcV3Sepolia
 * @notice TESTNET ONLY. The Stage 1 rehearsal of the EURC v3 series on Base Sepolia (spec A1.2), with a deliberately
 *         broken fixing recovered by a recovery window (A8). Refuses Base mainnet.
 * @dev    The series is deployed by DeployEurcFutureV3.deploy, the same code the mainnet deploy runs, with the
 *         production fixing parameters, margin (15% / 10%) and no cap. Around it, a minimal engine stack stands in for
 *         what Sepolia lacks: SubAccounts and MarginEngine v2 are real; the cash, auction and market spot feed are the
 *         unit tests' mocks; the Data Streams verifier is StandInStreamsVerifier, which accepts reports signed by
 *         REPORT_SIGNER (the keeper's DATA_STREAMS_STANDIN_KEY). There is no TradeModule: positions move by a priced
 *         transfer, which the future band-checks as it does a fill. The mainnet fork test covers the TradeModule path.
 *
 *   1. deploy:  DEPLOYER_KEY=<key> REPORT_SIGNER=<addr> FORWARD_SIGNER=<addr> STANDIN_BASE_USD=<18dp>
 *               STANDIN_QUOTE_USD=<18dp> [EXPIRY_IN=<seconds, default 5400>]
 *               forge script scripts/rehearse-eurc-v3-sepolia.s.sol --sig "rehearse()" --rpc-url <sepolia> --broadcast
 *               writes deployments/<chain>/EURC_FUTURE_V3_REHEARSAL.json; then start the keeper on it.
 *   2. trade:   once the keeper is posting reports, --sig "openPosition()": bob sells alice 10 contracts at the index.
 *   3. break:   stop the keeper for longer than maxSampleGap inside the fixing window; restart it. It opens a recovery
 *               window after expiry, samples it and settles.
 *   4. close:   after settlement, --sig "closeOut()": both close out; cash must be conserved.
 */
contract RehearseEurcV3Sepolia is DeployEurcFutureV3 {
  string internal constant REHEARSAL_NAME = "EURC_FUTURE_V3_REHEARSAL";
  uint internal constant EUR_MARKET = 2;
  /// @dev 18dp: the mock cash credits the raw amount, so the mock USDC keeps 18 decimals
  uint internal constant FUNDING_USDC = 20_000e18;
  int internal constant POSITION = 10e18;

  struct Stack {
    MockERC20 usdc;
    SubAccounts subAccounts;
    MockCash cash;
    MarginEngine engine;
    OracleDataSubmitter submitter;
    StandInStreamsVerifier verifier;
  }

  function rehearse() external {
    if (block.chainid == 8453) revert("rehearsal: never on Base mainnet");
    uint key = vm.envUint("DEPLOYER_KEY");
    uint price = vm.envUint("STANDIN_BASE_USD") * 1e18 / vm.envUint("STANDIN_QUOTE_USD");

    vm.startBroadcast(key);
    Stack memory st = _stack(price);
    Params memory params = _params(st, vm.addr(key), price);
    // the production deploy, then its setup and enable batches as the owner (no TradeModule here)
    Deployment memory d = deploy(params);
    d.future.acceptOwnership();
    d.forwardFeed.acceptOwnership();
    st.engine.whitelistAsset(d.future, EUR_MARKET, IMarginEngine.AssetType.Future);
    st.engine.setFutureMarginRequirements(EUR_MARKET, params.mmReq, params.imReq);
    d.future.setTotalPositionCap(st.engine, params.futureOICap);
    (uint alice, uint bob) = _accounts(st, vm.addr(key));
    vm.stopBroadcast();

    _record(st, d, params, alice, bob);
  }

  /// @dev What Sepolia lacks, minimal: real SubAccounts and MarginEngine v2, mocked cash, auction and spot feed.
  function _stack(uint price) internal returns (Stack memory st) {
    st.usdc = new MockERC20("USDC (rehearsal)", "USDC");
    st.subAccounts = new SubAccounts("Numo rehearsal accounts", "NUMO-R");
    st.cash = new MockCash(st.usdc, st.subAccounts);
    MarginEnginePortfolioViewer viewer = new MarginEnginePortfolioViewer(st.subAccounts, ICashAsset(address(st.cash)));
    st.engine = new MarginEngine(
      st.subAccounts, ICashAsset(address(st.cash)), IDutchAuction(address(new MockDutchAuction())), viewer
    );
    viewer.setMarginEngine(st.engine);
    st.engine.createMarket("ngn");
    if (st.engine.createMarket("eur") != EUR_MARKET) revert("EUR is market 2, as on mainnet");
    MockFeeds spot = new MockFeeds();
    spot.setSpot(price, 1e18);
    st.engine.setOraclesForMarket(EUR_MARKET, ISpotFeed(address(spot)), IForwardFeed(address(0)), IVolFeed(address(0)));
    MockFeeds stable = new MockFeeds();
    stable.setSpot(1e18, 1e18);
    st.engine.setStableFeed(stable);
    st.submitter = new OracleDataSubmitter();
    st.verifier = new StandInStreamsVerifier(vm.envAddress("REPORT_SIGNER"));
  }

  /// @dev The production defaults (fixing, margin, timelock, index age), no cap, the stand-in verifier.
  function _params(Stack memory st, address deployer, uint price) internal view returns (Params memory params) {
    params.subAccounts = address(st.subAccounts);
    params.vault = deployer;
    params.engine = address(st.engine);
    params.cash = address(st.cash);
    params.expiry = uint64(block.timestamp + vm.envOr("EXPIRY_IN", uint(5400)));
    params.fixingWindow = DEFAULT_FIXING_WINDOW;
    params.lastTradeTime = params.expiry - uint64(params.fixingWindow);
    params.contractSize = DEFAULT_CONTRACT_SIZE;
    params.initialMark = price;
    params.imReq = DEFAULT_FUTURE_IM_REQ;
    params.mmReq = DEFAULT_FUTURE_MM_REQ;
    params.futureOICap = UNCAPPED;
    params.feedTimelock = DEFAULT_FEED_TIMELOCK;
    params.maxSampleGap = DEFAULT_MAX_SAMPLE_GAP;
    params.recoveryDelay = DEFAULT_RECOVERY_DELAY;
    params.indexMaxAge = DEFAULT_INDEX_MAX_AGE;
    params.forwardSigner = vm.envAddress("FORWARD_SIGNER");
    params.verifierProxy = address(st.verifier);
  }

  function _accounts(Stack memory st, address deployer) internal returns (uint alice, uint bob) {
    alice = st.subAccounts.createAccount(deployer, st.engine);
    bob = st.subAccounts.createAccount(deployer, st.engine);
    st.usdc.mint(deployer, 2 * FUNDING_USDC);
    st.usdc.approve(address(st.cash), 2 * FUNDING_USDC);
    st.cash.deposit(alice, FUNDING_USDC);
    st.cash.deposit(bob, FUNDING_USDC);
  }

  function _record(Stack memory st, Deployment memory d, Params memory params, uint alice, uint bob) internal {
    string memory o = "rehearsal";
    vm.serializeUint(o, "chainId", block.chainid);
    vm.serializeAddress(o, "subAccounts", address(st.subAccounts));
    vm.serializeAddress(o, "manager", address(st.engine));
    vm.serializeAddress(o, "cash", address(st.cash));
    vm.serializeAddress(o, "usdc", address(st.usdc));
    vm.serializeAddress(o, "dataSubmitter", address(st.submitter));
    vm.serializeAddress(o, "standInVerifier", address(st.verifier));
    vm.serializeAddress(o, "reportSigner", st.verifier.signer());
    vm.serializeAddress(o, "adapter", address(d.adapter));
    vm.serializeAddress(o, "indexFeed", address(d.indexFeed));
    vm.serializeAddress(o, "future", address(d.future));
    vm.serializeAddress(o, "forwardFeed", address(d.forwardFeed));
    vm.serializeAddress(o, "forwardSigner", params.forwardSigner);
    vm.serializeUint(o, "subId", d.subId);
    vm.serializeUint(o, "expiry", params.expiry);
    vm.serializeUint(o, "lastTradeTime", params.lastTradeTime);
    vm.serializeUint(o, "initialMark", params.initialMark);
    vm.serializeUint(o, "poolAccount", st.engine.accId());
    vm.serializeUint(o, "alice", alice);
    string memory json = vm.serializeUint(o, "bob", bob);
    _writeToDeployments(REHEARSAL_NAME, json);
  }

  function _artifact() internal view returns (string memory) {
    return vm.readFile(
      string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "/", REHEARSAL_NAME, ".json")
    );
  }

  /// @notice bob sells alice POSITION contracts at the current index (the keeper must be posting reports).
  function openPosition() external {
    if (block.chainid == 8453) revert("rehearsal: never on Base mainnet");
    string memory a = _artifact();
    FutureAsset future = FutureAsset(vm.parseJsonAddress(a, ".future"));
    (uint index,) = EurcIndexFeed(vm.parseJsonAddress(a, ".indexFeed")).getSpot();
    vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
    SubAccounts(vm.parseJsonAddress(a, ".subAccounts"))
      .submitTransfer(
        ISubAccounts.AssetTransfer({
        fromAcc: vm.parseJsonUint(a, ".bob"),
        toAcc: vm.parseJsonUint(a, ".alice"),
        asset: future,
        subId: vm.parseJsonUint(a, ".subId"),
        amount: POSITION,
        assetData: bytes32(index)
      }),
        ""
      );
    vm.stopBroadcast();
    console2.log("alice long, bob short, 10 contracts at", index);
  }

  /// @notice After settlement: close out both accounts, and require cash conserved across them and the pool.
  function closeOut() external {
    if (block.chainid == 8453) revert("rehearsal: never on Base mainnet");
    string memory a = _artifact();
    MarginEngine engine = MarginEngine(vm.parseJsonAddress(a, ".manager"));
    SubAccounts subAccounts = SubAccounts(vm.parseJsonAddress(a, ".subAccounts"));
    address cash = vm.parseJsonAddress(a, ".cash");
    FutureAsset future = FutureAsset(vm.parseJsonAddress(a, ".future"));
    uint subId = vm.parseJsonUint(a, ".subId");
    uint alice = vm.parseJsonUint(a, ".alice");
    uint bob = vm.parseJsonUint(a, ".bob");
    uint pool = vm.parseJsonUint(a, ".poolAccount");
    IFutureAsset.FutureContract memory c = future.futureContracts(subId);
    if (!c.settled) revert("not settled yet");

    vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
    engine.closeOutExpired(alice, uint96(subId));
    engine.closeOutExpired(bob, uint96(subId));
    vm.stopBroadcast();

    int ca = subAccounts.getBalance(alice, ICashAsset(cash), 0);
    int cb = subAccounts.getBalance(bob, ICashAsset(cash), 0);
    int cp = subAccounts.getBalance(pool, ICashAsset(cash), 0);
    console2.log("settlement price", c.markPrice);
    console2.log("alice cash", ca);
    console2.log("bob cash", cb);
    console2.log("pool cash", cp);
    if (subAccounts.getBalance(alice, future, subId) != 0 || subAccounts.getBalance(bob, future, subId) != 0) {
      revert("positions not closed out");
    }
    if (ca + cb + cp != 2 * int(FUNDING_USDC)) revert("cash not conserved");
    console2.log("cash conserved: alice + bob + pool = 40,000 USDC");
  }
}
