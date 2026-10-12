#!/usr/bin/env bash
# Smoke-test the release APK on the emulator started by android-emulator-runner.
set -euo pipefail

APK="${1:?Usage: bash scripts/ci/verify-android-startup.sh path/to/app-release.apk}"
PACKAGE=com.jessetzh.fooddiary
ACTIVITY="$PACKAGE/.MainActivity"
ARTIFACTS=android-startup-artifacts
mkdir -p "$ARTIFACTS"

collect_diagnostics() {
  local status=$?
  trap - EXIT
  timeout 15s adb logcat -d -v threadtime > "$ARTIFACTS/logcat.txt" 2>&1 || true
  timeout 15s adb shell dumpsys activity activities > "$ARTIFACTS/activities.txt" 2>&1 || true
  timeout 15s adb shell dumpsys window > "$ARTIFACTS/windows.txt" 2>&1 || true
  if [[ "$status" -ne 0 ]]; then
    timeout 15s adb exec-out screencap -p > "$ARTIFACTS/failure.png" || true
  fi
  exit "$status"
}
trap collect_diagnostics EXIT

[[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 1; }
timeout 60s adb install --no-streaming -r "$APK" | tee "$ARTIFACTS/install.txt"
timeout 15s adb shell input keyevent KEYCODE_WAKEUP
timeout 15s adb shell wm dismiss-keyguard
timeout 15s adb shell am force-stop "$PACKAGE"
timeout 15s adb logcat -c
timeout 30s adb shell am start -W -n "$ACTIVITY" | tee "$ARTIFACTS/launch.txt"
# am start can report an error while adb still exits successfully.
grep -q '^Status: ok' "$ARTIFACTS/launch.txt" || {
  echo 'Android did not report a successful activity launch' >&2
  exit 1
}

APP_PID="$(timeout 15s adb shell pidof "$PACKAGE" | tr -d '\r')"
[[ -n "$APP_PID" ]] || { echo 'App process did not start' >&2; exit 1; }

# Let Flutter draw its startup UI and catch delayed crashes or process restarts.
for ((attempt = 0; attempt < 20; attempt++)); do
  sleep 1
  CURRENT_PID="$(timeout 15s adb shell pidof "$PACKAGE" | tr -d '\r')"
  [[ "$CURRENT_PID" == "$APP_PID" ]] || {
    echo 'App process exited or restarted during startup' >&2
    exit 1
  }
done

timeout 15s adb shell dumpsys activity activities > "$ARTIFACTS/activities.txt"
grep -E '(mResumedActivity|topResumedActivity)' "$ARTIFACTS/activities.txt" | grep -F "$ACTIVITY" || {
  echo 'App activity is not in the foreground' >&2
  exit 1
}
timeout 15s adb logcat -d --pid="$APP_PID" -v threadtime > "$ARTIFACTS/app-logcat.txt"
if grep -E 'FATAL EXCEPTION|Fatal signal|Unhandled Exception' "$ARTIFACTS/app-logcat.txt"; then
  echo 'App reported a fatal error during startup' >&2
  exit 1
fi

timeout 15s adb exec-out screencap -p > "$ARTIFACTS/startup.png"
[[ -s "$ARTIFACTS/startup.png" ]] || { echo 'Startup screenshot is empty' >&2; exit 1; }
echo "APK startup verified; screenshot saved to $ARTIFACTS/startup.png"
