GO ?= go

.PHONY: run-api
run-api:
	$(GO) run ./cmd/api

.PHONY: run-matcher
run-matcher:
	$(GO) run ./cmd/matcher

.PHONY: migrate
migrate:
	$(GO) run ./cmd/migrate

.PHONY: test
test:
	$(GO) test ./...
