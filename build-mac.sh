#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RETROARCH_VERSION="${RETROARCH_VERSION:-v1.22.2}"
RETROARCH_WORKDIR="${RETROARCH_WORKDIR:-$REPO_ROOT/workdir}"
RETROARCH_SRC_DIR="${RETROARCH_SRC_DIR:-$RETROARCH_WORKDIR/src/RetroArch}"
RETROARCH_DERIVED_DATA="${RETROARCH_DERIVED_DATA:-$RETROARCH_WORKDIR/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/macos}"
RETROARCH_XCODE_PROJECT="${RETROARCH_XCODE_PROJECT:-pkg/apple/RetroArch.xcodeproj}"
RETROARCH_XCODE_SCHEME="${RETROARCH_XCODE_SCHEME:-RetroArch}"
RETROARCH_BUILD_CONFIGURATION="${RETROARCH_BUILD_CONFIGURATION:-Release}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
ARCHS="${ARCHS:-$(uname -m)}"

"$REPO_ROOT/bootstrap-mac.sh"
RETROARCH_VERSION="$RETROARCH_VERSION" \
RETROARCH_WORKDIR="$RETROARCH_WORKDIR" \
RETROARCH_SRC_DIR="$RETROARCH_SRC_DIR" \
"$REPO_ROOT/fetch-retroarch.sh"

PROJECT_PATH="$RETROARCH_SRC_DIR/$RETROARCH_XCODE_PROJECT"
APP_PATH="$RETROARCH_DERIVED_DATA/Build/Products/$RETROARCH_BUILD_CONFIGURATION/RetroArch.app"
BINARY_PATH="$APP_PATH/Contents/MacOS/RetroArch"

mkdir -p "$OUTPUT_DIR"

echo
echo "=== Building RetroArch for macOS ==="
echo "Source:      $RETROARCH_SRC_DIR"
echo "Project:     $PROJECT_PATH"
echo "Scheme:      $RETROARCH_XCODE_SCHEME"
echo "Config:      $RETROARCH_BUILD_CONFIGURATION"
echo "Arch:        $ARCHS"
echo "Deployment:  $MACOSX_DEPLOYMENT_TARGET"
echo "DerivedData: $RETROARCH_DERIVED_DATA"
echo "Output:      $OUTPUT_DIR"

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$RETROARCH_XCODE_SCHEME" \
    -configuration "$RETROARCH_BUILD_CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$RETROARCH_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=YES \
    build

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Build finished without producing $BINARY_PATH" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR/RetroArch.app"
cp -R "$APP_PATH" "$OUTPUT_DIR/RetroArch.app"
cp "$BINARY_PATH" "$OUTPUT_DIR/RetroArch"

echo
echo "=== Build complete ==="
echo "Binary: $OUTPUT_DIR/RetroArch"
echo "App:    $OUTPUT_DIR/RetroArch.app"
file "$OUTPUT_DIR/RetroArch"
