#!/usr/bin/env bash
# Find the most recently built .app for a platform and launch/install it.
# Usage:
#   run-app.sh mac   <CONFIG> [FILE]
#   run-app.sh ios   <CONFIG> <SIM_NAME>  [FILE]
#   run-app.sh tvos  <CONFIG> <SIM_NAME>
set -euo pipefail

PLATFORM="${1:?platform}"
CONFIG="${2:-Debug}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"

find_app() { # <products-subdir> <app-name>
  ls -dt "$DERIVED"/GMApplePlayer-*/Build/Products/"$1"/"$2" 2>/dev/null | head -1
}

case "$PLATFORM" in
  mac)
    FILE="${3:-}"
    APP="$(find_app "$CONFIG" "GMApplePlayer-macOS.app")"
    [ -n "$APP" ] || { echo "no built macOS app; run 'make build-mac' first" >&2; exit 1; }
    echo "launching $APP"
    if [ -n "$FILE" ]; then open "$APP" --args --open "$FILE"; else open "$APP"; fi
    ;;
  ios)
    SIM="${3:?sim name}"; FILE="${4:-}"
    APP="$(find_app "$CONFIG-iphonesimulator" "GMApplePlayer-iOS.app")"
    [ -n "$APP" ] || { echo "no built iOS app; run 'make build-ios' first" >&2; exit 1; }
    open -a Simulator
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b 2>/dev/null || true
    echo "installing $APP on $SIM"
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" com.gm.appleplayer.ios
    [ -n "$FILE" ] && echo "note: push a file with 'xcrun simctl addmedia \"$SIM\" \"$FILE\"' or use Open URL"
    ;;
  tvos)
    SIM="${3:?sim name}"
    APP="$(find_app "$CONFIG-appletvsimulator" "GMApplePlayer-tvOS.app")"
    [ -n "$APP" ] || { echo "no built tvOS app; run 'make build-tvos' first" >&2; exit 1; }
    open -a Simulator
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b 2>/dev/null || true
    echo "installing $APP on $SIM"
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" com.gm.appleplayer.tvos
    ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac
