#!/usr/bin/env sh
set -eu

mode="${SERVICE_MODE:-api}"

case "$mode" in
  matcher)
    exec ./out-matcher
    ;;
  api|*)
    exec ./out
    ;;
esac

