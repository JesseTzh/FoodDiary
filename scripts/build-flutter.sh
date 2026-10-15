#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
BUILD_SHA="$(git rev-parse --short HEAD 2>/dev/null || printf dev)"
BUILD_VERSION="Ver:$(TZ=Asia/Shanghai date +%y%m%d-%H%M)-${BUILD_SHA}"
"${FLUTTER:-flutter}" build "$@" --dart-define="APP_VERSION=${BUILD_VERSION}"
