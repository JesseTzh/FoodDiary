#!/usr/bin/env bash
# Smoke-test the release APK on the emulator started by android-emulator-runner.
set -euo pipefail

APK="${1:?Usage: bash scripts/ci/verify-android-startup.sh path/to/app-release.apk}"
PACKAGE=com.jessetzh.fooddiary
ACTIVITY="$PACKAGE/.MainActivity"
ARTIFACTS=android-startup-artifacts
mkdir -p "$ARTIFACTS"

log() {
  printf '[android-startup] %s\n' "$*"
}

log_command() {
  log "${1}"
}

collect_diagnostics() {
  local status=$?
  trap - EXIT
  log "Collecting diagnostics (exit status: ${status})"
  timeout 15s adb logcat -d -v threadtime > "$ARTIFACTS/logcat.txt" 2>&1 || true
  timeout 15s adb shell dumpsys activity activities > "$ARTIFACTS/activities.txt" 2>&1 || true
  timeout 15s adb shell dumpsys window > "$ARTIFACTS/windows.txt" 2>&1 || true
  if [[ "$status" -ne 0 ]]; then
    timeout 15s adb exec-out screencap -p > "$ARTIFACTS/failure.png" || true
    log 'Recent Android logcat:'
    tail -n 120 "$ARTIFACTS/logcat.txt" || true
    log 'Activity state:'
    grep -E '(mResumedActivity|topResumedActivity|mFocusedApp)' \
      "$ARTIFACTS/activities.txt" || true
    if [[ -s "$ARTIFACTS/app-logcat.txt" ]]; then
      log 'Application logcat:'
      tail -n 120 "$ARTIFACTS/app-logcat.txt" || true
    fi
  fi
  log "Diagnostics saved under ${ARTIFACTS}/"
  exit "$status"
}
trap collect_diagnostics EXIT

log "Starting APK smoke test: ${APK}"
log_command 'Emulator properties'
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
[[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 1; }
log "APK size: $(wc -c < "$APK") bytes"
log_command 'Installing APK'
timeout 60s adb install --no-streaming -r "$APK" | tee "$ARTIFACTS/install.txt"
log_command 'Waking emulator and dismissing keyguard'
timeout 15s adb shell input keyevent KEYCODE_WAKEUP
timeout 15s adb shell wm dismiss-keyguard
log_command "Stopping ${PACKAGE} and clearing logcat"
timeout 15s adb shell am force-stop "$PACKAGE"
timeout 15s adb logcat -c
log_command "Launching ${ACTIVITY}"
timeout 30s adb shell am start -W -n "$ACTIVITY" | tee "$ARTIFACTS/launch.txt"
log 'Launch response:'
cat "$ARTIFACTS/launch.txt"
# am start can report an error while adb still exits successfully.
grep -q '^Status: ok' "$ARTIFACTS/launch.txt" || {
  echo 'Android did not report a successful activity launch' >&2
  exit 1
}

APP_PID="$(timeout 15s adb shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}')"
if [[ -z "$APP_PID" ]]; then
  echo 'App process did not start' >&2
  exit 1
fi
log "Application process started with PID ${APP_PID}"

# Let Flutter draw its startup UI and catch delayed crashes. Android may replace
# the process during Flutter/plugin initialization, so verify that the package
# remains alive instead of requiring one PID for the entire interval.
for ((attempt = 0; attempt < 20; attempt++)); do
  sleep 1
  CURRENT_PID="$(timeout 15s adb shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}')"
  [[ -n "$CURRENT_PID" ]] || {
    echo 'App process exited during startup' >&2
    exit 1
  }
  log "Startup check ${attempt}/20: process ${CURRENT_PID} is alive"
done

log_command 'Checking foreground activity'
timeout 15s adb shell dumpsys activity activities > "$ARTIFACTS/activities.txt"
if ! grep -E '(mResumedActivity|topResumedActivity)' "$ARTIFACTS/activities.txt" | grep -Fq "$ACTIVITY"; then
  echo 'App activity is not in the foreground' >&2
  exit 1
fi
CURRENT_PID="$(timeout 15s adb shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}')"
log "Collecting application logcat for PID ${CURRENT_PID}"
timeout 15s adb logcat -d --pid="$CURRENT_PID" -v threadtime > "$ARTIFACTS/app-logcat.txt"
if grep -E 'FATAL EXCEPTION|Fatal signal|Unhandled Exception' "$ARTIFACTS/app-logcat.txt"; then
  echo 'App reported a fatal error during startup' >&2
  exit 1
fi

timeout 15s adb exec-out screencap -p > "$ARTIFACTS/startup.png"
[[ -s "$ARTIFACTS/startup.png" ]] || { echo 'Startup screenshot is empty' >&2; exit 1; }
log "APK startup verified; screenshot saved to ${ARTIFACTS}/startup.png"
