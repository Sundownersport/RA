#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$ROOT_DIR/performance-mlp1-shader.sh"
AGGREGATOR="$ROOT_DIR/scripts/mlp1_shader_performance_matrix.py"
MATRIX_ROOT="${SHADER_MATRIX_RESULTS_DIR:-$ROOT_DIR/output/mlp1/shader-performance-matrix/$(date +%Y%m%d-%H%M%S)}"
EXPECTED_CASES=18
FAILURES=0

mkdir -p "$MATRIX_ROOT"

if [ -n "${ADB_SERIAL:-}" ]; then
    MATRIX_SERIAL="$ADB_SERIAL"
else
    MATRIX_SERIAL="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[ -n "${MATRIX_SERIAL:-}" ] || {
    echo "No online adb device found." >&2
    exit 1
}
MATRIX_ADB=(adb -s "$MATRIX_SERIAL")
ROMS_ROOT="$(
    "${MATRIX_ADB[@]}" shell '
for root in /mnt/sdcard /media/sdcard1; do
    if [ -f "$root/Roms/PS/Tekken 3 (USA).chd" ]; then
        printf "%s\n" "$root"
    fi
done
' | tr -d '\r'
)"
if [ -z "$ROMS_ROOT" ] || [[ "$ROMS_ROOT" == *$'\n'* ]]; then
    echo "could not uniquely resolve the second-card ROM root" >&2
    exit 1
fi
echo "Second-card ROM root: $ROMS_ROOT"

run_case() {
    local case_id="$1"
    local preset="$2"
    local core="$3"
    local content="$4"
    local content_class="$5"
    local refresh="$6"
    local bfi="$7"

    echo
    echo "=== $case_id ==="
    if SHADER_PERF_RESULTS_DIR="$MATRIX_ROOT/$case_id" \
        SHADER_PERF_PRESET="$preset" \
        SHADER_PERF_CORE_ID="$core" \
        SHADER_PERF_REMOTE_CONTENT="$content" \
        SHADER_PERF_CONTENT_CLASS="$content_class" \
        SHADER_PERF_REFRESH_HZ="$refresh" \
        SHADER_PERF_BFI="$bfi" \
        "$HARNESS"; then
        echo "PASS $case_id"
    else
        echo "FAIL $case_id" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

SHARP='leaf-bundled/interpolation/sharp-bilinear-simple.glslp'
SCANLINES='leaf-bundled/scanlines/scanline-fract.glslp'
GBA_COLOR='leaf-bundled/handheld/gba-color.glslp'
GBC_COLOR='leaf-bundled/handheld/gbc-color.glslp'

GBC="$ROMS_ROOT/Roms/GBC/Legend of Zelda, The - Oracle of Ages (USA, Australia).zip"
GBA="$ROMS_ROOT/Roms/GBA/Advance Wars (USA) (Rev 1).zip"
NES="$ROMS_ROOT/Roms/FC/Adventure Island (USA).zip"
SNES="$ROMS_ROOT/Roms/SFC/ActRaiser (USA).zip"
PSX="$ROMS_ROOT/Roms/PS/Tekken 3 (USA).chd"

run_case sharp-gbc-60 "$SHARP" gambatte "$GBC" '160x144 handheld' 60 0
run_case sharp-nes-60 "$SHARP" fceumm "$NES" '240p 4:3 console' 60 0
run_case sharp-snes-60 "$SHARP" snes9x "$SNES" '224-line console' 60 0
run_case sharp-psx-60 "$SHARP" pcsx_rearmed "$PSX" 'high-resolution heavier core' 60 0
run_case sharp-psx-120 "$SHARP" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 0
run_case sharp-psx-120-bfi "$SHARP" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 1

run_case scanlines-nes-60 "$SCANLINES" fceumm "$NES" '240p 4:3 console' 60 0
run_case scanlines-snes-60 "$SCANLINES" snes9x "$SNES" '224-line console' 60 0
run_case scanlines-psx-60 "$SCANLINES" pcsx_rearmed "$PSX" 'high-resolution heavier core' 60 0
run_case scanlines-psx-120 "$SCANLINES" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 0
run_case scanlines-psx-120-bfi "$SCANLINES" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 1

run_case gba-color-gba-60 "$GBA_COLOR" mgba "$GBA" '240x160 handheld' 60 0
run_case gba-color-psx-60 "$GBA_COLOR" pcsx_rearmed "$PSX" 'heavier-core budget check' 60 0
run_case gba-color-gba-120 "$GBA_COLOR" mgba "$GBA" '240x160 handheld' 120 0
# mGBA cannot sustain 60 fps at 120 Hz with BFI even with shaders disabled.
# Keep that unsupported core/display combination out of the recommendation gate;
# the no-shader and Sharp Pixels control reports are recorded in
# shader-sources/mlp1-recommended.json.

run_case gbc-color-gbc-60 "$GBC_COLOR" gambatte "$GBC" '160x144 handheld' 60 0
run_case gbc-color-psx-60 "$GBC_COLOR" pcsx_rearmed "$PSX" 'heavier-core budget check' 60 0
run_case gbc-color-gbc-120 "$GBC_COLOR" gambatte "$GBC" '160x144 handheld' 120 0
run_case gbc-color-gbc-120-bfi "$GBC_COLOR" gambatte "$GBC" '160x144 handheld' 120 1

python3 "$AGGREGATOR" \
    --matrix-root "$MATRIX_ROOT" \
    --expected-cases "$EXPECTED_CASES" \
    --output "$MATRIX_ROOT/matrix.json" || FAILURES=$((FAILURES + 1))

echo "Matrix report: $MATRIX_ROOT/matrix.json"
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES qualification case(s) or aggregate gate(s) failed" >&2
    exit 1
fi
