#!/usr/bin/env bash
# Runs the reporter scripts against stubbed Roblox services. Needs the `luau` CLI
# (https://github.com/luau-lang/luau/releases): LUAU=/path/to/luau ./run-tests.sh
set -euo pipefail
cd "$(dirname "$0")"
LUAU="${LUAU:-luau}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for side in server client; do
  cat Tests/stubs.luau "PeakErrorReporter.$side.luau" "Tests/$side.test.luau" > "$tmp/$side.luau"
  "$LUAU" "$tmp/$side.luau"
done
