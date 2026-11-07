#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../frontend"
web_build_dir=build/web
previous_arg=
for arg in "$@"; do
  if [[ "$previous_arg" == --output ]]; then web_build_dir="$arg"; fi
  if [[ "$arg" == --output=* ]]; then web_build_dir="${arg#--output=}"; fi
  previous_arg="$arg"
done
bash ../scripts/build-flutter.sh web --release --wasm --no-web-resources-cdn --dart-define=WEB_OPTIMIZED_ASSETS=true "$@"
python3 ../scripts/optimize-web.py "$web_build_dir"
python3 ../scripts/build-pwa.py "$web_build_dir"
