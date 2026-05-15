#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RETROARCH_VERSION="${RETROARCH_VERSION:-v1.22.2}"
RETROARCH_UPSTREAM_URL="${RETROARCH_UPSTREAM_URL:-https://github.com/libretro/RetroArch.git}"
RETROARCH_WORKDIR="${RETROARCH_WORKDIR:-$REPO_ROOT/workdir}"
RETROARCH_SRC_DIR="${RETROARCH_SRC_DIR:-$RETROARCH_WORKDIR/src/RetroArch}"

mkdir -p "$(dirname "$RETROARCH_SRC_DIR")"

if [[ ! -d "$RETROARCH_SRC_DIR/.git" ]]; then
    echo "Cloning RetroArch into $RETROARCH_SRC_DIR"
    git clone "$RETROARCH_UPSTREAM_URL" "$RETROARCH_SRC_DIR"
fi

if [[ -n "$(git -C "$RETROARCH_SRC_DIR" status --porcelain)" ]]; then
    echo "Refusing to update dirty source checkout: $RETROARCH_SRC_DIR" >&2
    echo "Clean or recreate the workdir checkout before refetching." >&2
    exit 1
fi

git -C "$RETROARCH_SRC_DIR" remote set-url origin "$RETROARCH_UPSTREAM_URL"
git -C "$RETROARCH_SRC_DIR" fetch --tags --prune origin
git -C "$RETROARCH_SRC_DIR" checkout --detach "$RETROARCH_VERSION"
git -C "$RETROARCH_SRC_DIR" submodule update --init --recursive

echo "RetroArch source ready:"
echo "  version: $RETROARCH_VERSION"
echo "  path:    $RETROARCH_SRC_DIR"
