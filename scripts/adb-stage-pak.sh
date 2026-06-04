#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-build}
PACKAGE_DIR="$ROOT_DIR/$BUILD_DIR/package/RetroArch.pak"

if [ ! -d "$PACKAGE_DIR" ]; then
    echo "Package not found at $PACKAGE_DIR. Run 'make package-mlp1' first." >&2
    exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found" >&2
    exit 1
fi

SERIAL=${ADB_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
if [ -z "$SERIAL" ]; then
    echo "No attached adb device found" >&2
    exit 1
fi

ADB="adb -s $SERIAL"
REQUESTED_REMOTE_SDCARD_PATH="${REMOTE_SDCARD_PATH:-auto}"
RESOLVE_SDCARD_HELPER="$ROOT_DIR/../miniloong-launcher-switcher/scripts/adb-resolve-umrk-sd.sh"
if [ -x "$RESOLVE_SDCARD_HELPER" ]; then
    REMOTE_SDCARD_PATH=$(REMOTE_SDCARD_PATH="$REQUESTED_REMOTE_SDCARD_PATH" ADB_SERIAL="$SERIAL" "$RESOLVE_SDCARD_HELPER")
else
    if [ -z "$REQUESTED_REMOTE_SDCARD_PATH" ] || [ "$REQUESTED_REMOTE_SDCARD_PATH" = "auto" ]; then
        echo "Cannot auto-detect active UMRK SD: $RESOLVE_SDCARD_HELPER not found." >&2
        echo "Set REMOTE_SDCARD_PATH=/mnt/sdcard or REMOTE_SDCARD_PATH=/media/sdcard1." >&2
        exit 1
    fi
    REMOTE_SDCARD_PATH="$REQUESTED_REMOTE_SDCARD_PATH"
    $ADB shell "mountpoint -q '$REMOTE_SDCARD_PATH'" >/dev/null || {
        echo "$REMOTE_SDCARD_PATH is not mounted on the device." >&2
        exit 1
    }
fi
REMOTE_APPS_PATH="${REMOTE_APPS_PATH:-$REMOTE_SDCARD_PATH/Apps}"
REMOTE_DIR="${REMOTE_DIR:-$REMOTE_APPS_PATH/RetroArch.pak}"

echo "Deploying RetroArch.pak to $REMOTE_DIR"
$ADB shell "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
$ADB push "$PACKAGE_DIR/." "$REMOTE_DIR/" >/dev/null
$ADB shell "chmod 755 '$REMOTE_DIR/launch.sh' && find '$REMOTE_DIR' -maxdepth 3 -type f | sort"
