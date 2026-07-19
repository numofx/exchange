#!/usr/bin/env sh
set -eu

mode="${SERVICE_MODE:-api}"

case "$mode" in
  matcher)
    exit 0
    ;;
  api|*)
    exec ./migrate
    ;;
esac

