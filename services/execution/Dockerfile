# Build context is the REPOSITORY ROOT, not services/execution — this package depends on
# @numo/abis and @numo/kms-signer through the pnpm workspace, so the build needs all three:
#
#   docker build -f services/execution/Dockerfile .
#
FROM node:22-slim AS build

WORKDIR /repo
RUN corepack enable && corepack prepare pnpm@8.7.3 --activate

# Manifests first: the install layer then survives any source-only change.
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY packages/abis/package.json       packages/abis/
COPY packages/kms-signer/package.json packages/kms-signer/
COPY services/execution/package.json  services/execution/
RUN pnpm install --frozen-lockfile

COPY packages/abis       packages/abis
COPY packages/kms-signer packages/kms-signer
COPY services/execution  services/execution

# Every workspace package the service imports must be COMPILED first: their main/types resolve to
# dist/, which is gitignored, so a package that is copied but not built fails the service's tsc with
# "Cannot find module". Add the build here whenever a new workspace dependency is added -- CI now
# builds this image (services-execution.yml) so a missing one fails there rather than at deploy.
RUN pnpm --filter @numo/abis build \
 && pnpm --filter @numo/kms-signer build \
 && pnpm --filter matching-executor build

# Resolves the workspace link into a self-contained tree with prod deps only.
RUN pnpm deploy --filter matching-executor --prod /app

# --------------------------------------------------------------------- runtime

FROM node:22-slim AS runtime

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.source="https://github.com/numofx/exchange"

ENV NODE_ENV=production
WORKDIR /app

COPY --from=build --chown=node:node /app ./

USER node

# --healthcheck short-circuits before loadConfig; see src/index.ts.
ENTRYPOINT ["node", "dist/index.js"]
