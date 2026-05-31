#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ -n "${JAWAKA_SDCARD_ROOT:-}" ]; then
    SDROOT=$JAWAKA_SDCARD_ROOT
elif [ -d /mnt/sdcard ]; then
    SDROOT=/mnt/sdcard
else
    SDROOT=$(CDPATH= cd -- "$APP_DIR/../.." && pwd)
fi

find_runner() {
    if [ -n "${JAWAKA_RETROARCH_RUNNER:-}" ] && [ -x "$JAWAKA_RETROARCH_RUNNER" ]; then
        printf '%s\n' "$JAWAKA_RETROARCH_RUNNER"
        return 0
    fi

    for candidate in \
        "$SDROOT/umrk-launcher/bin/jawaka-retroarch-runner" \
        "/mnt/sdcard/umrk-launcher/bin/jawaka-retroarch-runner" \
        "/Volumes/Storage/UMRK/Jawaka/build/bin/jawaka-retroarch-runner" \
        "$APP_DIR/../../umrk-launcher/bin/jawaka-retroarch-runner"
    do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

RUNNER=$(find_runner) || {
    echo "jawaka-retroarch-runner not found" >&2
    exit 127
}

export JAWAKA_SDCARD_ROOT=$SDROOT
export JAWAKA_RETROARCH_APP_ROOT=$APP_DIR

exec "$RUNNER" --menu
