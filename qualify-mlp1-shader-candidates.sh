#!/usr/bin/env bash
set -u

# Phase 2.3 performance gate for the five 2026-09-01 shader candidates.
#
# Modelled on qualify-mlp1-shader-expansion.sh. Cases are chosen per shader for
# the systems it is actually intended for: the LCD-grid shaders are qualified on
# handhelds, the CRT shaders on console classes, and every shader gets one
# heavier-core budget check so a recommendation cannot rest on light content
# alone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$ROOT_DIR/performance-mlp1-shader.sh"
AGGREGATOR="$ROOT_DIR/scripts/mlp1_shader_performance_matrix.py"
MATRIX_ROOT="${SHADER_MATRIX_RESULTS_DIR:-$ROOT_DIR/output/mlp1/shader-candidate-matrix/$(date +%Y%m%d-%H%M%S)}"
EXPECTED_CASES=20
FAILURES=0

mkdir -p "$MATRIX_ROOT"

if [ -n "${ADB_SERIAL:-}" ]; then
    MATRIX_SERIAL="$ADB_SERIAL"
else
    MATRIX_SERIAL="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[ -n "${MATRIX_SERIAL:-}" ] || { echo "No online adb device found." >&2; exit 1; }
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
    echo "could not uniquely resolve the ROM root" >&2
    exit 1
fi
echo "ROM root: $ROMS_ROOT"
echo "Results:  $MATRIX_ROOT"

run_case() {
    local case_id="$1" preset="$2" core="$3" content="$4" content_class="$5" refresh="$6" bfi="$7"
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

LCD3X='leaf-bundled/handheld/lcd3x.glslp'
ZLCD='leaf-bundled/handheld/zfast-lcd.glslp'
ZCRT='leaf-bundled/crt/zfast-crt.glslp'
ZGEO='leaf-bundled/crt/zfast_crt_geo.glslp'
ZCOMP='leaf-bundled/crt/zfast-composite.glslp'

GBC="$ROMS_ROOT/Roms/GBC/Legend of Zelda, The - Oracle of Ages (USA, Australia).zip"
GBA="$ROMS_ROOT/Roms/GBA/Advance Wars (USA) (Rev 1).zip"
NES="$ROMS_ROOT/Roms/FC/Adventure Island (USA).zip"
SNES="$ROMS_ROOT/Roms/SFC/ActRaiser (USA).zip"
PSX="$ROMS_ROOT/Roms/PS/Tekken 3 (USA).chd"

# LCD-grid shaders: handheld systems, plus a heavier-core budget check.
run_case lcd3x-gbc-60  "$LCD3X" gambatte "$GBC" '160x144 handheld' 60 0
run_case lcd3x-gba-60  "$LCD3X" mgba     "$GBA" '240x160 handheld' 60 0
run_case lcd3x-gbc-120 "$LCD3X" gambatte "$GBC" '160x144 handheld' 120 0
run_case lcd3x-psx-60  "$LCD3X" pcsx_rearmed "$PSX" 'heavier-core budget check' 60 0

run_case zlcd-gbc-60  "$ZLCD" gambatte "$GBC" '160x144 handheld' 60 0
run_case zlcd-gba-60  "$ZLCD" mgba     "$GBA" '240x160 handheld' 60 0
run_case zlcd-gbc-120 "$ZLCD" gambatte "$GBC" '160x144 handheld' 120 0
run_case zlcd-psx-60  "$ZLCD" pcsx_rearmed "$PSX" 'heavier-core budget check' 60 0

# CRT shaders: console classes at both refresh rates, plus the heavy core.
run_case zcrt-nes-60  "$ZCRT" fceumm "$NES"  '240p 4:3 console' 60 0
run_case zcrt-snes-60 "$ZCRT" snes9x "$SNES" '224-line console'  60 0
run_case zcrt-psx-60  "$ZCRT" pcsx_rearmed "$PSX" 'high-resolution heavier core' 60 0
run_case zcrt-psx-120 "$ZCRT" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 0

run_case zgeo-nes-60  "$ZGEO" fceumm "$NES"  '240p 4:3 console' 60 0
run_case zgeo-snes-60 "$ZGEO" snes9x "$SNES" '224-line console'  60 0
run_case zgeo-psx-60  "$ZGEO" pcsx_rearmed "$PSX" 'high-resolution heavier core' 60 0
run_case zgeo-psx-120 "$ZGEO" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 0

# zfast-composite is two-pass, so it gets the same coverage rather than less.
run_case zcomp-nes-60  "$ZCOMP" fceumm "$NES"  '240p 4:3 console' 60 0
run_case zcomp-snes-60 "$ZCOMP" snes9x "$SNES" '224-line console'  60 0
run_case zcomp-psx-60  "$ZCOMP" pcsx_rearmed "$PSX" 'high-resolution heavier core' 60 0
run_case zcomp-psx-120 "$ZCOMP" pcsx_rearmed "$PSX" 'high-resolution heavier core' 120 0

python3 "$AGGREGATOR" \
    --matrix-root "$MATRIX_ROOT" \
    --expected-cases "$EXPECTED_CASES" \
    --output "$MATRIX_ROOT/matrix.json" || FAILURES=$((FAILURES + 1))

echo
echo "Matrix report: $MATRIX_ROOT/matrix.json"
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES case(s) or aggregate gate(s) failed" >&2
    exit 1
fi
