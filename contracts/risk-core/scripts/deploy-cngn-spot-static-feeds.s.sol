// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import {ISpotFeed} from "../src/interfaces/ISpotFeed.sol";
import {LyraStaticSpotFeed} from "../src/feeds/static/LyraStaticSpotFeed.sol";
import {Deployment} from "./types.sol";
import {Utils} from "./utils.sol";

/**
 * @dev Deploys the two static spot feeds that a cNGN/USDC spot-only venue needs, and hands both
 *      to the admin vault. Run this BEFORE register-cngn-spot-srm.s.sol, which reads the
 *      addresses back out of the artifact this writes.
 *
 * @dev Why static, and why two:
 *
 *      1. ORIENTATION. The SRM's Base convention is USD-per-base (notional = position * spot).
 *         The live cNGN feed is quoted cNGN-per-USDC (~1345) because DeliverableFXManager divides
 *         by it (_quoteToCash). Pointing the SRM's Base slot at that feed inflates the reported
 *         mark-to-market by spot^2 - contained today only by marginFactor == 0. This feed carries
 *         the inverted price so the orientation is correct on its own terms.
 *
 *      2. LIVENESS. Both the market spot feed and the SRM's global stableFeed are read on every
 *         spot adjustment (_getMarketMargin, _getBaseMarginAndMtM:609, _getDepegMultiplier:427)
 *         and both revert when stale. Live heartbeats on Base are 180s and 3600s respectively, so
 *         a keeper gap halts a fully-funded orderbook whose solvency does not depend on either
 *         price (netMargin reduces to cash at marginFactor 0). LyraStaticSpotFeed has no staleness
 *         check at all, so neither can halt the book.
 *
 * @dev The frozen price is inert ONLY while marginFactor is 0. See the coupled-settings block in
 *      DEPLOYED_ADDRESSES.md before changing any of: marginFactor, borrowingEnabled, either spot
 *      feed, or oracleContingencyParams.
 *
 * Usage: NEW_OWNER=<vault> PRIVATE_KEY=<deployer> \
 *          forge script scripts/deploy-cngn-spot-static-feeds.s.sol --rpc-url $BASE_RPC_URL --broadcast
 */
contract DeployCNGNSpotStaticFeeds is Utils {
  string internal constant ARTIFACT_NAME = "CNGN_SPOT_STATIC_FEEDS";

  /// @dev confidence is unread on the spot path: all three consumers of spotConf are unreachable
  ///      for a base-only portfolio (_getNetPerpMargin returns at position == 0,
  ///      _getNetOptionMarginAndMtM's body is loop-only over an empty expiryHoldings, and
  ///      _getBaseMarginAndMtM returns at the baseMargin == 0 short-circuit before the contingency
  ///      block). Set to full confidence anyway so the value is not a confusing 0 to any reader.
  uint internal constant FULL_CONFIDENCE = 1e18;

  /// @dev USDC is the cash asset; the SRM's stableFeed is its USD price.
  uint internal constant STABLE_PRICE = 1e18;

  function run() external {
    uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");

    // Read the live cNGN feed and invert it, rather than hardcoding a rate that is stale the
    // moment it is written. This is the only place the inversion happens.
    address liveCngnFeed = vm.parseJsonAddress(_readDeploymentFile("CNGN"), ".spotFeed");
    if (liveCngnFeed == address(0)) revert("CNGN.spotFeed missing");

    (uint cngnPerUsdc,) = ISpotFeed(liveCngnFeed).getSpot();
    if (cngnPerUsdc == 0) revert("live cNGN feed returned 0");
    uint usdcPerCngn = 1e36 / cngnPerUsdc;
    if (usdcPerCngn == 0) revert("inverted price rounded to 0");

    vm.startBroadcast(deployerPrivateKey);

    LyraStaticSpotFeed cngnFeed = new LyraStaticSpotFeed();
    cngnFeed.setSpot(usdcPerCngn, FULL_CONFIDENCE);

    LyraStaticSpotFeed stableFeed = new LyraStaticSpotFeed();
    stableFeed.setSpot(STABLE_PRICE, FULL_CONFIDENCE);

    address[] memory owned = new address[](2);
    owned[0] = address(cngnFeed);
    owned[1] = address(stableFeed);
    _transferOwnership(owned);

    vm.stopBroadcast();

    string memory objKey = "cngn-spot-static-feeds";
    vm.serializeAddress(objKey, "cngnStaticSpotFeed", address(cngnFeed));
    vm.serializeAddress(objKey, "stableStaticSpotFeed", address(stableFeed));
    vm.serializeAddress(objKey, "invertedFrom", liveCngnFeed);
    vm.serializeUint(objKey, "cngnPerUsdcAtDeploy", cngnPerUsdc);
    string memory finalObj = vm.serializeUint(objKey, "usdcPerCngn", usdcPerCngn);
    _writeToDeployments(ARTIFACT_NAME, finalObj);

    console2.log("live cNGN feed (cNGN per USDC):", liveCngnFeed, cngnPerUsdc);
    console2.log("static cNGN feed (USDC per cNGN):", address(cngnFeed), usdcPerCngn);
    console2.log("static stable feed (USDC per USD):", address(stableFeed), STABLE_PRICE);
    console2.log("");
    console2.log("Ownership transfer initiated - the vault must acceptOwnership() on BOTH feeds.");
    console2.log("Those two calls are actions 9 and 10 of the register-cngn-spot-srm batch.");
  }
}
