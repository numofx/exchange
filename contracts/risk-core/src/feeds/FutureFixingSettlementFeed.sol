// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import {ISettlementFeed} from "../interfaces/ISettlementFeed.sol";
import {IFutureAsset} from "../interfaces/IFutureAsset.sol";

/**
 * @title FutureFixingSettlementFeed
 * @notice Settles an OptionAsset at the settlement price of the dated future with the same expiry, so an option and the
 *         future it is listed beside can never settle at different prices. Whichever way the future settles (the index
 *         fixing, or the vault's bounded fallback) is the price the options read; until it has, they are unsettled.
 * @dev    The future's price units must be the option strikes' units: MarginEngine v2's linear series, USDC per base.
 *         A v1 (inverse, base per USDC) future must never be passed. Stateless and ownerless: nothing here can be
 *         changed after deploy, so the only way to point options elsewhere is OptionAsset.setSettlementFeed.
 */
contract FutureFixingSettlementFeed is ISettlementFeed {
  IFutureAsset public immutable future;

  error FFSF_NoFutureForExpiry(uint64 expiry);

  constructor(IFutureAsset _future) {
    future = _future;
  }

  /// @dev Reverts for an expiry the future does not list: an option there could never settle, and saying so loudly
  ///      beats leaving it unsettled forever. The vol feed publishing only listed expiries keeps any from being written.
  function getSettlementPrice(uint64 expiry) external view returns (bool settled, uint price) {
    IFutureAsset.FutureContract memory c = future.futureContracts(future.getSubId(expiry));
    if (!c.listed || c.expiry != expiry) revert FFSF_NoFutureForExpiry(expiry);
    if (!c.settled) return (false, 0);
    return (true, c.markPrice);
  }
}
