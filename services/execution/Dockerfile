# Build context is the REPOSITORY ROOT, not services/execution — this package
# depends on @numo/abis through the pnpm workspace, so the build needs both:
#
#   docker build -f services/execution/Dockerfile .
#
FROM node:22-slim AS build

WORKDIR /repo
RUN corepack enable && corepack prepare pnpm@8.7.3 --activate

# Manifests first: the install layer then survives any source-only change.
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY packages/abis/package.json      packages/abis/
COPY services/execution/package.json services/execution/
RUN pnpm install --frozen-lockfile

COPY packages/abis      packages/abis
COPY services/execution services/execution

# @numo/abis must be compiled before the service that imports it.
RUN pnpm --filter @numo/abis build \
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
