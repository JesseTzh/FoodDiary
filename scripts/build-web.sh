#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
flutter build web --release --no-web-resources-cdn "$@"
python3 ../scripts/build-pwa.py
