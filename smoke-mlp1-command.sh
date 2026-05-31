#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output/mlp1}"
BINARY="${BINARY:-$OUTPUT_DIR/bin/retroarch}"
BUILD_MANIFEST="${BUILD_MANIFEST:-$OUTPUT_DIR/build-manifest.json}"

if [[ ! -x "$BINARY" ]]; then
    echo "missing executable MLP1 RetroArch binary: $BINARY" >&2
    exit 1
fi

if [[ ! -f "$BUILD_MANIFEST" ]]; then
    echo "missing MLP1 build manifest: $BUILD_MANIFEST" >&2
    echo "run ./build-mlp1.sh before the command smoke check" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to inspect $BUILD_MANIFEST" >&2
    exit 1
fi

python3 - "$BUILD_MANIFEST" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())
flags = set(manifest.get("configure_flags", []))
missing = sorted({"--enable-networking", "--enable-command"} - flags)

if missing:
    print(
        f"manifest is missing command-capable configure flags: {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)

patch_controls = manifest.get("patch_controls", {})
patch_set = patch_controls.get("MLP1_PATCH_SET", "")
patches_applied = manifest.get("patches_applied", [])

expected_patch_sets = {
    "": [],
    "command-menu": ["mlp1/0001-command-menu-commands.patch"],
}

if patch_set not in expected_patch_sets:
    print(f"manifest has unknown MLP1_PATCH_SET: {patch_set}", file=sys.stderr)
    sys.exit(1)

expected_patches = expected_patch_sets[patch_set]
if patches_applied != expected_patches:
    print(
        "manifest patch list mismatch: "
        f"expected {expected_patches}, got {patches_applied}",
        file=sys.stderr,
    )
    sys.exit(1)

print("manifest_ok: command-capable MLP1 build flags are present")
if patch_set == "command-menu":
    print("manifest_ok: command-menu patch set is present")
    print(
        "device_required: launch this binary on MLP1 and send "
        "GET_INFO, GET_STATE_SLOT, SET_STATE_SLOT, SAVE_STATE_SLOT, "
        "GET_DISK_COUNT, GET_DISK_SLOT, SET_DISK_SLOT, GET_PATH savestate, "
        "PAUSE, UNPAUSE, MENU_TOGGLE, RESET, QUIT over the RetroArch command interface"
    )
else:
    print("manifest_ok: clean upstream command build has no MLP1 patches")
    print("device_required: launch this binary on MLP1 and send GET_STATUS, PAUSE_TOGGLE, MENU_TOGGLE, QUIT over the RetroArch command interface")
PY
