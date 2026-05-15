#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "bootstrap-mac.sh only supports macOS." >&2
    exit 1
fi

require_tool() {
    local tool="$1"
    local hint="$2"

    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        echo "$hint" >&2
        exit 1
    fi
}

require_tool git "Install Xcode Command Line Tools with: xcode-select --install"
require_tool xcodebuild "Install Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
require_tool xcrun "Install Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

echo "=== macOS build host ==="
sw_vers

echo
echo "=== Xcode ==="
xcodebuild -version
echo "Developer dir: $(xcode-select -p)"
echo "macOS SDK: $(xcrun --sdk macosx --show-sdk-path)"

echo
echo "=== Homebrew ==="
if command -v brew >/dev/null 2>&1; then
    brew --version | head -n 1
    echo "No Homebrew formulae are required for the current non-Metal Xcode build path."
else
    echo "Homebrew not found."
    echo "It is optional for the current non-Metal Xcode build path, but recommended for future auxiliary tooling."
fi

echo
echo "Bootstrap complete."
