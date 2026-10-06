#!/usr/bin/env bash
# Runs the server test suite in the official Swift 6.2 image (no local toolchain needed).
# Usage: Server/scripts/docker-test.sh [extra swift test args]
# Set TEST_DATABASE_URL to also run the Postgres store contract tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
IMAGE="${SWIFT_IMAGE:-swift:6.2-noble}"
EXTRA_ENV=()
for var in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy TEST_DATABASE_URL; do
  [ -n "${!var:-}" ] && EXTRA_ENV+=(-e "$var")
done
if [ -n "${SSL_CERT_FILE_HOST:-}" ]; then
  EXTRA_ENV+=(-e GIT_SSL_CAINFO=/ca.crt -e SSL_CERT_FILE=/ca.crt -v "$SSL_CERT_FILE_HOST:/ca.crt:ro")
fi
exec docker run --rm --network host "${EXTRA_ENV[@]}" -v "$PWD":/work -w /work/Server "$IMAGE" swift test "$@"
