#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${LEAF_WORKSPACE_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LEAF_DIR="$WORKSPACE_DIR/Leaf"

if [ ! -f "$LEAF_DIR/Makefile" ]; then
    echo "Leaf checkout not found: $LEAF_DIR" >&2
    echo "Run app deployment from Leaf: make stage-app APP=retroarch-builds DEVICE=mlp1" >&2
    exit 1
fi

exec make -C "$LEAF_DIR" stage-app APP=retroarch-builds DEVICE=mlp1
