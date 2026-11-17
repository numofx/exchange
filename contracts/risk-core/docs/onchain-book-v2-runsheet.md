# OnchainBook v2 run-sheet: our maker on the book, self-priced (C6 first scope, part 2)

Prepared 2026-11-17. **Nothing here has been sent.** Each step that sends is its own go-ahead. The bot (part 1)
is market-maker `f7049c62`; the contracts are C4.1–C4.4 (spec Part C).

The goal is C0 test 3: an outside contract reaches the venue's liquidity in one transaction, with no off-chain
party. It passes when our maker's size quotes self-priced on the v2 book, so a taker attaches no reports. It does not
pass while the size stays on `Matching`.

## Decisions needed first

| # | Decision | Options, with a recommendation |
|---|---|---|
| D1 | List a next EURC series? (open on the 30 Nov run-sheet; owner said yes 2026-11-17, expiry being confirmed) | Needed: v2 can only list a series the future has listed (the deploy refuses otherwise), and EURC-30NOV26's last trade is 14:30 UTC on 30 Nov. **Recommend yes.** |
| D2 | Its expiry | 2026-12-31 15:00 UTC (`1798729200`, rehearsed) or an earlier business day, e.g. 2026-12-30, to avoid a fixing window on 31 Dec. Last trade 30 min before, as now. |
| D3 | **Decided 2026-11-17: (b), ttl 30 s** (bot defaults since market-maker `0d687040`). Self-priced cadence, which sets the cost (below) | (a) As decided: ttl 10 s, every 5 s cycle sends. (b) ttl 30 s, refresh 22 s (`refresh + poll + 3 ≤ ttl`): about a fifth of the updates, with quotes up to ~30 s old when the forward moves less than `MM_BOOK_REPRICE_TICKS`. A reprice still sends at once in either case. (a) is the decision of record; (b) is offered because of the cost. |
| D4 | Book size | Today: 60 EURC a side (`20@0,40@50`, 300-tick half-spread). C0 test 3 means our `Matching` size moves here. Name the curve and half-spread; margin is sized from it (step 5). |
| D5 | The maker's account | **Recommend** a new account for v2, owned by the MM wallet (`0x3448…B47B`), keeping #56 for v1 until 30 Nov. |
| D6 | `Matching` quoting on the new series | C6 keeps the Matching path. Quoting both doubles our exposure per price. **Recommend** our size on the book only, with Matching quoting the series small or not at all until C4.6. |

## Cost and funding (MM wallet `0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B`)

| | Gas per update | Updates a day | ETH a day (0.006 gwei; the L1 fee on top) |
|---|---|---|---|
| Pegged, today | ~40k | ≤ ~100 | ~0.00004 |
| D3 (a), 10 s ttl | 73,061 (fork, v2) | 17,280 | ~0.0076 + L1, call it ≤ 0.013 |
| D3 (b), 30 s ttl | 73,061 | ~3,500 | ~0.0016 + L1, ≤ 0.003 |

- **Balance:** 0.0004 ETH on 2026-11-17, under an hour at (a).
- **Fund before step 6:** at least two weeks at the chosen cadence (b): **about 0.05 ETH**. By hand
  from the owner, not from another hot wallet. Write it back the same day.
- **Raise its floor** in `check_signer_balance.py` in the same commit as the switch. The floor is a week's spend at
  (b): **~0.02 ETH**. The floor of 0.00005 assumes pegged. Raised earlier, it pages until funded; left
  as is, it misses a drain.

## Steps

1. **List the series (D1, D2).** A vault `setContract(expiry, lastTradeTime, initialMark)` on FutureAsset v3
   `0xC350…B227`. The fork test `testTheSeriesIsReadFromTheFuture` does exactly this.
   - **Not built yet:** a proposer for that action, the series' keeper instance (`numo-future-feeds-v2@…`,
     `FUTURE_VERSION=v3`, its own funded relayer: two keepers on one relayer race for nonces), and the instruments
     registry entry with `taker_fee_bps`. The enable gate refuses a series missing from `/markets`.
   - The adapter, the index feed and the `report-age` alert are the future's and are shared, so nothing is repointed.
2. **Deploy** from a fresh, single-use deployer:

   ```
   EXPIRY=<D2> TAKER_FEE_RATE=<registry bps × 1e14> MAKER_OWNER=0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B \
     forge script scripts/deploy-onchain-book.s.sol --rpc-url $BASE_RPC_URL --account <keystore> --broadcast
   ```

   - It deploys the book and the router. The deployer sets `maxSelfPricedTtl` to 60 s and the tax to 0, then
     nominates the vault.
   - It writes `ONCHAIN_BOOK_V2{,_VAULT_ACTIONS,_ENABLE_VAULT_ACTIONS}.json`, recording `router` and `deployBlock`,
     and refuses if they already exist. v1's files are untouched.
3. **Setup batch:** `propose_onchain_book_batch.py book-setup` (`--version 2` is the default) accepts ownership and
   allows the maker. The gates re-read 26 settings, including the cap and the router's book, cash and SubAccounts.
4. **Indexer:** set `ONCHAIN_BOOK_V2_ADDRESS` and `ONCHAIN_BOOK_V2_START_BLOCK` (`deployBlock`) on the matcher.
   - Needs a markets deploy that includes this commit, through `with-matcher-mute.sh`.
   - The terraform needs a variable pair beside `onchain_book_address`. An empty start block must stay unset, not
     `"0"`: the config refuses a start block without an address.
   - Check `/healthz` → `book_indexers` lists both books.
5. **Maker account (D5).** Same steps as `docs/book-maker.md`: create it under engine v2, deposit cash for D4's
   margin, and set allowances to the **v2** book (allowances are per book).
6. **Fund the wallet** and raise the floor (above).
7. **Bot, dry run.** A second ECS service beside `market-maker-book`, with `MM_BOOK_ADDRESS` set to the v2 book,
   `MM_BOOK_SELF_PRICED=true`, the new account, D4's curve, and its own healthchecks.io dead-man check. Read the log:
   `book_v2=true`, `self_priced=true`, then `preflight ok`. Then set `MM_BOOK_DRY_RUN=false`. Preflight sets the curve
   and registers.
8. **Enable batch:** `book-enable`. Its gates require the vault owns the book, the maker is allowed, the series is
   open, the index answers, and the book's fee equals the registry's.
9. **Canary.** A throwaway account takes a few lots with no reports attached (`take(o, "")`). This is C0 3a. Check
   the fill on the tape (`source = book`) and `book_takes`. Then the kit's `DeltaHedgedEurcVault` flow, or a router
   `route`, as the composed case.
10. **Write back** the same day: the addresses, the terraform values, the floor and the funding.

v1 keeps quoting EURC-30NOV26 pegged until its cutoff, from the same image: the bot detects v1 and refuses
self-priced there. After 30 Nov, retire `market-maker-book` and drop `ONCHAIN_BOOK_ADDRESS` once its tape is final.

## Rehearsed on forks, 2026-11-17

- **Bot** (market-maker `docs/book-maker.md`): the five refusals, quoting, a take at the curve, a lapse at the ttl,
  SIGTERM cancel, and a cancel on a stale index.
- **Deploy and proposer** (Base fork, block ~58.64M, as chain 8453 with the artifacts in a scratch directory):
  - the deploy refused EURC-31DEC26 before the vault listed it, then deployed it once listed: symbol
    `EURC-31DEC26`, cap 60, router recorded;
  - a second deploy refused to overwrite;
  - setup gates passed: 26 settings;
  - the parity gate failed when the deployer changed the cap to 59, and when the artifact named the wrong router;
  - after setup was replayed as the vault, every action read as landed;
  - enable failed on the fork's stale index and on the series missing from the registry, as it must.
