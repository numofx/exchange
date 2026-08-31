# Build context is services/markets.
#
# One image carries all three binaries; which one runs is chosen per ECS task
# definition via an entryPoint override, and SERVICE_MODE declares the same choice
# as an environment variable so the boot guard can assert the two agree.

FROM golang:1.24-bookworm AS build

WORKDIR /src

# Dependencies first so a source-only change does not re-download the module cache.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG GIT_SHA=unknown

# CGO off and a static build so the result runs on distroless/static.
# -trimpath keeps build paths out of the binary; -s -w drop the symbol table.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api     ./cmd/api \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/matcher ./cmd/matcher \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/migrate ./cmd/migrate

# --------------------------------------------------------------------- runtime

FROM gcr.io/distroless/static-debian12:nonroot

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.source="https://github.com/numofx/exchange"

COPY --from=build /out/api     /app/api
COPY --from=build /out/matcher /app/matcher
COPY --from=build /out/migrate /app/migrate

USER nonroot:nonroot

# Overridden per task definition: matcher and migrate point at their own binary.
ENTRYPOINT ["/app/api"]
