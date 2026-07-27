#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
LEAF_ROOT="${LEAF_ROOT:-$WORKSPACE_ROOT/Leaf}"
RESOLVER="$LEAF_ROOT/scripts/adb-resolve-umrk-sd.sh"
MANIFEST="${SHADER_MANIFEST:-$ROOT_DIR/output/mlp1/shaders/manifest.json}"
FIXTURE="${SHADER_TEST_CONTENT:-$ROOT_DIR/tests/fixtures/mlp1-shader-test.p8}"
CORE_ID="${SHADER_TEST_CORE_ID:-fake08}"
REMOTE_CONTENT_SOURCE="${SHADER_TEST_REMOTE_CONTENT:-}"
RETROARCH_BUILD_MANIFEST="${RETROARCH_BUILD_MANIFEST:-$ROOT_DIR/output/mlp1/build-manifest.json}"
REMOTE_DIR="${SHADER_SMOKE_REMOTE_DIR:-/tmp/leaf-shader-smoke}"
PORT="${SHADER_SMOKE_PORT:-55357}"
REPEAT_COUNT="${SHADER_SMOKE_REPEAT_COUNT:-2}"
RESULT_ROOT="${SHADER_SMOKE_RESULTS_DIR:-$ROOT_DIR/output/mlp1/shader-smoke}"
RESULT_DIR="$RESULT_ROOT/$(date +%Y%m%d-%H%M%S)"
RESULT_TSV="$RESULT_DIR/results.tsv"
LOCAL_WORK="$(mktemp -d "${TMPDIR:-/tmp}/leaf-shader-smoke.XXXXXX")"
REMOTE_READY=0

case "$REMOTE_DIR" in
    /tmp/leaf-shader-smoke|/tmp/leaf-shader-smoke-*) ;;
    *)
        echo "SHADER_SMOKE_REMOTE_DIR must remain under /tmp/leaf-shader-smoke*" >&2
        exit 2
        ;;
esac

for path in "$RESOLVER" "$MANIFEST" "$RETROARCH_BUILD_MANIFEST"; do
    [ -f "$path" ] || { echo "missing shader smoke input: $path" >&2; exit 1; }
done
if [ -z "$REMOTE_CONTENT_SOURCE" ] && [ ! -f "$FIXTURE" ]; then
    echo "missing shader smoke fixture: $FIXTURE" >&2
    exit 1
fi
case "$CORE_ID" in
    *[!A-Za-z0-9_-]*|"")
        echo "SHADER_TEST_CORE_ID must be a libretro core basename" >&2
        exit 2
        ;;
esac
case "$REMOTE_CONTENT_SOURCE" in
    *"'"*|*'"'*|*'$'*|*'`'*|*\\*)
        echo "SHADER_TEST_REMOTE_CONTENT contains unsupported shell characters" >&2
        exit 2
        ;;
esac
command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required for manifest/report processing" >&2
    exit 1
}
command -v ffmpeg >/dev/null 2>&1 || {
    echo "ffmpeg is required for non-black screenshot validation" >&2
    exit 1
}

if [ -n "${ADB_SERIAL:-}" ]; then
    SERIAL="$ADB_SERIAL"
else
    SERIAL="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || { echo "No online adb device found." >&2; exit 1; }
ADB=(adb -s "$SERIAL")
"${ADB[@]}" get-state 2>/dev/null | grep -qx device || {
    echo "ADB device is not online: $SERIAL" >&2
    exit 1
}

REMOTE_SD="$(
    ADB_SERIAL="$SERIAL" PLATFORM_ID=mlp1 REMOTE_SDCARD_PATH=auto "$RESOLVER"
)"
REMOTE_PLATFORM="$REMOTE_SD/.system/leaf/platforms/mlp1"
REMOTE_RETROARCH="$REMOTE_PLATFORM/bin/retroarch"
REMOTE_CORE="$REMOTE_PLATFORM/cores/${CORE_ID}_libretro.so"
REMOTE_INFO="$REMOTE_PLATFORM/info/${CORE_ID}_libretro.info"
REMOTE_BUNDLE="$REMOTE_PLATFORM/shaders"
REMOTE_SHADERS="${SHADER_SMOKE_REMOTE_SHADERS:-$REMOTE_SD/.umrk/mlp1/retroarch/.config/retroarch/shaders}"
REMOTE_CTL="$REMOTE_PLATFORM/launcher/bin/jawaka-retroarchctl"
if [ -n "$REMOTE_CONTENT_SOURCE" ]; then
    REMOTE_FIXTURE="$REMOTE_CONTENT_SOURCE"
    CONTENT_KIND="device-provided"
else
    REMOTE_FIXTURE="$REMOTE_DIR/content/mlp1-shader-test.p8"
    CONTENT_KIND="committed-fixture"
fi
REMOTE_CONFIG="$REMOTE_DIR/retroarch.cfg"
REMOTE_LOG="$REMOTE_DIR/logs/retroarch.log"
REMOTE_SCREENSHOTS="$REMOTE_DIR/screenshots"
REMOTE_DISPLAY_SCREENSHOTS="$REMOTE_DIR/display-screenshots"

PRESETS=()
while IFS= read -r preset; do
    [ -n "$preset" ] && PRESETS+=("$preset")
done < <(python3 - "$MANIFEST" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for row in manifest["presets"]:
    print(row["path"])
PY
)
[ "${#PRESETS[@]}" -gt 0 ] || { echo "shader manifest has no presets" >&2; exit 1; }

mkdir -p "$RESULT_DIR"
printf 'preset\tpass\tduration_ms\tluma_yavg\tscreenshot\tmenu_screenshot\tlog\n' >"$RESULT_TSV"

cleanup() {
    set +e
    if [ "$REMOTE_READY" = "1" ]; then
        "${ADB[@]}" shell "'$REMOTE_CTL' --timeout-ms 500 --port '$PORT' quit" \
            >/dev/null 2>&1 || true
        "${ADB[@]}" shell "
REMOTE='$REMOTE_DIR'
if [ -f \"\$REMOTE/retroarch.pid\" ]; then
    pid=\$(cat \"\$REMOTE/retroarch.pid\" 2>/dev/null || true)
    [ -n \"\$pid\" ] && kill \"\$pid\" 2>/dev/null || true
fi
if [ -f \"\$REMOTE/paused-pids\" ]; then
    while read pid; do
        [ -n \"\$pid\" ] && kill -CONT \"\$pid\" 2>/dev/null || true
    done < \"\$REMOTE/paused-pids\"
fi
" >/dev/null 2>&1 || true
        "${ADB[@]}" pull "$REMOTE_DIR/logs/." "$RESULT_DIR/device-logs/" >/dev/null 2>&1 || true
        "${ADB[@]}" shell "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1 || true
    fi
    rm -rf "$LOCAL_WORK"
    set -e
}
trap cleanup EXIT HUP INT TERM

for remote_path in \
    "$REMOTE_RETROARCH" "$REMOTE_CORE" "$REMOTE_INFO" \
    "$REMOTE_BUNDLE/manifest.json" "$REMOTE_CTL"; do
    "${ADB[@]}" shell "test -f '$remote_path'" || {
        echo "missing staged device artifact: $remote_path" >&2
        exit 1
    }
done
if [ -n "$REMOTE_CONTENT_SOURCE" ]; then
    "${ADB[@]}" shell "test -f '$REMOTE_FIXTURE'" || {
        echo "device test content does not exist: $REMOTE_FIXTURE" >&2
        exit 1
    }
fi
"${ADB[@]}" shell "command -v weston-screenshooter >/dev/null 2>&1" || {
    echo "weston-screenshooter is required for the menu display check" >&2
    exit 1
}

echo "Using adb device: $SERIAL"
echo "Using platform payload: $REMOTE_PLATFORM"
echo "Writing results: $RESULT_DIR"

"${ADB[@]}" shell "rm -rf '$REMOTE_DIR' && mkdir -p \
    '$REMOTE_DIR/content' '$REMOTE_DIR/home' '$REMOTE_DIR/logs' \
    '$REMOTE_DIR/saves' '$REMOTE_DIR/states' '$REMOTE_DIR/system' \
    '$REMOTE_SCREENSHOTS' '$REMOTE_DISPLAY_SCREENSHOTS'"
if [ -z "$REMOTE_CONTENT_SOURCE" ]; then
    "${ADB[@]}" push "$FIXTURE" "$REMOTE_FIXTURE" >/dev/null
fi
REMOTE_READY=1

cat >"$LOCAL_WORK/retroarch.cfg" <<CFG
config_save_on_exit = "false"
video_driver = "gl"
video_context_driver = "sdl_gl"
video_threaded = "false"
video_fullscreen = "true"
video_windowed_fullscreen = "false"
video_shader_enable = "false"
video_shader_dir = "$REMOTE_SHADERS"
video_gpu_screenshot = "true"
audio_driver = "alsa"
audio_mute = "true"
input_driver = "sdl2"
input_joypad_driver = "sdl2"
input_autodetect_enable = "false"
network_cmd_enable = "true"
network_cmd_port = "$PORT"
libretro_directory = "$REMOTE_PLATFORM/cores"
libretro_info_path = "$REMOTE_PLATFORM/info"
system_directory = "$REMOTE_DIR/system"
savefile_directory = "$REMOTE_DIR/saves"
savestate_directory = "$REMOTE_DIR/states"
screenshot_directory = "$REMOTE_SCREENSHOTS"
rgui_browser_directory = "$REMOTE_DIR"
menu_driver = "rgui"
menu_pause_libretro = "true"
pause_nonactive = "false"
pause_on_disconnect = "false"
quit_press_twice = "false"
stdin_cmd_enable = "false"
log_verbosity = "true"
CFG
"${ADB[@]}" push "$LOCAL_WORK/retroarch.cfg" "$REMOTE_CONFIG" >/dev/null

cat >"$LOCAL_WORK/launch-retroarch.sh" <<SH
#!/bin/sh
export XDG_RUNTIME_DIR=/var/run
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
export HOME="$REMOTE_DIR/home"
cd "$REMOTE_DIR" || exit 1
exec "$REMOTE_RETROARCH" --config "$REMOTE_CONFIG" \
    -L "$REMOTE_CORE" "$REMOTE_FIXTURE" --verbose \
    >"$REMOTE_LOG" 2>&1 < /dev/null
SH
"${ADB[@]}" push "$LOCAL_WORK/launch-retroarch.sh" "$REMOTE_DIR/launch-retroarch.sh" >/dev/null
"${ADB[@]}" shell "chmod 755 '$REMOTE_DIR/launch-retroarch.sh'"

if "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1"; then
    echo "RetroArch is already running; quit the current game before shader qualification." >&2
    exit 1
fi

echo "Pausing the launcher stack for exclusive display ownership"
"${ADB[@]}" shell "
: > '$REMOTE_DIR/paused-pids'
for name in loong_pangu jawakad jawaka-launcher jawaka-menu; do
    for pid in \$(pidof \"\$name\" 2>/dev/null || true); do
        grep -qx \"\$pid\" '$REMOTE_DIR/paused-pids' 2>/dev/null || echo \"\$pid\" >> '$REMOTE_DIR/paused-pids'
        kill -STOP \"\$pid\" 2>/dev/null || true
    done
done
"
run_ctl() {
    local command="'$REMOTE_CTL' --timeout-ms 1500 --port '$PORT'"
    local arg
    for arg in "$@"; do
        case "$arg" in
            *"'"*)
                echo "unsupported quote in RetroArch command argument: $arg" >&2
                return 4
                ;;
        esac
        command="$command '$arg'"
    done
    "${ADB[@]}" shell "$command"
}

wait_for_port() {
    local ready=0
    local _
    for _ in $(seq 1 40); do
        if run_ctl status >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.25
    done
    [ "$ready" = "1" ]
}

wait_for_exit() {
    local _
    for _ in $(seq 1 40); do
        if ! "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1"; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

milliseconds() {
    python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

image_luma() {
    local image="$1"
    local metadata
    metadata="$(
        ffmpeg -hide_banner -loglevel info -i "$image" \
            -vf signalstats,metadata=print -frames:v 1 -f null - 2>&1
    )"
    printf '%s\n' "$metadata" |
        sed -n 's/.*lavfi\.signalstats\.YAVG=//p' |
        tail -1
}

image_difference() {
    local first="$1"
    local second="$2"
    local metadata
    metadata="$(
        ffmpeg -hide_banner -loglevel info -i "$first" -i "$second" \
            -filter_complex \
            '[0:v][1:v]blend=all_mode=difference,signalstats,metadata=print' \
            -frames:v 1 -f null - 2>&1
    )"
    printf '%s\n' "$metadata" |
        sed -n 's/.*lavfi\.signalstats\.YAVG=//p' |
        tail -1
}

wait_for_remote_png() {
    local directory="$1"
    local remote_path=""
    local size=""
    local previous_size=""
    local stable_count=0
    local _
    for _ in $(seq 1 40); do
        remote_path="$(
            "${ADB[@]}" shell \
                "find '$directory' -type f -name '*.png' | sort | tail -1" |
                tr -d '\r'
        )"
        if [ -n "$remote_path" ]; then
            size="$(
                "${ADB[@]}" shell "stat -c %s '$remote_path' 2>/dev/null" |
                    tr -d '\r'
            )"
            case "$size" in
                *[!0-9]*|"") stable_count=0 ;;
                0) stable_count=0 ;;
                "$previous_size") stable_count=$((stable_count + 1)) ;;
                *) stable_count=0 ;;
            esac
            if [ "$stable_count" -ge 2 ]; then
                printf '%s\n' "$remote_path"
                return 0
            fi
            previous_size="$size"
        fi
        sleep 0.25
    done
    return 1
}

capture_display() {
    local local_path="$1"
    local remote_path
    "${ADB[@]}" shell "
cd '$REMOTE_DISPLAY_SCREENSHOTS' &&
XDG_RUNTIME_DIR=/var/run WAYLAND_DISPLAY=wayland-0 \
    weston-screenshooter >/dev/null 2>&1
"
    remote_path="$(wait_for_remote_png "$REMOTE_DISPLAY_SCREENSHOTS")"
    [ -n "$remote_path" ] || {
        echo "Weston did not create a display screenshot" >&2
        return 1
    }
    "${ADB[@]}" pull "$remote_path" "$local_path" >/dev/null
    [ -s "$local_path" ] || {
        echo "Weston display screenshot is empty after transfer" >&2
        return 1
    }
    "${ADB[@]}" shell "rm -f '$remote_path'"
}

for preset_relative in "${PRESETS[@]}"; do
    remote_preset="$REMOTE_SHADERS/$preset_relative"
    preset_slug="${preset_relative//\//_}"
    echo "Qualifying $preset_relative"
    for pass in $(seq 1 "$REPEAT_COUNT"); do
        "${ADB[@]}" shell "rm -f '$REMOTE_LOG' '$REMOTE_DIR/retroarch.pid'; \
            rm -f '$REMOTE_SCREENSHOTS/'*.png 2>/dev/null || true; \
            rm -rf '$REMOTE_DIR/states' && mkdir -p '$REMOTE_DIR/states'"
        started_ms="$(milliseconds)"
        "${ADB[@]}" shell "start-stop-daemon -S -b -m \
            -p '$REMOTE_DIR/retroarch.pid' -x '$REMOTE_DIR/launch-retroarch.sh'"
        if ! wait_for_port; then
            echo "RetroArch command interface did not start for $preset_relative pass $pass" >&2
            "${ADB[@]}" shell "tail -160 '$REMOTE_LOG' 2>/dev/null || true"
            exit 1
        fi

        run_ctl raw-send SET_SHADER "$remote_preset" >/dev/null
        sleep 2
        "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1" || {
            echo "RetroArch exited while loading $preset_relative pass $pass" >&2
            exit 1
        }

        local_menu_screenshot=""
        if [ "$pass" = "1" ]; then
            run_ctl save-state >/dev/null
            sleep 2
            "${ADB[@]}" shell "find '$REMOTE_DIR/states' -type f | grep -q ." || {
                echo "save-state file was not created for $preset_relative" >&2
                exit 1
            }
            run_ctl load-state >/dev/null
            sleep 1

            run_ctl raw-send OPEN_MENU >/dev/null
            sleep 1
            local_menu_screenshot="$RESULT_DIR/${preset_slug%.glslp}-menu-display-pass1.png"
            capture_display "$local_menu_screenshot"
            run_ctl menu-toggle >/dev/null
            sleep 3
            gameplay_status="$(run_ctl status)"
            case "$gameplay_status" in
                *"result=ok"*) ;;
                *)
                    echo "RetroArch did not resume content after closing the menu for $preset_relative" >&2
                    printf '%s\n' "$gameplay_status" >&2
                    exit 1
                    ;;
            esac
            local_gameplay_display="$RESULT_DIR/${preset_slug%.glslp}-gameplay-display-pass1.png"
            capture_display "$local_gameplay_display"
        fi

        run_ctl raw-send SCREENSHOT >/dev/null
        sleep 1
        remote_screenshot="$(wait_for_remote_png "$REMOTE_SCREENSHOTS")"
        [ -n "$remote_screenshot" ] || {
            echo "RetroArch did not create a screenshot for $preset_relative pass $pass" >&2
            exit 1
        }

        if [ "$pass" = "1" ]; then
            run_ctl raw-send "SET_SHADER " >/dev/null
            sleep 1
            "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1" || {
                echo "RetroArch exited while clearing $preset_relative" >&2
                exit 1
            }
            run_ctl raw-send SET_SHADER "$remote_preset" >/dev/null
            sleep 1
            "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1" || {
                echo "RetroArch exited while reapplying $preset_relative" >&2
                exit 1
            }
        fi

        local_screenshot="$RESULT_DIR/${preset_slug%.glslp}-pass${pass}.png"
        local_log="$RESULT_DIR/${preset_slug%.glslp}-pass${pass}.log"
        "${ADB[@]}" pull "$remote_screenshot" "$local_screenshot" >/dev/null
        [ -s "$local_screenshot" ] || {
            echo "RetroArch screenshot is empty after transfer for $preset_relative pass $pass" >&2
            exit 1
        }
        "${ADB[@]}" exec-out cat "$REMOTE_LOG" >"$local_log"
        grep -Fq "[Shaders] Applying shader: \"$remote_preset\"." "$local_log" || {
            echo "RetroArch did not log the applied preset for $preset_relative pass $pass" >&2
            exit 1
        }
        if ! grep -Fq "[GLSL] Found GLSL vertex shader." "$local_log" ||
            ! grep -Fq "[GLSL] Found GLSL fragment shader." "$local_log" ||
            ! grep -Fq "[GLSL] Linking GLSL program." "$local_log"; then
            echo "RetroArch did not compile and link GLSL for $preset_relative pass $pass" >&2
            exit 1
        fi
        luma="$(image_luma "$local_screenshot")"
        python3 - "$luma" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 1.0:
    raise SystemExit(f"screenshot is black or transparent (YAVG={value})")
PY
        if [ -n "$local_menu_screenshot" ]; then
            menu_luma="$(image_luma "$local_menu_screenshot")"
            menu_difference="$(
                image_difference "$local_menu_screenshot" "$local_gameplay_display"
            )"
            python3 - "$menu_luma" "$menu_difference" <<'PY'
import sys
menu_luma = float(sys.argv[1])
difference = float(sys.argv[2])
if menu_luma <= 1.0:
    raise SystemExit(f"menu screenshot is black or transparent (YAVG={menu_luma})")
if difference <= 1.0:
    raise SystemExit(
        f"menu screenshot does not differ materially from gameplay (YAVG diff={difference})"
    )
PY
            [ "$(grep -Fc "[Shaders] Applying shader: \"$remote_preset\"." "$local_log")" -ge 2 ] || {
                echo "RetroArch did not reapply $preset_relative after clearing it" >&2
                exit 1
            }
            grep -Fq '[Shaders] Applying shader: "".' "$local_log" || {
                echo "RetroArch did not log a successful shader clear for $preset_relative" >&2
                exit 1
            }
        fi
        if grep -Eiq \
            '((shader|glsl).*(failed|failure|compile error|link error)|failed to (compile|link)|\[Command\].*failed)' \
            "$local_log"; then
            echo "shader/compiler failure found in $local_log" >&2
            grep -Ein \
                '((shader|glsl).*(failed|failure|compile error|link error)|failed to (compile|link)|\[Command\].*failed)' \
                "$local_log" >&2 || true
            exit 1
        fi

        run_ctl quit >/dev/null
        wait_for_exit || {
            echo "RetroArch did not quit cleanly for $preset_relative pass $pass" >&2
            exit 1
        }
        finished_ms="$(milliseconds)"
        duration_ms="$((finished_ms - started_ms))"
        menu_screenshot_name=""
        if [ -n "$local_menu_screenshot" ]; then
            menu_screenshot_name="$(basename "$local_menu_screenshot")"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$preset_relative" "$pass" "$duration_ms" "$luma" \
            "$(basename "$local_screenshot")" \
            "$menu_screenshot_name" \
            "$(basename "$local_log")" \
            >>"$RESULT_TSV"
    done
done

echo "Regressing Fugazi-style global automatic preset behavior"
REMOTE_AUTO_CONFIG_DIR="$REMOTE_DIR/home/.config/retroarch/config"
REMOTE_GLOBAL_PRESET="$REMOTE_AUTO_CONFIG_DIR/global.glslp"
REMOTE_AUTO_PRESET="$REMOTE_SHADERS/leaf-recommended/sharp-pixels.glslp"
REMOTE_BROWSE_PRESET="$REMOTE_SHADERS/leaf-recommended/subtle-scanlines.glslp"
AUTO_APPLY_LOG="$RESULT_DIR/fugazi-global-apply.log"
AUTO_CLEAR_LOG="$RESULT_DIR/fugazi-global-clear.log"

"${ADB[@]}" shell "
mkdir -p '$REMOTE_AUTO_CONFIG_DIR'
printf '%s\n' '#reference \"$REMOTE_AUTO_PRESET\"' > '$REMOTE_GLOBAL_PRESET'
sed -i 's/^video_shader_enable = .*/video_shader_enable = \"true\"/' '$REMOTE_CONFIG'
rm -f '$REMOTE_LOG' '$REMOTE_DIR/retroarch.pid'
"
GLOBAL_PRESET_HASH="$(
    "${ADB[@]}" shell "sha256sum '$REMOTE_GLOBAL_PRESET'" |
        awk '{print $1}' |
        tr -d '\r'
)"

"${ADB[@]}" shell "start-stop-daemon -S -b -m \
    -p '$REMOTE_DIR/retroarch.pid' -x '$REMOTE_DIR/launch-retroarch.sh'"
wait_for_port || {
    echo "RetroArch did not start for the Fugazi automatic-preset regression" >&2
    exit 1
}
sleep 2
"${ADB[@]}" exec-out cat "$REMOTE_LOG" >"$AUTO_APPLY_LOG"
if ! grep -Fq \
    "[Shaders] Specific shader preset found at \"$REMOTE_GLOBAL_PRESET\"." \
    "$AUTO_APPLY_LOG"; then
    echo "RetroArch did not auto-apply the Fugazi-style global preset" >&2
    exit 1
fi
if ! grep -Fq "[GLSL] Linking GLSL program." "$AUTO_APPLY_LOG"; then
    echo "the Fugazi-style global preset did not compile and link" >&2
    exit 1
fi

run_ctl raw-send SET_SHADER "$REMOTE_BROWSE_PRESET" >/dev/null
sleep 1
GLOBAL_PRESET_HASH_AFTER_BROWSE="$(
    "${ADB[@]}" shell "sha256sum '$REMOTE_GLOBAL_PRESET'" |
        awk '{print $1}' |
        tr -d '\r'
)"
[ "$GLOBAL_PRESET_HASH_AFTER_BROWSE" = "$GLOBAL_PRESET_HASH" ] || {
    echo "browsing the packaged bundle modified the automatic global preset" >&2
    exit 1
}
run_ctl quit >/dev/null
wait_for_exit || {
    echo "RetroArch did not quit after the Fugazi automatic-preset regression" >&2
    exit 1
}

"${ADB[@]}" shell "
rm -f '$REMOTE_GLOBAL_PRESET' '$REMOTE_LOG' '$REMOTE_DIR/retroarch.pid'
"
"${ADB[@]}" shell "start-stop-daemon -S -b -m \
    -p '$REMOTE_DIR/retroarch.pid' -x '$REMOTE_DIR/launch-retroarch.sh'"
wait_for_port || {
    echo "RetroArch did not start after clearing the Fugazi-style preset" >&2
    exit 1
}
sleep 2
"${ADB[@]}" exec-out cat "$REMOTE_LOG" >"$AUTO_CLEAR_LOG"
if grep -Fq "[Shaders] Specific shader preset found at " "$AUTO_CLEAR_LOG"; then
    echo "the cleared Fugazi-style global preset was still applied" >&2
    exit 1
fi
run_ctl quit >/dev/null
wait_for_exit || {
    echo "RetroArch did not quit after clearing the Fugazi-style preset" >&2
    exit 1
}

python3 - "$MANIFEST" "$RESULT_TSV" "$RESULT_DIR/report.json" "$SERIAL" \
    "$RETROARCH_BUILD_MANIFEST" "$CORE_ID" "$CONTENT_KIND" <<'PY'
import csv
import json
import sys
from datetime import datetime, timezone

(
    manifest_path,
    tsv_path,
    output_path,
    serial,
    build_manifest_path,
    core_id,
    content_kind,
) = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
build_manifest = json.load(open(build_manifest_path, encoding="utf-8"))
rows = list(csv.DictReader(open(tsv_path, encoding="utf-8"), delimiter="\t"))
by_preset = {}
for row in rows:
    row["pass"] = int(row["pass"])
    row["duration_ms"] = int(row["duration_ms"])
    row["luma_yavg"] = float(row["luma_yavg"])
    by_preset.setdefault(row["preset"], []).append(row)
report = {
    "schema_version": 1,
    "device_serial": serial,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "bundle_id": manifest["bundle_id"],
    "source": manifest["source"],
    "sources": manifest.get("sources", [manifest["source"]]),
    "retroarch_build": {
        "version": build_manifest["retroarch_version"],
        "commit": build_manifest["commit"],
        "build_profile": build_manifest["build_profile"],
    },
    "test_core": core_id,
    "test_content": content_kind,
    "qualification": "loads",
    "automatic_global_preset_regression": {
        "apply": "pass",
        "packaged_browser_preservation": "pass",
        "clear": "pass",
        "user_state_touched": False,
    },
    "presets": [
        {
            "path": preset["path"],
            "qualification": "loads",
            "passes": by_preset.get(preset["path"], []),
        }
        for preset in manifest["presets"]
    ],
}
json.dump(report, open(output_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
open(output_path, "a", encoding="utf-8").write("\n")
PY

echo "All ${#PRESETS[@]} presets passed $REPEAT_COUNT device load runs."
echo "Qualification report: $RESULT_DIR/report.json"
