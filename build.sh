#!/bin/bash
# Builds Waterline.app for Apple Silicon and/or Intel Macs.
#
#   ./build.sh                 build for this Mac's chip
#   ./build.sh --all           build both: build/AppleSilicon/ and build/Intel/
#   ./build.sh --intel         build only the Intel version
#   ./build.sh --silicon       build only the Apple Silicon version
#   ./build.sh --zip           also package Waterline-AppleSilicon.zip / Waterline-Intel.zip
#   ./build.sh --install       also copy this Mac's version to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Waterline"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
# uname -m says x86_64 inside a Rosetta shell; ask the hardware instead.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then HOST_ARCH=arm64; else HOST_ARCH=x86_64; fi

ARCHS=()
ZIP=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --all) ARCHS=(arm64 x86_64) ;;
    --silicon) ARCHS+=(arm64) ;;
    --intel) ARCHS+=(x86_64) ;;
    --zip) ZIP=true ;;
    --install) INSTALL=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
[[ ${#ARCHS[@]} -eq 0 ]] && ARCHS=("$HOST_ARCH")

label() { [[ "$1" == arm64 ]] && echo "AppleSilicon" || echo "Intel"; }

for ARCH in "${ARCHS[@]}"; do
  LABEL="$(label "$ARCH")"
  APP="build/$LABEL/$APP_NAME.app"

  swift build -c release --arch "$ARCH"
  BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/Waterline" "$APP/Contents/MacOS/Waterline"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

  # Ad-hoc signature: enough to run locally and to register as a login item.
  # Release builds can be signed with a Developer ID by setting SIGN_IDENTITY.
  codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
  echo "Built $APP ($VERSION, $LABEL)"

  if $ZIP; then
    ZIP_PATH="build/$APP_NAME-$LABEL.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP" "$ZIP_PATH"
    echo "Packaged $ZIP_PATH"
  fi
done

if $INSTALL; then
  APP="build/$(label "$HOST_ARCH")/$APP_NAME.app"
  [[ -d "$APP" ]] || { echo "No build for this Mac's chip ($HOST_ARCH) to install" >&2; exit 1; }
  pkill -x Waterline 2>/dev/null || true
  # Wait for the old copy to exit, or `open` can fail with error -600.
  for _ in $(seq 1 50); do pgrep -x Waterline >/dev/null || break; sleep 0.1; done
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  open "/Applications/$APP_NAME.app"
  echo "Installed $(label "$HOST_ARCH") build to /Applications and launched"
fi
