#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MLP1_DEFAULT_SDCARD_PATH=/mnt/sdcard
TG5040_DEFAULT_SDCARD_PATH=/mnt/SDCARD

find_sdcard_root() {
    probe=$APP_DIR
    while [ "$probe" != "/" ] && [ -n "$probe" ]; do
        if [ -d "$probe/.system/leaf/platforms" ] ||
           [ -f "$probe/.system/leaf/launcher/env.sh" ] ||
           { [ -d "$probe/Apps" ] && [ -d "$probe/.system" ]; }; then
            printf '%s\n' "$probe"
            return 0
        fi
        probe=$(dirname "$probe")
    done

    case "$APP_DIR" in
        */Apps/*/*.pak) (CDPATH= cd -- "$APP_DIR/../../.." && pwd) ;;
        *) (CDPATH= cd -- "$APP_DIR/../.." && pwd) ;;
    esac
}

infer_platform() {
    case "$SDCARD_PATH" in
        "$MLP1_DEFAULT_SDCARD_PATH") printf '%s\n' mlp1; return 0 ;;
        "$TG5040_DEFAULT_SDCARD_PATH") printf '%s\n' tg5040; return 0 ;;
    esac

    case "$APP_DIR" in
        */Apps/*/*.pak)
            platform_dir=$(basename "$(dirname "$APP_DIR")")
            if [ "$platform_dir" != "shared" ]; then
                printf '%s\n' "$platform_dir"
                return 0
            fi
            ;;
    esac

    if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
        printf '%s\n' mac
        return 0
    fi

    echo "PLATFORM is not set; launch from Jawaka or source .system/leaf/platforms/<platform>/launcher/env.sh" >&2
    exit 1
}

PAK_SDCARD_ROOT=$(find_sdcard_root)
SDCARD_PATH=${SDCARD_PATH:-${JAWAKA_SDCARD_ROOT:-$PAK_SDCARD_ROOT}}
if [ -z "${PLATFORM:-}" ]; then
    PLATFORM=$(infer_platform)
fi
PLATFORM_ENV_FILE="$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh"

if [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
elif [ -f "$PLATFORM_ENV_FILE" ]; then
    . "$PLATFORM_ENV_FILE"
elif [ -n "${SDCARD_PATH:-}" ] && [ -f "$SDCARD_PATH/.system/leaf/launcher/env.sh" ]; then
    . "$SDCARD_PATH/.system/leaf/launcher/env.sh"
elif [ -f "$PAK_SDCARD_ROOT/.system/leaf/launcher/env.sh" ]; then
    . "$PAK_SDCARD_ROOT/.system/leaf/launcher/env.sh"
fi

SDCARD_PATH=${SDCARD_PATH:-${JAWAKA_SDCARD_ROOT:-$PAK_SDCARD_ROOT}}
if [ -z "${PLATFORM:-}" ]; then
    PLATFORM=$(infer_platform)
fi
if [ -z "${UMRK_LAUNCHER_PATH:-}" ]; then
    UMRK_LAUNCHER_PATH=$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher
fi
UMRK_BIN_PATH=${UMRK_BIN_PATH:-$UMRK_LAUNCHER_PATH/bin}

find_runner() {
    if [ -n "${JAWAKA_RETROARCH_RUNNER:-}" ] && [ -x "$JAWAKA_RETROARCH_RUNNER" ]; then
        printf '%s\n' "$JAWAKA_RETROARCH_RUNNER"
        return 0
    fi

    for candidate in \
        "$UMRK_BIN_PATH/jawaka-retroarch-runner" \
        "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/bin/jawaka-retroarch-runner" \
        "$SDCARD_PATH/.system/leaf/launcher/bin/jawaka-retroarch-runner"
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
