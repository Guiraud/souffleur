#!/usr/bin/env bash

# Development build for Android: bumps the version in pubspec.yaml (patch and
# build number), builds a release APK and installs it on the connected device.
# Every build thus gets a distinct version, visible on the home screen as
# "x.y.z (Build n)" and in the Android app info.

set -euo pipefail

usage() {
  cat <<EOF
usage: dev_android.sh [-n] [-t entrypoint] [-h]
  -n             Build only, do not install on the device.
  -t entrypoint  Dart entrypoint (default: lib/main.dart).
  -h             Show this help.
  (i) Set ANDROID_SERIAL to pick a device when several are connected.
EOF
}

INSTALL=YES
ENTRYPOINT=lib/main.dart
while getopts "nt:h" opt; do
  case $opt in
    n) INSTALL= ;;
    t) ENTRYPOINT=$OPTARG ;;
    h)
      usage
      exit 0
      ;;
    \?)
      usage >&2
      exit 1
      ;;
  esac
done

# Run from the repo root regardless of where the script was invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Bundled toolchain when the .flutter submodule is checked out, system one otherwise.
FLUTTER=flutter
if [ -x .flutter/bin/flutter ]; then
  FLUTTER=.flutter/bin/flutter
fi

PUBSPEC="pubspec.yaml"
APK="build/app/outputs/flutter-apk/app-release.apk"

old_version="$(sed -nE 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -n1)"
if [[ ! "$old_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$ ]]; then
  echo "Unexpected version '$old_version' in $PUBSPEC (expected x.y.z+n)." >&2
  exit 1
fi
new_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))+$((BASH_REMATCH[4] + 1))"

set_version() {
  perl -pi -e "s/^version:.*/version: $1/" "$PUBSPEC"
}

set_version "$new_version"
echo "Version: $old_version -> $new_version"

if ! "$FLUTTER" build apk --release -t "$ENTRYPOINT"; then
  set_version "$old_version"
  echo "Build failed, version restored to $old_version." >&2
  exit 1
fi

if [ -z "$INSTALL" ]; then
  echo "Built $new_version: $APK"
  exit 0
fi

device="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
if [ -z "$device" ]; then
  echo "No Android device connected; built $new_version at $APK." >&2
  exit 1
fi

adb -s "$device" install -r "$APK"
echo "Installed $new_version on $device."
