#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
LEAF_ROOT="${LEAF_ROOT:-$WORKSPACE_ROOT/Leaf}"
RESOLVER="$LEAF_ROOT/scripts/adb-resolve-umrk-sd.sh"
REPORT_TOOL="$ROOT_DIR/scripts/mlp1_shader_performance_report.py"
MANIFEST="${SHADER_MANIFEST:-$ROOT_DIR/output/mlp1/shaders/manifest.json}"
RETROARCH_BUILD_MANIFEST="${SHADER_PERF_RETROARCH_BUILD_MANIFEST:-$ROOT_DIR/output/mlp1/build-manifest.json}"
RETROARCH_BINARY="${SHADER_PERF_RETROARCH_BINARY:-$ROOT_DIR/output/mlp1/bin/retroarch}"
PRESET="${SHADER_PERF_PRESET:-}"
CORE_ID="${SHADER_PERF_CORE_ID:-}"
REMOTE_CONTENT="${SHADER_PERF_REMOTE_CONTENT:-}"
CONTENT_CLASS="${SHADER_PERF_CONTENT_CLASS:-}"
DURATION_SECONDS="${SHADER_PERF_SECONDS:-60}"
SAMPLE_INTERVAL_SECONDS="${SHADER_PERF_SAMPLE_INTERVAL:-15}"
WARMUP_SECONDS="${SHADER_PERF_WARMUP_SECONDS:-10}"
REFRESH_HZ="${SHADER_PERF_REFRESH_HZ:-60}"
BFI="${SHADER_PERF_BFI:-0}"
REMOTE_DIR="${SHADER_PERF_REMOTE_DIR:-/tmp/leaf-shader-performance}"
PORT="${SHADER_PERF_PORT:-55358}"
RESULT_ROOT="${SHADER_PERF_RESULTS_DIR:-$ROOT_DIR/output/mlp1/shader-performance}"
RESULT_DIR="$RESULT_ROOT/$(date +%Y%m%d-%H%M%S)"
LOCAL_WORK="$(mktemp -d "${TMPDIR:-/tmp}/leaf-shader-performance.XXXXXX")"
REMOTE_READY=0
REFRESH_CHANGED=0
ORIGINAL_REFRESH_HZ=""

for variable in PRESET CORE_ID REMOTE_CONTENT CONTENT_CLASS; do
    [ -n "${!variable}" ] || {
        echo "missing required performance input: $variable" >&2
        exit 2
    }
done
for integer in "$DURATION_SECONDS" "$SAMPLE_INTERVAL_SECONDS" "$WARMUP_SECONDS"; do
    case "$integer" in
        *[!0-9]*|"") echo "performance durations must be positive integers" >&2; exit 2 ;;
    esac
    [ "$integer" -gt 0 ] || { echo "performance durations must be positive" >&2; exit 2; }
done
case "$REFRESH_HZ" in
    60|120) ;;
    *) echo "SHADER_PERF_REFRESH_HZ must be 60 or 120" >&2; exit 2 ;;
esac
case "$BFI" in
    0|1) ;;
    *) echo "SHADER_PERF_BFI must be 0 or 1" >&2; exit 2 ;;
esac
if [ "$BFI" = "1" ] && [ "$REFRESH_HZ" != "120" ]; then
    echo "Black Frame Insertion qualification requires 120 Hz" >&2
    exit 2
fi
if [ "$DURATION_SECONDS" -lt 60 ] && [ "${SHADER_PERF_ALLOW_SHORT:-0}" != "1" ]; then
    echo "SHADER_PERF_SECONDS must be at least 60 for recommendation evidence" >&2
    exit 2
fi
case "$CORE_ID" in
    *[!A-Za-z0-9_-]*|"") echo "invalid SHADER_PERF_CORE_ID" >&2; exit 2 ;;
esac
case "$REMOTE_CONTENT" in
    *"'"*|*'"'*|*'$'*|*'`'*|*\\*)
        echo "SHADER_PERF_REMOTE_CONTENT contains unsupported shell characters" >&2
        exit 2
        ;;
esac
case "$REMOTE_DIR" in
    /tmp/leaf-shader-performance|/tmp/leaf-shader-performance-*) ;;
    *) echo "SHADER_PERF_REMOTE_DIR must remain under /tmp/leaf-shader-performance*" >&2; exit 2 ;;
esac

for path in \
    "$RESOLVER" "$REPORT_TOOL" "$MANIFEST" \
    "$RETROARCH_BUILD_MANIFEST" "$RETROARCH_BINARY"; do
    [ -f "$path" ] || { echo "missing performance input: $path" >&2; exit 1; }
done
for command in adb python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "$command is required for MLP1 shader performance testing" >&2
        exit 1
    }
done

if [ "$PRESET" != "none" ]; then
    python3 - "$MANIFEST" "$PRESET" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
presets = {row["path"] for row in manifest["presets"]}
if sys.argv[2] not in presets:
    raise SystemExit(f"preset is not present in the generated bundle: {sys.argv[2]}")
PY
fi

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
REMOTE_SHADERS="${SHADER_PERF_REMOTE_SHADERS:-$REMOTE_SD/.umrk/mlp1/retroarch/.config/retroarch/shaders}"
REMOTE_PRESET="$REMOTE_SHADERS/$PRESET"
REMOTE_CTL="$REMOTE_PLATFORM/launcher/bin/jawaka-retroarchctl"
REMOTE_PLATFORM_CTL="$REMOTE_PLATFORM/launcher/bin/jawaka-platformctl"
REMOTE_CONFIG="$REMOTE_DIR/retroarch.cfg"
REMOTE_LOG="$REMOTE_DIR/retroarch.log"
REMOTE_CAPTURES="$REMOTE_DIR/display-captures"

for remote_path in \
    "$REMOTE_RETROARCH" "$REMOTE_CORE" "$REMOTE_INFO" \
    "$REMOTE_CTL" "$REMOTE_PLATFORM_CTL" "$REMOTE_CONTENT"; do
    "${ADB[@]}" shell "test -f '$remote_path'" || {
        echo "missing device performance input: $remote_path" >&2
        exit 1
    }
done
if [ "$PRESET" != "none" ]; then
    "${ADB[@]}" shell "test -f '$REMOTE_PRESET'" || {
        echo "missing device performance input: $REMOTE_PRESET" >&2
        exit 1
    }
fi
"${ADB[@]}" shell "command -v weston-screenshooter >/dev/null 2>&1" || {
    echo "weston-screenshooter is required on the device" >&2
    exit 1
}

mkdir -p "$RESULT_DIR/samples"

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
        "${ADB[@]}" exec-out cat "$REMOTE_LOG" >"$RESULT_DIR/retroarch.log" 2>/dev/null || true
        "${ADB[@]}" shell "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1 || true
    fi
    if [ "$REFRESH_CHANGED" = "1" ] && [ -n "$ORIGINAL_REFRESH_HZ" ]; then
        "${ADB[@]}" shell \
            "'$REMOTE_PLATFORM_CTL' request '{\"type\":\"platform-action\",\"action\":\"set-refresh-rate\",\"value\":$ORIGINAL_REFRESH_HZ}'" \
            >/dev/null 2>&1 || true
        sleep 3
    fi
    rm -rf "$LOCAL_WORK"
    set -e
}
trap cleanup EXIT HUP INT TERM

platform_refresh_hz() {
    local payload
    local _
    for _ in $(seq 1 20); do
        if payload="$("${ADB[@]}" shell "'$REMOTE_PLATFORM_CTL' status" 2>/dev/null)"; then
            if printf '%s' "$payload" |
                tr -d '\r' |
                python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["refresh_rate_hz"])'
            then
                return 0
            fi
        fi
        sleep 0.25
    done
    return 1
}

wait_for_refresh_hz() {
    local target="$1"
    local _
    for _ in $(seq 1 40); do
        [ "$(platform_refresh_hz 2>/dev/null || true)" = "$target" ] && return 0
        sleep 0.25
    done
    return 1
}

ORIGINAL_REFRESH_HZ="$(platform_refresh_hz)"
case "$ORIGINAL_REFRESH_HZ" in
    60|90|120) ;;
    *) echo "could not determine current MLP1 refresh rate" >&2; exit 1 ;;
esac
if [ "$ORIGINAL_REFRESH_HZ" != "$REFRESH_HZ" ]; then
    "${ADB[@]}" shell \
        "'$REMOTE_PLATFORM_CTL' request '{\"type\":\"platform-action\",\"action\":\"set-refresh-rate\",\"value\":$REFRESH_HZ}'"
    REFRESH_CHANGED=1
    wait_for_refresh_hz "$REFRESH_HZ" || {
        echo "MLP1 did not switch to ${REFRESH_HZ} Hz" >&2
        exit 1
    }
    sleep 2
fi

cat >"$LOCAL_WORK/retroarch.cfg" <<CFG
config_save_on_exit = "false"
video_driver = "gl"
video_context_driver = "sdl_gl"
video_threaded = "false"
video_fullscreen = "true"
video_windowed_fullscreen = "false"
video_vsync = "true"
video_refresh_rate = "$REFRESH_HZ.000000"
video_black_frame_insertion = "$BFI"
video_shader_enable = "false"
video_shader_dir = "$REMOTE_SHADERS"
video_gpu_screenshot = "true"
statistics_show = "true"
fps_update_interval = "30"
video_font_enable = "true"
video_font_size = "18.000000"
audio_driver = "alsa"
audio_mute = "true"
audio_sync = "true"
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
screenshot_directory = "$REMOTE_DIR/screenshots"
menu_driver = "rgui"
menu_pause_libretro = "true"
pause_nonactive = "false"
quit_press_twice = "false"
stdin_cmd_enable = "false"
log_verbosity = "true"
CFG

cat >"$LOCAL_WORK/launch-retroarch.sh" <<SH
#!/bin/sh
export XDG_RUNTIME_DIR=/var/run
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
export HOME="$REMOTE_DIR/home"
cd "$REMOTE_DIR" || exit 1
exec "$REMOTE_RETROARCH" --config "$REMOTE_CONFIG" \
    -L "$REMOTE_CORE" "$REMOTE_CONTENT" --verbose \
    >"$REMOTE_LOG" 2>&1 < /dev/null
SH

"${ADB[@]}" shell "rm -rf '$REMOTE_DIR' && mkdir -p \
    '$REMOTE_DIR/home' '$REMOTE_DIR/saves' '$REMOTE_DIR/states' \
    '$REMOTE_DIR/system' '$REMOTE_DIR/screenshots' '$REMOTE_CAPTURES'"
"${ADB[@]}" push "$LOCAL_WORK/retroarch.cfg" "$REMOTE_CONFIG" >/dev/null
"${ADB[@]}" push "$LOCAL_WORK/launch-retroarch.sh" "$REMOTE_DIR/launch-retroarch.sh" >/dev/null
"${ADB[@]}" shell "chmod 755 '$REMOTE_DIR/launch-retroarch.sh'"
REMOTE_READY=1

if "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1"; then
    echo "RetroArch is already running; quit the current game first." >&2
    exit 1
fi

"${ADB[@]}" shell "
: > '$REMOTE_DIR/paused-pids'
for name in loong_pangu jawakad jawaka-launcher jawaka-menu; do
    for pid in \$(pidof \"\$name\" 2>/dev/null || true); do
        grep -qx \"\$pid\" '$REMOTE_DIR/paused-pids' 2>/dev/null ||
            echo \"\$pid\" >> '$REMOTE_DIR/paused-pids'
        kill -STOP \"\$pid\" 2>/dev/null || true
    done
done
"

run_ctl() {
    local command="'$REMOTE_CTL' --timeout-ms 1500 --port '$PORT'"
    local arg
    for arg in "$@"; do
        case "$arg" in
            *"'"*) echo "unsupported quote in RetroArch command argument" >&2; return 4 ;;
        esac
        command="$command '$arg'"
    done
    "${ADB[@]}" shell "$command"
}

wait_for_port() {
    local _
    for _ in $(seq 1 40); do
        run_ctl status >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}

read_temperatures() {
    local destination="$1"
    # The single-quoted script is intentionally expanded by the remote shell.
    # shellcheck disable=SC2016
    "${ADB[@]}" shell '
for type_path in /sys/class/thermal/thermal_zone*/type; do
    [ -f "$type_path" ] || continue
    zone=${type_path%/type}
    printf "%s " "$(cat "$type_path")"
    cat "$zone/temp"
done
' | tr -d '\r' >"$destination"
}

capture_metrics() {
    local number="$1"
    local text_output="$RESULT_DIR/samples/sample-${number}.txt"

    run_ctl raw-request GET_PERF_INFO >"$text_output"
}

capture_display() {
    local remote_capture
    local display_capture="$RESULT_DIR/final-statistics-overlay.png"

    "${ADB[@]}" shell "
cd '$REMOTE_CAPTURES' &&
XDG_RUNTIME_DIR=/var/run WAYLAND_DISPLAY=wayland-0 \
    weston-screenshooter >/dev/null 2>&1
"
    remote_capture="$(
        "${ADB[@]}" shell \
            "find '$REMOTE_CAPTURES' -type f -name '*.png' | sort | tail -1" |
            tr -d '\r'
    )"
    [ -n "$remote_capture" ] || {
        echo "Weston did not create the final performance capture" >&2
        return 1
    }
    "${ADB[@]}" pull "$remote_capture" "$display_capture" >/dev/null
    "${ADB[@]}" shell "rm -f '$remote_capture'"
}

DISPLAY_MODE="$(
    "${ADB[@]}" shell \
        "XDG_RUNTIME_DIR=/var/run WAYLAND_DISPLAY=wayland-0 wayland-info 2>/dev/null" |
        awk '
        $1 == "mode:" {
            in_mode=1
            width=""
            height=""
            refresh=""
            next
        }
        in_mode && /width: .*height: .*refresh:/ {
            width=$2
            height=$5
            refresh=$8
            gsub(/,/, "", refresh)
        }
        in_mode && $1 == "flags:" {
            if ($0 ~ /current/) {
                print width "x" height "@" refresh "Hz"
                exit
            }
            in_mode=0
        }'
)"
[ -n "$DISPLAY_MODE" ] || {
    echo "could not resolve the compositor's current display mode" >&2
    exit 1
}
python3 - "$DISPLAY_MODE" "$REFRESH_HZ" <<'PY'
import re
import sys
match = re.fullmatch(r"\d+x\d+@([0-9.]+)Hz", sys.argv[1])
if not match or abs(float(match.group(1)) - int(sys.argv[2])) > 1.0:
    raise SystemExit(
        f"active display mode {sys.argv[1]!r} does not match requested "
        f"{sys.argv[2]} Hz"
    )
PY

echo "Device: $SERIAL"
echo "Display: $DISPLAY_MODE (requested ${REFRESH_HZ} Hz; BFI $BFI)"
echo "Preset: $PRESET"
echo "Core/content class: $CORE_ID / $CONTENT_CLASS"
echo "Warm-up: ${WARMUP_SECONDS}s"
echo "Duration: ${DURATION_SECONDS}s"
echo "Results: $RESULT_DIR"

read_temperatures "$RESULT_DIR/temperature-before.txt"
"${ADB[@]}" shell "start-stop-daemon -S -b -m \
    -p '$REMOTE_DIR/retroarch.pid' -x '$REMOTE_DIR/launch-retroarch.sh'"
wait_for_port || {
    echo "RetroArch command interface did not start" >&2
    "${ADB[@]}" shell "tail -160 '$REMOTE_LOG' 2>/dev/null || true"
    exit 1
}
if [ "$PRESET" != "none" ]; then
    run_ctl raw-send SET_SHADER "$REMOTE_PRESET" >/dev/null
fi
sleep "$WARMUP_SECONDS"
"${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1" || {
    echo "RetroArch exited while applying $PRESET" >&2
    exit 1
}
run_ctl raw-request GET_PERF_INFO >"$RESULT_DIR/baseline.txt"

elapsed=0
sample=1
while [ "$elapsed" -lt "$DURATION_SECONDS" ]; do
    remaining="$((DURATION_SECONDS - elapsed))"
    step="$SAMPLE_INTERVAL_SECONDS"
    [ "$remaining" -lt "$step" ] && step="$remaining"
    sleep "$step"
    elapsed="$((elapsed + step))"
    "${ADB[@]}" shell "pidof retroarch >/dev/null 2>&1" || {
        echo "RetroArch exited after ${elapsed}s" >&2
        exit 1
    }
    printf 'Sampling at %ss/%ss\n' "$elapsed" "$DURATION_SECONDS"
    capture_metrics "$(printf '%02d' "$sample")"
    sample="$((sample + 1))"
done

capture_display
read_temperatures "$RESULT_DIR/temperature-after.txt"
"${ADB[@]}" exec-out cat "$REMOTE_LOG" >"$RESULT_DIR/retroarch.log"
run_ctl quit >/dev/null
sleep 1

python3 "$REPORT_TOOL" \
    --samples "$RESULT_DIR/samples" \
    --baseline "$RESULT_DIR/baseline.txt" \
    --shader-manifest "$MANIFEST" \
    --retroarch-build-manifest "$RETROARCH_BUILD_MANIFEST" \
    --retroarch-binary "$RETROARCH_BINARY" \
    --log "$RESULT_DIR/retroarch.log" \
    --temperature-before "$RESULT_DIR/temperature-before.txt" \
    --temperature-after "$RESULT_DIR/temperature-after.txt" \
    --output "$RESULT_DIR/report.json" \
    --preset "$PRESET" \
    --core "$CORE_ID" \
    --content-class "$CONTENT_CLASS" \
    --content-name "${REMOTE_CONTENT##*/}" \
    --display-mode "$DISPLAY_MODE" \
    --requested-refresh-hz "$REFRESH_HZ" \
    --bfi "$BFI" \
    --warmup-seconds "$WARMUP_SECONDS" \
    --duration-seconds "$DURATION_SECONDS" \
    --sample-interval-seconds "$SAMPLE_INTERVAL_SECONDS"

echo "Performance report: $RESULT_DIR/report.json"
