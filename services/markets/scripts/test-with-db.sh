#!/usr/bin/env bash
# Runs the markets-service tests against a real Postgres, the way CI does.
#
# The database-backed tests skip when no database is configured, and a skip reads as a pass: until
# this existed, CI ran `go test ./...` with no database, so every one of them — the order-history
# owner filter, the book, the matcher's post-only path, the event hub — was skipped on every run
# while the job stayed green. So this does not stop at "the tests passed". It also fails if any test
# skipped for want of a database.
#
# Two variable names are in use (MARKETS_SERVICE_TEST_DATABASE_URL and TEST_DATABASE_URL); both
# are set from the one given, so neither half of the suite can quietly fall back to skipping.
#
#   MARKETS_SERVICE_TEST_DATABASE_URL=postgres://... ./scripts/test-with-db.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

db="${MARKETS_SERVICE_TEST_DATABASE_URL:-}"
if [ -z "$db" ]; then
  echo "MARKETS_SERVICE_TEST_DATABASE_URL is not set." >&2
  echo "  The database-backed tests skip without it, and a skip reads as a pass." >&2
  echo "  e.g. docker run -d -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:18" >&2
  exit 2
fi
export MARKETS_SERVICE_TEST_DATABASE_URL="$db" TEST_DATABASE_URL="$db" DATABASE_URL="$db"

# The orders suites assume a migrated schema; they do not apply migrations themselves.
if ! go run ./cmd/migrate; then
  echo "::error::migrations failed against the test database" >&2
  exit 1
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# -p 1: one package at a time. The api and events suites each re-apply every migration file to the
# shared database, and 000003 creates a table 000007 drops, so two packages doing it at once race on
# CREATE TABLE and Postgres rejects the loser (duplicate key on pg_type_typname_nsp_index). That
# passed or failed by timing. Packages run in seconds, so serializing them costs next to nothing.
go test -p 1 -count=1 -v ./... >"$out" 2>&1
status=$?

grep -E '^(ok|FAIL|---? FAIL|panic:)' "$out"
if [ "$status" -ne 0 ]; then
  echo "::error::go test failed; full output follows" >&2
  cat "$out"
  exit "$status"
fi

# go test -v prints a skip's message before its --- SKIP line, so take the line after the message.
skipped="$(grep -A1 -E 'DATABASE_URL' "$out" | grep -E -- '--- SKIP|DATABASE_URL' || true)"
if [ -n "$skipped" ]; then
  echo "$skipped"
  echo "::error::a database-backed test skipped; a skip reads as a pass" >&2
  exit 1
fi

ran="$(grep -cE '^\s*--- PASS: ' "$out")"
echo "database-backed run: ${ran} passing tests, none skipped for want of a database"
