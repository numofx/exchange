// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SubAccounts} from "../src/SubAccounts.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {MarginEngine} from "../src/risk-managers/MarginEngine.sol";
import {IManager} from "../src/interfaces/IManager.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {IAsset} from "../src/interfaces/IAsset.sol";
import {IFutureAsset} from "../src/interfaces/IFutureAsset.sol";
import {CashAsset} from "../src/assets/CashAsset.sol";
import {FutureAsset} from "../src/assets/FutureAsset.sol";
import {EurcIndexFeed} from "../src/feeds/EurcIndexFeed.sol";
import {Utils} from "./utils.sol";

/**
 * @title CanaryEurcV3
 * @notice The Stage 1 drill on Base mainnet (spec A1.4): one contract on the canary series that deploy-eurc-future-v3
 *         listed before the production one, between two accounts of one throwaway key, so no one else is exposed.
 *         The keeper instance for the canary (the numo-future-feeds-v2 unit, instance eurc-v3-canary) posts the reports; the drill
 *         stops it inside the canary's window for longer than the sample gap, restarts it, and it settles through a
 *         recovery window against the real Data Streams verifier.
 *
 *   1. open:  after the vault's setup and enable batches, before the canary's last trade, with the keeper posting:
 *             CANARY_KEY=<throwaway key holding 2 x CANARY_FUNDING_USDC USDC and gas>
 *             forge script scripts/canary-eurc-v3.s.sol --sig "open()" --rpc-url $BASE_RPC_URL --broadcast
 *             Two accounts on MarginEngine v2, CANARY_FUNDING_USDC (6dp, default 300 USDC) each; the short sells the
 *             long one contract at the index. Writes deployments/8453/EURC_FUTURE_V3_CANARY.json.
 *   2. break: stop the canary keeper inside the window for over 2 minutes; restart it. After expiry it opens a
 *             recovery window 5 minutes out, samples it and settles.
 *   3. close: after settlement: CANARY_KEY=... RETURN_TO=<address for the USDC> ... --sig "closeOut()"
 *             Both close out; cash must be conserved across the close-out exactly; all USDC goes to RETURN_TO.
 */
contract CanaryEurcV3 is Utils {
  string internal constant ARTIFACT = "EURC_FUTURE_V3";
  string internal constant CANARY = "EURC_FUTURE_V3_CANARY";
  address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  int internal constant ONE_CONTRACT = 1e18;

  struct Series {
    FutureAsset future;
    MarginEngine engine;
    CashAsset cash;
    EurcIndexFeed indexFeed;
    uint96 subId;
  }

  function _series(string memory a, uint96 subId) internal view returns (Series memory c) {
    c.future = FutureAsset(vm.parseJsonAddress(a, ".future"));
    c.engine = MarginEngine(vm.parseJsonAddress(a, ".manager"));
    c.cash = CashAsset(vm.parseJsonAddress(a, ".cash"));
    c.indexFeed = EurcIndexFeed(vm.parseJsonAddress(a, ".indexFeed"));
    c.subId = subId;
  }

  function open() external {
    if (block.chainid != 8453) revert("canary: Base mainnet only");
    string memory a = _readDeploymentFile(ARTIFACT);
    Series memory c = _series(a, uint96(vm.parseJsonUint(a, ".canarySubId")));
    uint funding = vm.envOr("CANARY_FUNDING_USDC", uint(300e6));
    (uint long, uint short, uint entry) = openOn(c, vm.envUint("CANARY_KEY"), funding);

    string memory o = "canary";
    vm.serializeAddress(o, "owner", vm.addr(vm.envUint("CANARY_KEY")));
    vm.serializeUint(o, "subId", c.subId);
    vm.serializeUint(o, "long", long);
    vm.serializeUint(o, "short", short);
    vm.serializeUint(o, "fundingUsdc", funding);
    vm.serializeUint(o, "entry", entry);
    string memory json = vm.serializeUint(o, "openedAt", block.timestamp);
    _writeToDeployments(CANARY, json);
  }

  function closeOut() external {
    if (block.chainid != 8453) revert("canary: Base mainnet only");
    string memory k = _readDeploymentFile(CANARY);
    Series memory c = _series(_readDeploymentFile(ARTIFACT), uint96(vm.parseJsonUint(k, ".subId")));
    closeOutOn(
      c,
      vm.envUint("CANARY_KEY"),
      vm.parseJsonUint(k, ".long"),
      vm.parseJsonUint(k, ".short"),
      vm.envAddress("RETURN_TO")
    );
  }

  /// @notice Two accounts of `key`'s owner, `funding` USDC (6dp) each; the short sells the long one contract at the
  ///         index. The fork test runs this exact function.
  function openOn(Series memory c, uint key, uint funding) public returns (uint long, uint short, uint entry) {
    if (c.subId == 0) revert("deployed without a canary");
    IFutureAsset.FutureContract memory fc = c.future.futureContracts(c.subId);
    if (!fc.listed || block.timestamp >= fc.lastTradeTime) revert("canary past its last trade");
    if (address(c.engine.assetMap(2, IMarginEngine.AssetType.Future)) != address(c.future)) {
      revert("setup has not landed");
    }
    if (c.future.totalPositionCap(c.engine) == 0) revert("enable has not landed: the cap is 0");
    (entry,) = c.indexFeed.getSpot(); // reverts unless the keeper is posting
    address owner = vm.addr(key);
    if (IERC20(USDC).balanceOf(owner) < 2 * funding) revert("CANARY_KEY holds less than 2 x CANARY_FUNDING_USDC");
    SubAccounts subAccounts = SubAccounts(address(c.engine.subAccounts()));

    vm.startBroadcast(key);
    long = subAccounts.createAccount(owner, IManager(address(c.engine)));
    short = subAccounts.createAccount(owner, IManager(address(c.engine)));
    IERC20(USDC).approve(address(c.cash), 2 * funding);
    c.cash.deposit(long, funding);
    c.cash.deposit(short, funding);
    subAccounts.submitTransfer(
      ISubAccounts.AssetTransfer({
        fromAcc: short, toAcc: long, asset: c.future, subId: c.subId, amount: ONE_CONTRACT, assetData: bytes32(entry)
      }),
      ""
    );
    vm.stopBroadcast();
    console2.log("canary opened: long", long);
    console2.log("short", short);
    console2.log("one contract at", entry);
  }

  /// @notice After settlement: both close out, the VM must net to zero and cash be conserved across the close-out;
  ///         every whole cent of USDC goes to `returnTo`. The fork test runs this exact function.
  function closeOutOn(Series memory c, uint key, uint long, uint short, address returnTo)
    public
    returns (uint returned)
  {
    if (!c.future.futureContracts(c.subId).settled) revert("canary not settled yet");
    uint pool = c.engine.accId();

    vm.startBroadcast(key);
    // interest first, so the close-out alone is measured: it must move cash between the three and create none
    c.engine.settleInterest(long);
    c.engine.settleInterest(short);
    c.engine.settleInterest(pool);
    vm.stopBroadcast();
    int before = _sum(c, long, short, pool);
    int pending = c.future.getPendingVM(long, c.subId);
    if (pending + c.future.getPendingVM(short, c.subId) != 0) revert("VM does not net to zero");

    vm.startBroadcast(key);
    c.engine.closeOutExpired(long, c.subId);
    c.engine.closeOutExpired(short, c.subId);
    vm.stopBroadcast();
    int drift = _sum(c, long, short, pool) - before;

    console2.log("settlement price", c.future.futureContracts(c.subId).markPrice);
    console2.log("long's VM at settlement (18dp)", pending);
    console2.log("cash drift across the close-out (18dp)", drift);
    if (_position(c, long) != 0 || _position(c, short) != 0) revert("positions not closed out");
    // Simulated in one block, the drift is exactly 0. On chain the transactions may land in different blocks, with
    // interest on the pool between them: the read-back after broadcasting is the evidence (spec A1.4).
    if (drift != 0) revert("cash not conserved across the close-out");

    returned = _withdrawAll(c, key, long, returnTo) + _withdrawAll(c, key, short, returnTo);
    console2.log("USDC returned (6dp)", returned);
  }

  function _withdrawAll(Series memory c, uint key, uint acc, address to) internal returns (uint amount) {
    amount = uint(_cashOf(c, acc)) / 1e12;
    vm.startBroadcast(key);
    c.cash.withdraw(acc, amount, to);
    vm.stopBroadcast();
  }

  function _sum(Series memory c, uint a, uint b, uint p) internal view returns (int) {
    return _cashOf(c, a) + _cashOf(c, b) + _cashOf(c, p);
  }

  function _cashOf(Series memory c, uint acc) internal view returns (int) {
    return c.engine.subAccounts().getBalance(acc, IAsset(address(c.cash)), 0);
  }

  function _position(Series memory c, uint acc) internal view returns (int) {
    return c.engine.subAccounts().getBalance(acc, c.future, c.subId);
  }
}
