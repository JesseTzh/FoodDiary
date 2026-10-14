#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ARTIFACTS="${CI_ARTIFACTS_DIR:-mock-page-artifacts}"
mkdir -p "$ARTIFACTS"
python3 -m http.server 18081 --bind 127.0.0.1 --directory frontend/build/web >"$ARTIFACTS/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:18081/ >/dev/null; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then cat "$ARTIFACTS/server.log"; exit 1; fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:18081/ >/dev/null
CI_BASE_URL=http://127.0.0.1:18081 CI_ARTIFACTS_DIR="$ARTIFACTS" node scripts/ci/web/mock-pages.mjs
