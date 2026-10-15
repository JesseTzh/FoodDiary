#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
bash ../scripts/build-flutter.sh web --release --no-web-resources-cdn "$@"
python3 ../scripts/build-pwa.py
