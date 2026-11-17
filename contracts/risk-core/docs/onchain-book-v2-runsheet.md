# OnchainBook v2 run-sheet: our maker on the book, self-priced (C6 first scope, part 2)

Prepared 2026-11-17. **Nothing here has been sent.** Each step that sends is its own go-ahead.

| Piece | Where |
|---|---|
| Bot | market-maker `0d687040` (self-priced, v1/v2 detection, 30 s defaults) |
| Contracts | C4.1–C4.4 (spec Part C) |
| Deploy, proposer, indexer | exchange `9780841` |
| Terraform | `infra/aws/market-maker-book-v2.tf` and the `onchain_book_v2_*` variables |

The goal is C0 test 3: an outside contract reaches the venue's liquidity in one transaction, with no off-chain
party. It passes when our maker's size quotes self-priced on the v2 book, so a taker attaches no reports. It does not
pass while the size stays on `Matching`.

## Decided (owner, 2026-11-17)

- **Series: v2 lists EURC-30NOV26 now**, beside v1 (`EXPIRY=1796050800`).
  - No series listing, keeper or registry entry is needed: the future, the adapter and the fee registry already
    carry it.
  - Last trade is 14:30 UTC on 30 Nov, and both makers' cutoff (`MM_BOOK_CUTOFF_SECONDS` 3600) takes their quotes
    down at 13:30. That leaves about 12 days of trading. A next series is a separate decision, on the 30 Nov
    run-sheet.
- **Self-priced ttl: 30 s**, refreshed once 22 s old (`refresh + poll + 3 ≤ ttl`). A reprice of
  `MM_BOOK_REPRICE_TICKS` sends at once. This replaces C6's ~10 s, for gas. The book's cap stays at 60 s.

## Decided later (owner, 2026-11-17)

- **D4: A, the whole size.** The Matching maker's ladder moved to the book (3,012 EURC a side, 8–35 bps), with the
  bot's inventory cap (5,000 lots) and on-chain skew (1 tick a lot to 2,750). #58 holds 1,590 USDC (300 from #56,
  1,290 from #40).
- **D5:** #58, a new account; #56 stays on v1.
- **D6:** the Matching maker for EURC-30NOV26 (#40) stopped 2026-11-17 19:01 UTC; #40 keeps 10 USDC behind a 2-EURC
  short to expiry.

## Cost and funding (MM wallet `0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B`)

| | Gas per update | Updates a day | ETH a day (0.006 gwei; the L1 fee on top) |
|---|---|---|---|
| v1 pegged, today | ~40k | ≤ ~100 | ~0.00004 |
| v2 self-priced, 30 s ttl | 73,061 (fork) | ~3,500 | ~0.0016 + L1, ≤ 0.003 |

- **Balance:** 0.0004 ETH on 2026-11-17.
- **Fund before step 6:** about **0.05 ETH**, which covers to 30 Nov with room. By hand from the owner, not from
  another hot wallet. Write it back the same day.
- **Raise its floor** in `check_signer_balance.py` to **~0.02 ETH** (a week's spend), in the same commit as the
  switch. The floor of 0.00005 assumes pegged. Raised earlier, it pages until funded; left as is, it misses a drain.

## Steps

1. **Deploy** from a fresh, single-use deployer. **Done 2026-11-17 ~13:15 UTC:** book `0x83C5741a24d57189379E1215F7A22d9f048E89d5`, router
   `0xd9540220b514ab2E1a98Ff3C4c4F1F5FD5cf76aB`, created in block 58,656,423 (`OPS_BOX_CHANGES.md`). `maxMakers` is 10, not v1's 3:
   pass `MAX_MAKERS` next time.

   ```
   EXPIRY=1796050800 TAKER_FEE_RATE=500000000000000 MAKER_OWNER=0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B \
     forge script scripts/deploy-onchain-book.s.sol --rpc-url $BASE_RPC_URL --account <keystore> --broadcast
   ```

   - It deploys the book and the router. The deployer sets `maxSelfPricedTtl` to 60 s and the tax to 0, then
     nominates the vault.
   - It writes `ONCHAIN_BOOK_V2{,_VAULT_ACTIONS,_ENABLE_VAULT_ACTIONS}.json`, recording `router` and `deployBlock`,
     and refuses if they already exist. v1's files are untouched.
   - The fee (5 bps) is the registry's, and the enable gate checks it again.
2. **Setup batch** (**landed 2026-11-17 13:44 UTC**, `OPS_BOX_CHANGES.md`): `propose_onchain_book_batch.py book-setup` (`--version 2` is the default) accepts ownership and
   allows the maker. The gates re-read 26 settings, including the cap and the router's book, cash and SubAccounts.
3. **Indexer** (**done 2026-11-17 13:52 UTC**: markets `6bb45f2`, both books on `/health`). Deploy markets at `9780841` or later through `with-matcher-mute.sh`. Then set
   `onchain_book_v2_address` and `onchain_book_v2_start_block` (`deployBlock`); the matcher's preconditions refuse
   one without the other, and v1's address. Check that `/healthz` → `book_indexers` lists both books.
4. **Maker account (D5)** (**done 2026-11-17: #58, 300 USDC moved from #56, allowances to the v2 book**). Same steps as `docs/book-maker.md`:
   - create the account under engine v2;
   - deposit cash for D4's margin;
   - set allowances to the **v2** book (allowances are per book).
5. **Dead-man check** (**created 2026-11-17**, `39ff502b…`; **went down 17:30:53** with the bot stopped, up again on restart). A healthchecks.io check `book-maker-v2` (1 min period, 10 min grace), its ping URL at SSM
   `/numo/exchange/book_maker_v2_heartbeat_url`. Create it before step 7: a task referencing a missing parameter
   does not start. Prove it fires (break it) once the bot runs.
6. **Fund the wallet** and raise the floor (above). (**Done 2026-11-17:** 0.03 ETH; burn 0.002/day in the check.)
7. **Bot, dry run** (**live 2026-11-17 15:32 UTC** after a dry run from 15:25; registered, quoting self-priced).
   - Build and push a market-maker image at `0d687040` or later. Set:
     - `image_market_maker_book_v2`;
     - `onchain_book_v2_maker_book`;
     - `onchain_book_v2_maker_account_id`;
     - `desired_count_market_maker_book_v2 = 1`.

     `market_maker_book_v2_dry_run` defaults to true.
   - The plan should add only the v2 log group, task definition, service, and one IAM resource (the new heartbeat
     ARN).
   - Read the log: `book_v2=true`, `self_priced=true`, `ttl=30s`, then `preflight ok`.
   - Then set `market_maker_book_v2_dry_run = false`. Preflight sets the curve and registers.
8. **Enable batch** (**landed 2026-11-17 17:40:55**, tx `0xbf9bdaa8…`): `book-enable`. Its gates require the vault owns the book, the maker is allowed, the series is
   open, the index answers, and the book's fee equals the registry's.
9. **Canary** (**passed 2026-11-17**: #57 bought and sold 5 EURC against #58 with no reports, directly and through the router, reduce-only included).
   - A throwaway account takes a few lots with no reports attached (`take(o, "")`). This is C0 3a.
   - Check the fill on the tape (`source = book`) and in `book_takes`.
   - Then run the kit's `DeltaHedgedEurcVault` flow, or a router `route`, as the composed case.
10. **Write back** the same day: the addresses, the terraform values, the floor and the funding.

v1 keeps quoting pegged from `market-maker-book` until the same cutoff. The bot detects v1 and refuses self-priced
there. After 30 Nov, retire both book makers and drop both indexer addresses once the tapes are final (30 Nov
run-sheet).

## Rehearsed on forks, 2026-11-17

- **Bot** (market-maker `docs/book-maker.md`): the five refusals, quoting, a take at the curve, a lapse at the ttl,
  SIGTERM cancel, and a cancel on a stale index.
- **Deploy and proposer, on the exact path** (Base fork at head, block ~58.65M, as chain 8453, with the artifacts
  moved to a scratch directory):
  - `EXPIRY=1796050800` with `MAKER_OWNER` set to the MM wallet deployed `EURC-30NOV26`: cap 60, router recorded;
  - the setup gates passed (26 settings);
  - with setup replayed as the vault, **every enable gate passed**, against the live index (1.099309) and the live
    registry (5 bps).
- **Deploy and proposer, other cases** (a 31 Dec series listed on the fork):
  - refused before the vault listed the series;
  - a second deploy refused to overwrite;
  - the parity gate failed when the deployer changed the cap, and when the artifact named the wrong router;
  - enable failed on a stale index and on a series missing from the registry.
- **Terraform:** `fmt -check` and `validate` clean (terraform 1.9.8, in a container). Not planned: there are no AWS
  credentials here.
