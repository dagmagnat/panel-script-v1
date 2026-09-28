#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Keep this umbrella test aligned with the helpers that exist in the current
# installer. The previous version tested removed cover/relay functions and
# failed before exercising any current code.
bash "$ROOT_DIR/tests/timeweb-origin-tests.sh"
bash "$ROOT_DIR/tests/node-caddy-route-tests.sh"

echo 'All current origin and reverse-proxy tests passed.'
