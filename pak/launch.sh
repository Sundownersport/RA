#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PAK_SDCARD_ROOT=$(CDPATH= cd -- "$APP_DIR/../.." && pwd)
MLP1_DEFAULT_SDCARD_PATH=/mnt/sdcard

if [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
elif [ -n "${SDCARD_PATH:-}" ] && [ -f "$SDCARD_PATH/.system/leaf/launcher/env.sh" ]; then
    . "$SDCARD_PATH/.system/leaf/launcher/env.sh"
elif [ -f "$PAK_SDCARD_ROOT/.system/leaf/launcher/env.sh" ]; then
    . "$PAK_SDCARD_ROOT/.system/leaf/launcher/env.sh"
fi

if [ -z "${PLATFORM:-}" ]; then
    case "$PAK_SDCARD_ROOT" in
        "$MLP1_DEFAULT_SDCARD_PATH") PLATFORM=mlp1 ;;
        *) PLATFORM=mac ;;
    esac
fi
SDCARD_PATH=${SDCARD_PATH:-${JAWAKA_SDCARD_ROOT:-$PAK_SDCARD_ROOT}}
if [ -z "${UMRK_LAUNCHER_PATH:-}" ]; then
    case "$PLATFORM" in
        *) UMRK_LAUNCHER_PATH=$SDCARD_PATH/.system/leaf/launcher ;;
    esac
fi
UMRK_BIN_PATH=${UMRK_BIN_PATH:-$UMRK_LAUNCHER_PATH/bin}

find_runner() {
    if [ -n "${JAWAKA_RETROARCH_RUNNER:-}" ] && [ -x "$JAWAKA_RETROARCH_RUNNER" ]; then
        printf '%s\n' "$JAWAKA_RETROARCH_RUNNER"
        return 0
    fi

    for candidate in \
        "$UMRK_BIN_PATH/jawaka-retroarch-runner" \
        "$APP_DIR/../../.system/leaf/launcher/bin/jawaka-retroarch-runner"
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

export PLATFORM
export SDCARD_PATH
export UMRK_LAUNCHER_PATH
export UMRK_BIN_PATH
export JAWAKA_SDCARD_ROOT=$SDCARD_PATH
export JAWAKA_RETROARCH_APP_ROOT=$APP_DIR

exec "$RUNNER" --menu
