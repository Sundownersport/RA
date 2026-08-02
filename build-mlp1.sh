#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TOOLCHAIN_REPO=""
if [[ -d "$REPO_ROOT/../mlp1-toolchain" ]]; then
    DEFAULT_TOOLCHAIN_REPO="$(cd "$REPO_ROOT/../mlp1-toolchain" && pwd)"
fi

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-$DEFAULT_TOOLCHAIN_REPO}"
RETROARCH_VERSION="${RETROARCH_VERSION:-v1.22.2}"
RETROARCH_UPSTREAM_URL="${RETROARCH_UPSTREAM_URL:-https://github.com/libretro/RetroArch.git}"
RETROARCH_SRC_DIR="${RETROARCH_SRC_DIR:-$REPO_ROOT/workdir/src/RetroArch}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
OUTPUT_BIN_DIR="${OUTPUT_BIN_DIR:-$OUTPUT_DIR/bin}"
BUILD_MANIFEST="${BUILD_MANIFEST:-$OUTPUT_DIR/build-manifest.json}"
JOBS="${JOBS:-}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-release}"
MLP1_NATIVE_WAYLAND="${MLP1_NATIVE_WAYLAND:-0}"
MLP1_ENABLE_UDEV="${MLP1_ENABLE_UDEV:-auto}"
MLP1_ENABLE_MALI_FBDEV="${MLP1_ENABLE_MALI_FBDEV:-0}"
MLP1_APPLY_COMMON_PATCHES="${MLP1_APPLY_COMMON_PATCHES:-0}"
MLP1_PATCH_SET="${MLP1_PATCH_SET:-}"

if [[ "${IN_MLP1_CONTAINER:-0}" != "1" ]]; then
    if [[ -z "$TOOLCHAIN_REPO" ]]; then
        echo "TOOLCHAIN_REPO is required when ../mlp1-toolchain is not present." >&2
        exit 1
    fi
    if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
        echo "missing Docker image: $TOOLCHAIN_IMAGE" >&2
        echo "build it with: make -C $TOOLCHAIN_REPO image" >&2
        exit 1
    fi

    docker run --rm \
        -e IN_MLP1_CONTAINER=1 \
        -e TOOLCHAIN_IMAGE="$TOOLCHAIN_IMAGE" \
        -e RETROARCH_VERSION="$RETROARCH_VERSION" \
        -e RETROARCH_UPSTREAM_URL="$RETROARCH_UPSTREAM_URL" \
        -e RETROARCH_SRC_DIR=/workspace/workdir/src/RetroArch \
        -e OUTPUT_DIR=/workspace/output/mlp1 \
        -e OUTPUT_BIN_DIR=/workspace/output/mlp1/bin \
        -e BUILD_MANIFEST=/workspace/output/mlp1/build-manifest.json \
        -e JOBS="${JOBS:-}" \
        -e MLP1_BUILD_PROFILE="$MLP1_BUILD_PROFILE" \
        -e MLP1_NATIVE_WAYLAND="$MLP1_NATIVE_WAYLAND" \
        -e MLP1_ENABLE_UDEV="$MLP1_ENABLE_UDEV" \
        -e MLP1_ENABLE_MALI_FBDEV="$MLP1_ENABLE_MALI_FBDEV" \
        -e MLP1_APPLY_COMMON_PATCHES="$MLP1_APPLY_COMMON_PATCHES" \
        -e MLP1_PATCH_SET="$MLP1_PATCH_SET" \
        -v "$REPO_ROOT":/workspace \
        -v "$TOOLCHAIN_REPO":/mlp1-toolchain:ro \
        -w /workspace \
        "$TOOLCHAIN_IMAGE" \
        /workspace/build-mlp1.sh "$@"
    exit $?
fi

JOBS="${JOBS:-$(nproc)}"

if [[ -f /opt/mlp1-toolchain/umrk/mlp1-build-flags.env ]]; then
    . /opt/mlp1-toolchain/umrk/mlp1-build-flags.env
elif [[ -f /mlp1-toolchain/flags/mlp1-build-flags.env ]]; then
    . /mlp1-toolchain/flags/mlp1-build-flags.env
else
    UMRK_MLP1_TARGET_SOC="rk3566"
    UMRK_MLP1_TARGET_CPU="cortex-a55"
    UMRK_MLP1_PROFILE_CFLAGS="-O2 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_CXXFLAGS="-O2 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_LDFLAGS="-Wl,--gc-sections"
fi

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

mali_fbdev_flag="--disable-mali_fbdev"
case "$MLP1_ENABLE_MALI_FBDEV" in
    1|true|yes|on)
        mali_fbdev_flag="--enable-mali_fbdev"
        ;;
    0|false|no|off|"")
        mali_fbdev_flag="--disable-mali_fbdev"
        ;;
    *)
        echo "invalid MLP1_ENABLE_MALI_FBDEV=$MLP1_ENABLE_MALI_FBDEV" >&2
        exit 1
        ;;
esac

apply_common_patches=false
case "$MLP1_APPLY_COMMON_PATCHES" in
    1|true|yes|on)
        apply_common_patches=true
        ;;
    0|false|no|off|"")
        apply_common_patches=false
        ;;
    *)
        echo "invalid MLP1_APPLY_COMMON_PATCHES=$MLP1_APPLY_COMMON_PATCHES" >&2
        exit 1
        ;;
esac

if [[ "$apply_common_patches" == "true" ]]; then
    echo "MLP1_APPLY_COMMON_PATCHES is intentionally disabled." >&2
    echo "Use MLP1_PATCH_SET with explicit patch names instead." >&2
    exit 1
fi

patches_applied=()
patches_to_unapply=()

cleanup_applied_patches() {
    local i patch

    if [[ "${#patches_to_unapply[@]}" -eq 0 ]]; then
        return
    fi

    for ((i=${#patches_to_unapply[@]} - 1; i >= 0; i--)); do
        patch="${patches_to_unapply[$i]}"
        if git apply --reverse --check "$patch" >/dev/null 2>&1; then
            git apply --reverse "$patch" || true
        else
            echo "warning: could not reverse applied patch: $patch" >&2
        fi
    done
}

trap cleanup_applied_patches EXIT

apply_named_patch() {
    local name="$1"
    local patch_path
    local patch_label

    case "$name" in
        portrait-rotation)
            patch_path="$REPO_ROOT/patches/common/0002-portrait-panel-landscape-rotation.patch"
            patch_label="common/$(basename "$patch_path")"
            ;;
        command-menu)
            patch_path="$REPO_ROOT/patches/mlp1/0001-command-menu-commands.patch"
            patch_label="mlp1/$(basename "$patch_path")"
            ;;
        jawaka-load-content)
            patch_path="$REPO_ROOT/patches/mlp1/0002-jawaka-load-content-command.patch"
            patch_label="mlp1/$(basename "$patch_path")"
            ;;
        controller-bindings)
            patch_path="$REPO_ROOT/patches/mlp1/0003-controller-only-bindings-ui.patch"
            patch_label="mlp1/$(basename "$patch_path")"
            ;;
        record-scale-clamp)
            patch_path="$REPO_ROOT/patches/mlp1/0005-record-scale-clamp.patch"
            patch_label="mlp1/$(basename "$patch_path")"
            ;;
        record-indicator)
            patch_path="$REPO_ROOT/patches/mlp1/0006-recording-indicator.patch"
            patch_label="mlp1/$(basename "$patch_path")"
            ;;
        "")
            return 0
            ;;
        *)
            echo "unknown MLP1 patch set entry: $name" >&2
            echo "known entries: portrait-rotation, command-menu, jawaka-load-content, controller-bindings, record-scale-clamp, record-indicator" >&2
            exit 1
            ;;
    esac

    if [[ ! -f "$patch_path" ]]; then
        echo "missing MLP1 patch file: $patch_path" >&2
        exit 1
    fi

    echo "Applying MLP1 patch: $name"
    git apply --check "$patch_path"
    git apply "$patch_path"
    patches_applied+=("$patch_label")
    patches_to_unapply+=("$patch_path")
}

if [[ -n "$MLP1_PATCH_SET" ]]; then
    IFS=',' read -r -a patch_set_entries <<< "$MLP1_PATCH_SET"
    for patch_entry in "${patch_set_entries[@]}"; do
        patch_entry="${patch_entry//[[:space:]]/}"
        apply_named_patch "$patch_entry"
    done
fi

make distclean >/dev/null 2>&1 || true

# --- FFmpeg (optional, opt-in) --------------------------------------------
# The device's own FFmpeg 4.4 is built --disable-encoders with only mjpeg/png
# for video, so linking against it would give MJPEG-in-mpegts, software
# encoded. build-mlp1-ffmpeg.sh produces an FFmpeg 6.1 with h264_rkmpp, which
# encodes on the RK3566 VPU instead.
#
# It is staged into the sysroot here rather than pointed at in place: the
# toolchain's pkg-config prepends the sysroot to every path, so a .pc living
# outside it resolves to nonsense. The sysroot lives inside the image and does
# not survive --rm, so this has to run on every build.
#
# SONAMEs are 60/60/58/7/4 against the device's 58/58/56/5/3, so nothing stock
# is shadowed and the two sets coexist.
MLP1_FFMPEG_DIR="${MLP1_FFMPEG_DIR:-/workspace/output/mlp1/ffmpeg}"
ffmpeg_flag="--disable-ffmpeg"
if [[ -d "$MLP1_FFMPEG_DIR/lib" && -f "$MLP1_FFMPEG_DIR/lib/pkgconfig/libavcodec.pc" ]]; then
    echo "staging FFmpeg from $MLP1_FFMPEG_DIR into the sysroot"
    cp -a "$MLP1_FFMPEG_DIR"/lib/lib*.so* "$SYSROOT/usr/lib/"
    cp -a "$MLP1_FFMPEG_DIR"/include/* "$SYSROOT/usr/include/"
    mkdir -p "$SYSROOT/usr/lib/pkgconfig"
    for pc in "$MLP1_FFMPEG_DIR"/lib/pkgconfig/*.pc; do
        sed -e 's|^prefix=.*|prefix=/usr|' \
            -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
            -e 's|^libdir=.*|libdir=${prefix}/lib|' \
            -e 's|^includedir=.*|includedir=${prefix}/include|' \
            "$pc" > "$SYSROOT/usr/lib/pkgconfig/$(basename "$pc")"
    done
    ffmpeg_flag="--enable-ffmpeg"
    # The runpath is set with patchelf AFTER linking, not through LDFLAGS. The
    # literal string has to survive make and then the shell make invokes, and
    # each layer eats it differently: $ORIGIN lost its $O to make's
    # single-character variable expansion and linked as "RIGIN/../lib/ffmpeg",
    # then $$ORIGIN survived make and was eaten by the shell as "/../lib/ffmpeg".
    # Both linked and reported success. patchelf writes the bytes directly.
else
    echo "no FFmpeg at $MLP1_FFMPEG_DIR -- building without recording support"
    echo "  (run build-mlp1-ffmpeg.sh first if you want h264_rkmpp recording)"
fi

export CFLAGS="${CFLAGS:-} $UMRK_MLP1_PROFILE_CFLAGS -D_GNU_SOURCE"
export CXXFLAGS="${CXXFLAGS:-} $UMRK_MLP1_PROFILE_CXXFLAGS -D_GNU_SOURCE"
export LDFLAGS="${LDFLAGS:-} $UMRK_MLP1_PROFILE_LDFLAGS"
export PKG_CONF_PATH="${PKG_CONF_PATH:-pkg-config}"
export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-$SYSROOT}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig}"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$PKG_CONFIG_LIBDIR}"

configure_flags=(
    "--host=$CROSS_TRIPLE"
    "--disable-qt"
    "--disable-discord"
    "--disable-x11"
    "$wayland_flag"
    "--enable-pulse"
    "--disable-jack"
    "--disable-oss"
    "--disable-vulkan"
    "--disable-vulkan_display"
    "--disable-opengl1"
    "--disable-opengl_core"
    "--disable-kms"
    "$mali_fbdev_flag"
    "--disable-ssl"
    "--enable-networking"
    "--enable-command"
    "--enable-sdl2"
    "--enable-alsa"
    "$udev_flag"
    "--enable-freetype"
    "--enable-zlib"
    "--enable-opengles"
    "--enable-opengles3"
    "--enable-egl"
    "$ffmpeg_flag"
)

./configure "${configure_flags[@]}"

make -j"$JOBS"

mkdir -p "$OUTPUT_BIN_DIR"
cp -f retroarch "$OUTPUT_BIN_DIR/retroarch"
"${STRIP:-aarch64-buildroot-linux-gnu-strip}" -s "$OUTPUT_BIN_DIR/retroarch"

if [[ "$ffmpeg_flag" == "--enable-ffmpeg" ]]; then
    # $ORIGIN resolves to the directory holding the binary, so this finds our
    # FFmpeg at .system/leaf/platforms/mlp1/lib/ffmpeg on the SD card without
    # shadowing the stock libav* that Kodi and friends use.
    patchelf --set-rpath '$ORIGIN/../lib/ffmpeg' "$OUTPUT_BIN_DIR/retroarch"
    rpath_actual="$(patchelf --print-rpath "$OUTPUT_BIN_DIR/retroarch")"
    if [[ "$rpath_actual" != '$ORIGIN/../lib/ffmpeg' ]]; then
        echo "runpath did not take: got '$rpath_actual'" >&2
        exit 1
    fi
    echo "runpath: $rpath_actual"
fi

verification_status="skipped"
verified=false
if [[ -x /mlp1-toolchain/scripts/verify-binary.sh ]]; then
    /mlp1-toolchain/scripts/verify-binary.sh "$OUTPUT_BIN_DIR/retroarch"
    verification_status="passed"
    verified=true
fi

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf "%s" "$value"
}

json_string() {
    printf '"'
    json_escape "$1"
    printf '"'
}

json_array() {
    local first=1
    local item

    printf "["
    for item in "$@"; do
        if [[ "$first" -eq 0 ]]; then
            printf ", "
        fi
        json_string "$item"
        first=0
    done
    printf "]"
}

commit="$(git -C "$RETROARCH_SRC_DIR" rev-parse HEAD)"
mkdir -p "$(dirname "$BUILD_MANIFEST")"
{
    printf "{\n"
    printf '  "platform": '; json_string "mlp1"; printf ",\n"
    printf '  "retroarch_version": '; json_string "$RETROARCH_VERSION"; printf ",\n"
    printf '  "retroarch_upstream_url": '; json_string "$RETROARCH_UPSTREAM_URL"; printf ",\n"
    printf '  "source_dir": '; json_string "$RETROARCH_SRC_DIR"; printf ",\n"
    printf '  "commit": '; json_string "$commit"; printf ",\n"
    printf '  "target_soc": '; json_string "$UMRK_MLP1_TARGET_SOC"; printf ",\n"
    printf '  "target_cpu": '; json_string "$UMRK_MLP1_TARGET_CPU"; printf ",\n"
    printf '  "build_profile": '; json_string "$MLP1_BUILD_PROFILE"; printf ",\n"
    printf '  "cflags": '; json_string "$CFLAGS"; printf ",\n"
    printf '  "cxxflags": '; json_string "$CXXFLAGS"; printf ",\n"
    printf '  "ldflags": '; json_string "$LDFLAGS"; printf ",\n"
    printf '  "configure_flags": '; json_array "${configure_flags[@]}"; printf ",\n"
    printf '  "patches_applied": '; json_array "${patches_applied[@]}"; printf ",\n"
    printf "  \"patch_controls\": {\n"
    printf '    "MLP1_APPLY_COMMON_PATCHES": '; json_string "$MLP1_APPLY_COMMON_PATCHES"; printf ",\n"
    printf '    "MLP1_ENABLE_MALI_FBDEV": '; json_string "$MLP1_ENABLE_MALI_FBDEV"; printf ",\n"
    printf '    "MLP1_PATCH_SET": '; json_string "$MLP1_PATCH_SET"; printf "\n"
    printf "  },\n"
    printf '  "toolchain_image": '; json_string "$TOOLCHAIN_IMAGE"; printf ",\n"
    printf '  "output_binary": '; json_string "$OUTPUT_BIN_DIR/retroarch"; printf ",\n"
    printf '  "exceptions": [],\n'
    printf '  "verified": %s,' "$verified"; printf "\n"
    printf '  "verification": '; json_string "$verification_status"; printf "\n"
    printf "}\n"
} > "$BUILD_MANIFEST"

echo "MLP1 RetroArch built: $OUTPUT_BIN_DIR/retroarch"
echo "Build manifest written: $BUILD_MANIFEST"
