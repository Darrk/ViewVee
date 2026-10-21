#!/usr/bin/env bash
# Records the camera-side screen for the Google Play foreground service
# declaration video: pair -> monitoring -> app to background -> still streaming.
#
# Usage: tool/record_play_review.sh [device-serial]   (default: first adb device)
# Output: build/play_review/camera_side.mp4

set -euo pipefail

cd "$(dirname "$0")/.."
SERIAL="${1:-$(adb devices | awk 'NR==2 {print $1}')}"
OUT_DIR=build/play_review
REMOTE=/sdcard/viewvee_play_review.mp4
mkdir -p "$OUT_DIR"

adb_() { adb -s "$SERIAL" "$@"; }

echo "Building and installing release build on $SERIAL..."
flutter build apk --release
adb_ install -r build/app/outputs/flutter-apk/app-release.apk
adb_ shell pm grant com.specterint.viewvee android.permission.POST_NOTIFICATIONS || true

# Show taps so the reviewer can follow the flow.
adb_ shell settings put system show_touches 1

echo "Recording (max 180 s). Press Enter to stop early."
adb_ shell screenrecord --bit-rate 8000000 --time-limit 180 "$REMOTE" &
REC_PID=$!
sleep 1
adb_ shell monkey -p com.specterint.viewvee -c android.intent.category.LAUNCHER 1 >/dev/null

cat <<'STEPS'

Do this now, while it records:
  1. On the emulator: choose the camera role, start monitoring -> QR code appears.
  2. On your real phone (viewer): scan the QR code from your PC screen.
  3. Show the live picture on the phone for a few seconds.
  4. On the emulator: press Home. Pull down the notification shade so the
     ongoing "monitoring" notification is visible.
  5. Show on the phone that video/audio is still live (wave at the webcam).
  6. Return to the app and stop monitoring.
STEPS

read -r || true
adb_ shell pkill -INT screenrecord || true
wait "$REC_PID" 2>/dev/null || true
sleep 2
adb_ pull "$REMOTE" "$OUT_DIR/camera_side.mp4"
adb_ shell rm "$REMOTE"
adb_ shell settings put system show_touches 0
echo "Saved $OUT_DIR/camera_side.mp4"
