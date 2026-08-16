#!/bin/bash
set -e

RETROARCH_VERSION="${RETROARCH_VERSION:-v1.22.2}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building RetroArch ${RETROARCH_VERSION} for Allwinner H700 (armhf) ==="

# Clone RetroArch
if [ ! -d "RetroArch" ]; then
    git clone --depth 1 --branch "$RETROARCH_VERSION" \
        https://github.com/libretro/RetroArch.git
fi

cd RetroArch

# Apply common patches (spruce IGM, portrait-panel rotation, sysfs rumble).
if [ -d /patches/common ] && ls /patches/common/*.patch 1>/dev/null 2>&1; then
    for patch in /patches/common/*.patch; do
        echo "Applying: $(basename "$patch")"
        git apply "$patch"
    done
fi

# Cross-compilation environment
export CC=arm-linux-gnueabihf-gcc
export CXX=arm-linux-gnueabihf-g++
export AR=arm-linux-gnueabihf-ar
export STRIP=arm-linux-gnueabihf-strip
export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig

# H700 is 4x Cortex-A53, so in aarch32 this is ARMv8-A 32-bit, not ARMv7.
# -mfpu=neon-fp-armv8 gets the ARMv8 FP/SIMD unit rather than the toolchain
# default (vfpv3-d16), which has no NEON at all. RetroArch appends its own
# -mfpu=neon -marm to its hand-written NEON objects, which is correct for
# them - that asm is ARMv7 NEON - and only affects those files.
H700_ARCH="-mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
H700_OPT="-O3 $H700_ARCH -ffunction-sections -fdata-sections -fomit-frame-pointer -flto=auto -DNDEBUG"
H700_DEFS="-DHAVE_SCREEN_ORIENTATION -DGEOMETRY_MENU_ROTATION -D_GNU_SOURCE -DHAVE_FILTERS_BUILTIN"

export CFLAGS="$CFLAGS $H700_OPT $H700_DEFS"
export CXXFLAGS="$CXXFLAGS $H700_OPT $H700_DEFS"
# $H700_ARCH must be repeated in LDFLAGS. With -flto the link step recompiles
# the IR, and it does so against whatever target the *link* command names - so
# omitting -mcpu here silently rebuilds everything for the toolchain default.
# That is not theoretical: -mcpu=cortex-a53 defines __ARM_FEATURE_CRC32, which
# switches libretro-common/encodings/encoding_crc32.c onto the __crc32b/__crc32d
# ACLE builtins, and lto-wrapper then rejected them as "not supported for this
# target" because the default arm target has no CRC extension.
export LDFLAGS="$LDFLAGS $H700_ARCH -Wl,--gc-sections -flto=auto"

# Configure for the H700 in 32-bit mode.
#
# Targets BOTH userlands. Stock Anbernic is Ubuntu with a full 32-bit multilib
# in /usr/lib32, so it needs nothing extra. BaseOS harvests only one armhf
# library of its own (libc.so.6, so the vendor bluetooth binary runs), so
# spruce supplies the rest of the 32-bit stack on the card - see
# AnbernicXXCommon.cfg. The kernel side is already proven: BaseOS runs that
# armhf bluetooth binary, so aarch32 EL0 works.
#
# Two things this has that ra32.universal does not:
#
# --enable-neon: the universal armhf build leaves HAVE_NEON at its default of
#   no, which drops RetroArch's NEON sinc/CC resamplers, its NEON memcpy and
#   the s16<->float audio conversions. Those are per-frame paths and the A53
#   has the SIMD unit sitting idle otherwise. On aarch64 this flag is moot
#   (NEON is architectural), which is why ra64.h700 disables it - here it is
#   a real gain and the main reason a 32-bit h700 target is worth having.
# --enable-mali_fbdev: same reasoning as ra64.h700 - reach the Mali blob
#   directly instead of RetroArch -> SDL2 -> mali fbdev EGL. Safe to enable
#   even where it may not suit: video_context_driver_init_first falls through
#   to the remaining context drivers if fbdev_mali fails to initialise.
#
# --disable-vulkan: no 32-bit Vulkan driver on these devices.
# --disable-kms: nothing to bind to on either userland.
#
# Note on input under BaseOS: the stock 32-bit SDL2 dlopens libudev, so its
# joystick enumeration finds nothing where no udevd runs. RetroArch's linuxraw
# joypad driver reads /dev/input/js* through the legacy API with no udev and no
# SDL, which is why --enable-udev and --enable-sdl2 are both kept but neither
# is load-bearing there. Driver choice is made in the platform cfg, not here.
CFLAGS="$CFLAGS" \
CXXFLAGS="$CXXFLAGS" \
LDFLAGS="$LDFLAGS" \
./configure --host=arm-linux-gnueabihf \
    --enable-mali_fbdev \
    --enable-neon \
    --enable-floathard \
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
    --disable-discord

# Both of the flags this target exists for default to "no" upstream, and both
# fail quietly: without them you get a binary that runs correctly and is just
# slower, with nothing in any log to say why. Fail the build instead.
for want in HAVE_MALI_FBDEV HAVE_NEON; do
    if ! grep -q "^$want = 1" config.mk; then
        echo "FATAL: $want did not survive configure - config.mk says:" >&2
        grep -i 'mali\|neon\|EGL\|OPENGLES' config.mk >&2 || true
        exit 1
    fi
done
echo "=== confirmed: HAVE_MALI_FBDEV = 1, HAVE_NEON = 1 ==="

# Build
make HAVE_STATIC_VIDEO_FILTERS=1 HAVE_STATIC_AUDIO_FILTERS=1 -j$(nproc)

# Output
mkdir -p "$OUTPUT_DIR"
cp retroarch "$OUTPUT_DIR/"
arm-linux-gnueabihf-strip -s "$OUTPUT_DIR/retroarch"

echo "=== Build complete: ${OUTPUT_DIR}/retroarch ==="
