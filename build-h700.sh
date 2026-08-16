#!/bin/bash
set -e

RETROARCH_VERSION="${RETROARCH_VERSION:-v1.22.2}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building RetroArch ${RETROARCH_VERSION} for Allwinner H700 (aarch64) ==="

# Clone RetroArch
if [ ! -d "RetroArch" ]; then
    git clone --depth 1 --branch "$RETROARCH_VERSION" \
        https://github.com/libretro/RetroArch.git
fi

cd RetroArch

# Apply common patches (spruce IGM, portrait-panel rotation, sysfs rumble).
# The portrait patch matters here: the XX line includes rotated panels (RG28XX,
# RG34XX/SP), which is also why the rotation defines stay in CFLAGS below.
if [ -d /patches/common ] && ls /patches/common/*.patch 1>/dev/null 2>&1; then
    for patch in /patches/common/*.patch; do
        echo "Applying: $(basename "$patch")"
        git apply "$patch"
    done
fi

# Cross-compilation environment
export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export AR=aarch64-linux-gnu-ar
export STRIP=aarch64-linux-gnu-strip
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig

# H700 is 4x Cortex-A53. -mcpu (not -march/-mtune) so the scheduler and the
# ISA both target it. Kept at -O3 rather than -Ofast: the frontend's floating
# point is audio resampling and viewport maths, where -ffast-math buys nothing
# measurable and can shift results.
H700_OPT="-O3 -mcpu=cortex-a53 -ffunction-sections -fdata-sections -fomit-frame-pointer -flto=auto -DNDEBUG"
H700_DEFS="-DHAVE_SCREEN_ORIENTATION -DGEOMETRY_MENU_ROTATION -D_GNU_SOURCE -DHAVE_FILTERS_BUILTIN"

export CFLAGS="$CFLAGS $H700_OPT $H700_DEFS"
export CXXFLAGS="$CXXFLAGS $H700_OPT $H700_DEFS"
export LDFLAGS="$LDFLAGS -Wl,--gc-sections -flto=auto"

# Configure for the H700 Anbernic XX line running under BaseOS.
#
# The one change of substance vs ra64.universal is --enable-mali_fbdev. The
# universal binary has no fbdev context driver, so with KMS off and no X11 or
# wayland its "gl" video driver falls through to the SDL2 GL context: RA ->
# SDL2 -> mali fbdev EGL. Building the fbdev_mali context in lets RA talk to
# the Mali blob directly and drops SDL2 out of the video path entirely.
# gfx_ctx_mali_fbdev sits ahead of sdl_gl_ctx in RA's auto-pick order, so it
# wins on its own; the platform cfg pins it anyway.
#
# --disable-kms: BaseOS harvests no libdrm/libgbm (manifest/harvest.list), so
#   there is nothing for KMS to bind to. This is where MustardOS's h700 recipe
#   diverges from ours - it builds --enable-kms against its own buildroot.
# --disable-vulkan: the H700's Mali-G31 fbdev blob exposes no Vulkan driver.
#   The universal binary carries it for the Smart Pro S; here it is dead weight.
# --enable-udev: kept. BaseOS runs no udevd so RA's udev drivers enumerate
#   nothing, but libudev.so.1 IS harvested, so it links clean and costs nothing.
#   Input comes from the sdl2 driver via the BaseOS platform cfg overlay.
# --enable-sdl2: still required - it is the input/joypad driver, and remains
#   the video fallback if the fbdev context ever fails to init.
CFLAGS="$CFLAGS" \
CXXFLAGS="$CXXFLAGS" \
LDFLAGS="$LDFLAGS" \
./configure --host=aarch64-linux-gnu \
    --enable-mali_fbdev \
    --enable-egl \
    --enable-opengles \
    --enable-opengles3 \
    --enable-sdl2 \
    --enable-udev \
    --enable-alsa \
    --enable-networking \
    --enable-ssl \
    --enable-command \
    --enable-freetype \
    --enable-builtinzlib \
    --enable-zlib \
    --disable-vulkan \
    --disable-kms \
    --disable-opengl \
    --disable-opengl1 \
    --disable-opengl_core \
    --disable-x11 \
    --disable-wayland \
    --disable-qt \
    --disable-pulse \
    --disable-jack \
    --disable-oss \
    --disable-discord \
    --disable-neon

# Sanity-check that the fbdev context actually made it into the build. A silent
# HAVE_MALI_FBDEV=no here would produce a binary that looks fine and quietly
# goes back through SDL2, which is exactly the thing this target exists to stop.
if ! grep -q '^HAVE_MALI_FBDEV = 1' config.mk; then
    echo "FATAL: mali_fbdev context not enabled - config.mk says:" >&2
    grep -i 'mali\|EGL\|OPENGLES' config.mk >&2 || true
    exit 1
fi
echo "=== confirmed: HAVE_MALI_FBDEV = 1 ==="

# Build
make HAVE_STATIC_VIDEO_FILTERS=1 HAVE_STATIC_AUDIO_FILTERS=1 -j$(nproc)

# Output
mkdir -p "$OUTPUT_DIR"
cp retroarch "$OUTPUT_DIR/"
aarch64-linux-gnu-strip -s "$OUTPUT_DIR/retroarch"

echo "=== Build complete: ${OUTPUT_DIR}/retroarch ==="
