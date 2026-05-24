#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-/Volumes/Storage/UMRK/mlp1-toolchain}"
RETROARCH_SRC_DIR="${RETROARCH_SRC_DIR:-$REPO_ROOT/workdir/src/RetroArch}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
OUTPUT_BIN_DIR="${OUTPUT_BIN_DIR:-$OUTPUT_DIR/bin}"
JOBS="${JOBS:-}"
MLP1_NATIVE_WAYLAND="${MLP1_NATIVE_WAYLAND:-auto}"
MLP1_ENABLE_UDEV="${MLP1_ENABLE_UDEV:-auto}"

if [[ "${IN_MLP1_CONTAINER:-0}" != "1" ]]; then
    if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
        echo "missing Docker image: $TOOLCHAIN_IMAGE" >&2
        echo "build it with: make -C $TOOLCHAIN_REPO image" >&2
        exit 1
    fi

    docker run --rm \
        -e IN_MLP1_CONTAINER=1 \
        -e RETROARCH_VERSION="${RETROARCH_VERSION:-}" \
        -e RETROARCH_UPSTREAM_URL="${RETROARCH_UPSTREAM_URL:-}" \
        -e RETROARCH_SRC_DIR=/workspace/workdir/src/RetroArch \
        -e OUTPUT_DIR=/workspace/output/mlp1 \
        -e OUTPUT_BIN_DIR=/workspace/output/mlp1/bin \
        -e JOBS="${JOBS:-}" \
        -e MLP1_NATIVE_WAYLAND="$MLP1_NATIVE_WAYLAND" \
        -e MLP1_ENABLE_UDEV="$MLP1_ENABLE_UDEV" \
        -v "$REPO_ROOT":/workspace \
        -v "$TOOLCHAIN_REPO":/mlp1-toolchain:ro \
        -w /workspace \
        "$TOOLCHAIN_IMAGE" \
        /workspace/build-mlp1.sh "$@"
    exit $?
fi

JOBS="${JOBS:-$(nproc)}"

"$REPO_ROOT/fetch-retroarch.sh"

cd "$RETROARCH_SRC_DIR"

wayland_flag="--disable-wayland"
case "$MLP1_NATIVE_WAYLAND" in
    1|true|yes|on)
        wayland_flag="--enable-wayland"
        ;;
    0|false|no|off)
        wayland_flag="--disable-wayland"
        ;;
    auto)
        if pkg-config --exists wayland-client wayland-egl; then
            wayland_flag="--enable-wayland"
        else
            echo "Native Wayland development files not present in the MLP1 SDK; using SDL2 video path."
        fi
        ;;
    *)
        echo "invalid MLP1_NATIVE_WAYLAND=$MLP1_NATIVE_WAYLAND" >&2
        exit 1
        ;;
esac

udev_flag="--disable-udev"
case "$MLP1_ENABLE_UDEV" in
    1|true|yes|on)
        udev_flag="--enable-udev"
        ;;
    0|false|no|off)
        udev_flag="--disable-udev"
        ;;
    auto)
        if pkg-config --exists libudev; then
            udev_flag="--enable-udev"
        else
            echo "libudev development files not present in the MLP1 SDK; using SDL2 input path."
        fi
        ;;
    *)
        echo "invalid MLP1_ENABLE_UDEV=$MLP1_ENABLE_UDEV" >&2
        exit 1
        ;;
esac

make distclean >/dev/null 2>&1 || true

export CFLAGS="${CFLAGS:-} -O2 -mcpu=cortex-a55 -ffunction-sections -fdata-sections -D_GNU_SOURCE"
export CXXFLAGS="${CXXFLAGS:-} -O2 -mcpu=cortex-a55 -ffunction-sections -fdata-sections -D_GNU_SOURCE"
export LDFLAGS="${LDFLAGS:-} -Wl,--gc-sections"
export PKG_CONF_PATH="${PKG_CONF_PATH:-pkg-config}"
export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-$SYSROOT}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig}"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$PKG_CONFIG_LIBDIR}"

./configure --host="$CROSS_TRIPLE" \
    --disable-qt \
    --disable-discord \
    --disable-x11 \
    "$wayland_flag" \
    --disable-pulse \
    --disable-jack \
    --disable-oss \
    --disable-vulkan \
    --disable-vulkan_display \
    --disable-opengl1 \
    --disable-opengl_core \
    --disable-kms \
    --disable-ssl \
    --disable-networking \
    --enable-sdl2 \
    --enable-alsa \
    "$udev_flag" \
    --enable-freetype \
    --enable-zlib \
    --enable-opengles \
    --enable-opengles3 \
    --enable-egl

make -j"$JOBS"

mkdir -p "$OUTPUT_BIN_DIR"
cp -f retroarch "$OUTPUT_BIN_DIR/retroarch"
"${STRIP:-aarch64-buildroot-linux-gnu-strip}" -s "$OUTPUT_BIN_DIR/retroarch"

if [[ -x /mlp1-toolchain/scripts/verify-binary.sh ]]; then
    /mlp1-toolchain/scripts/verify-binary.sh "$OUTPUT_BIN_DIR/retroarch"
fi

echo "MLP1 RetroArch built: $OUTPUT_BIN_DIR/retroarch"
