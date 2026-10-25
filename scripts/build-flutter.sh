#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
BUILD_SHA="$(git rev-parse --short HEAD 2>/dev/null || printf dev)"
BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf dev)"
BUILD_VERSION="Ver:$(TZ=Asia/Shanghai date +%y%m%d-%H%M)-${BUILD_SHA}"
BUILD_NUMBER="$(python3 -c 'import time; print(int(time.time()) - 946684800)')"
# Persist the exact display version used by the APK for the release manifest.
printf '%s\n' "$BUILD_VERSION" > build-version.txt
"${FLUTTER:-flutter}" build "$@" --build-number="$BUILD_NUMBER" --dart-define="APP_VERSION=${BUILD_VERSION}" --dart-define="APP_BUILD_COMMIT=${BUILD_COMMIT}"
