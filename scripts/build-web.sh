#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
BUILD_SHA="$(git rev-parse --short HEAD 2>/dev/null || printf dev)"
BUILD_VERSION="Ver:$(date -u +%y%m%d-%H%M)-${BUILD_SHA}"
flutter build web --release --no-web-resources-cdn --dart-define="APP_VERSION=${BUILD_VERSION}" "$@"
python3 ../scripts/build-pwa.py
