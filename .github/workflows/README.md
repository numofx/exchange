# Path-filtered CI

Copy these into `.github/workflows/` of the monorepo. Each workflow runs only
when its component (or a dependency) changes, so a Go change never triggers a
`forge test` and vice-versa.

| Workflow | Triggers on paths | Runs |
|----------|-------------------|------|
| `contracts-risk-core`  | `contracts/risk-core/**` | `forge fmt --check`, `forge test` |
| `contracts-execution`  | `contracts/execution/**` **+ `contracts/risk-core/**`** (v2-core dep) | `forge fmt --check`, `forge test` |
| `services-markets`     | `services/markets/**` | `go build`, `go vet`, `go test` |
| `services-execution`   | `services/execution/**` **+ `packages/abis/**`** | `pnpm check`, `build`, `test` |
| `abis-drift` (Phase 2) | `contracts/execution/**` + `packages/abis/**` | regenerate, fail on diff |

## Dependency edges encoded in the filters
- `contracts/risk-core` change → re-runs **both** contract workflows (execution
  compiles against risk-core through `v2-core`).
- `packages/abis` change → re-runs **services-execution** (it imports `@numo/abis`).
- `contracts/execution` change → `abis-drift` forces the committed ABIs to be
  regenerated; that regen commit touches `packages/abis`, which in turn triggers
  `services-execution`. So a contract ABI change transitively re-tests the service.

## Simplification vs the old per-repo CI
The old `risk-core` / `execution-contracts` `ci.yml` used an SSH secret
(`V2_CORE`) to clone a private `v2-core` submodule. In the monorepo `v2-core` is
an in-repo symlink and the remaining submodules (forge-std, OZ, derive-utils) are
public — `submodules: recursive` is enough, **no SSH secret**.

## Follow-ups (not in these files)
- Port `slither.yml` from each contracts repo the same way (path-filtered on
  `contracts/**`).
- Phase 2 removes `matchingRepoPath`; update `services/execution/src/app.test.ts`
  (currently sets `matchingRepoPath: '/tmp/execution-contracts'`) or
  `services-execution` `test` will fail. Do this in the Phase 2 change.
- Codecov upload was in the old contracts CI; re-add with a repo secret if you
  still want coverage reporting.
