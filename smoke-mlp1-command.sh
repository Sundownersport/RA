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

if manifest.get("patches_applied") != []:
    print("manifest contains patches_applied entries; Phase 1 expects a clean build", file=sys.stderr)
    sys.exit(1)

print("manifest_ok: command-capable MLP1 build flags are present")
print("device_required: launch this binary on MLP1 and send GET_INFO, PAUSE, UNPAUSE, MENU_TOGGLE, QUIT over the RetroArch command interface")
PY
