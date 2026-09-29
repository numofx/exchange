# local-venue

The whole USDCcNGN-PERP venue on one machine, launched in the same order mainnet will be:

```bash
BASE_RPC_URL=<archive-capable Base RPC> ./scripts/local-venue/up.sh
./scripts/local-venue/down.sh
```

`up.sh` forks Base as chain **31337**, then:

1. deploys the stack and TradeModule with the real deploy scripts. The stack comes up with cap 0
   and the module is not allowlisted;
2. runs the two deploy batches as the vault (impersonated), which only accept ownership, and checks
   the market is still closed;
3. starts Postgres, runs the migrations, and starts markets api and matcher and execution-service;
4. starts `perp-feeds --local-fixed-price`, the keeper (live, with `/health` on), the SecurityModule
   seed and a two-sided maker quote;
5. runs `propose_perp_enable_batch.py --local`, which checks every launch gate against the local
   services and writes the enable actions, then applies them as the vault;
6. has a taker cross the quote, and reads the position back from `/v1/positions`.

Needs `anvil`, `forge`, `cast`, Go, pnpm and Postgres binaries (`initdb`, `pg_ctl`). State, logs and
pids go to `.local-venue/` (override with `LOCAL_VENUE_DIR`). Ports are anvil 8600, Postgres 5544,
markets 8090, execution 8091 and keeper health 9464.

## What keeps this local

- Every key is `keccak256("numo.local-venue.<label>")`, and USDC is minted by writing its storage.
- `venue.ts` asks the RPC for its chain id and refuses anything but 31337.
- `perp-feeds --local-fixed-price` refuses unless both `CHAIN_ID` and the RPC's own chain id are
  31337. It names 8453 and 84532 in its refusal.
- `propose_perp_enable_batch.py --local` requires 31337 and never proposes.
- The e2e deploy scripts `require(block.chainid == 31337)`.

The vault steps are anvil impersonation. They show which calls the real vault makes, not how it
makes them.
