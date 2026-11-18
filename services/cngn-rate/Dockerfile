# Build context is the REPOSITORY ROOT: the lockfile is the workspace's, which pins cngn-rate-picker 0.2.2.
#
#   docker build -f services/cngn-rate/Dockerfile .
#
FROM node:22-slim AS build

WORKDIR /repo
RUN corepack enable && corepack prepare pnpm@8.7.3 --activate

COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY services/cngn-rate/package.json services/cngn-rate/
RUN pnpm install --frozen-lockfile --filter cngn-rate...

COPY services/cngn-rate services/cngn-rate
RUN pnpm --filter cngn-rate build
RUN pnpm deploy --filter cngn-rate --prod /app

FROM node:22-slim AS runtime

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.source="https://github.com/numofx/exchange"

ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app ./
USER node
# A sidecar: it listens on 127.0.0.1 only, for the cNGN book maker in the same task.
ENTRYPOINT ["node", "dist/main.js"]
