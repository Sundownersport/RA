#!/bin/bash
# Cross-compile ffmpeg-rockchip as SHARED libraries for the MLP1 toolchain, so
# RetroArch can be built with --enable-ffmpeg and record through the RK3566 VPU.
#
# Why not the FFmpeg already on the device: LoongOS ships FFmpeg 4.4 built with
# --disable-encoders and only mjpeg/png re-enabled for video, no H.264 by any
# path, and only spdif/adts/asf/ipod/mpegts muxers. Linking RetroArch against it
# would give MJPEG-in-mpegts, software encoded, competing with the emulator for
# CPU. This build adds h264_rkmpp, which encodes on the VPU instead.
#
# SONAMEs do not collide with the stock libraries. ffmpeg-rockchip is FFmpeg 6.1
# (avcodec 60 / avformat 60 / avutil 58 / swscale 7 / swresample 4); the device
# carries the 4.4 set (58 / 58 / 56 / 5 / 3). Nothing on the device is shadowed,
# and RetroArch reaches ours through an RPATH rather than by luck.
#
# Runs INSIDE the mlp1-toolchain image. Adapted from moonlight-poc/build.sh,
# which proved the rkmpp path end to end (kmsgrab -> h264_rkmpp, 64-80 fps,
# near-idle CPU). Differences: shared instead of static, no Sunshine staging.
set -euo pipefail

TC=/opt/mlp1-toolchain
export PATH="$TC/bin:$PATH"
SYSROOT="$TC/aarch64-buildroot-linux-gnu/sysroot"
CROSS=aarch64-buildroot-linux-gnu-
NPROC=$(nproc)

SRC_MPP=${SRC_MPP:-/work/mpp}
SRC_FF=${SRC_FF:-/work/ffmpeg-rockchip}
OUT=${OUT:-/work/output/mlp1/ffmpeg}

# MPP's merge_static_lib.sh calls bare `ar`; the image ships only the cross ar.
ln -sf "$TC/bin/${CROSS}ar" "$TC/bin/ar" 2>/dev/null || true

echo "================ 1/3  MPP (cmake, shared) ================"
cd "$SRC_MPP"
rm -rf build/cross; mkdir -p build/cross; cd build/cross
cmake ../.. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER="${CROSS}gcc" -DCMAKE_CXX_COMPILER="${CROSS}g++" \
  -DCMAKE_INSTALL_PREFIX="$SYSROOT/usr" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=ON >/tmp/mpp_cmake.log 2>&1 \
  || { tail -30 /tmp/mpp_cmake.log; exit 1; }
make -j"$NPROC" >/tmp/mpp_make.log 2>&1 || { tail -40 /tmp/mpp_make.log; exit 1; }
make install >/tmp/mpp_install.log 2>&1 || { tail -20 /tmp/mpp_install.log; exit 1; }
echo "  MPP -> $(ls "$SYSROOT"/usr/lib/librockchip_mpp.so.1 2>&1)"

echo "================ 2/3  ffmpeg-rockchip (shared) ================"
cd "$SRC_FF"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig"
make distclean >/dev/null 2>&1 || true

# rkrga is deliberately NOT enabled. librga is C++ and its std::locale static
# initialisation segfaulted the PoC binary at load. rkmpp alone still does the
# colour convert on RGA internally, which is where the win actually came from.
#
# --pkg-config=pkg-config is required: ffmpeg otherwise looks for the
# cross-prefixed name, fails to find it, falls back to `false`, and reports
# "libdrm not found" with no other explanation.
./configure \
  --prefix="$OUT" \
  --enable-cross-compile --arch=aarch64 --target-os=linux \
  --cross-prefix="$CROSS" --sysroot="$SYSROOT" \
  --pkg-config=pkg-config \
  --enable-gpl --enable-version3 \
  --enable-libdrm --enable-rkmpp \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-htmlpages \
  --disable-manpages --disable-txtpages \
  --disable-sdl2 --disable-alsa \
  --disable-debug \
  >/tmp/ff_configure.log 2>&1 \
  || { echo "--- configure FAILED ---"; tail -40 /tmp/ff_configure.log; \
       echo "--- config.log tail ---"; tail -30 ffbuild/config.log 2>/dev/null; exit 1; }

# config.h writes "#define CONFIG_RKMPP 1"; config.mak writes "CONFIG_RKMPP=yes".
# Matching only one form silently aborts a perfectly good configure.
for want in RKMPP LIBDRM; do
    grep -qE "^#define CONFIG_$want 1\$" config.h \
      || { echo "CONFIG_$want did not enable; refusing to build a useless ffmpeg"; \
           echo "--- configure log tail ---"; tail -25 /tmp/ff_configure.log; exit 1; }
    echo "  CONFIG_$want enabled"
done

make -j"$NPROC" >/tmp/ff_make.log 2>&1 || { echo "--- make FAILED ---"; tail -40 /tmp/ff_make.log; exit 1; }
make install >/tmp/ff_install.log 2>&1 || { tail -20 /tmp/ff_install.log; exit 1; }

echo "================ 3/3  stage for RetroArch ================"
# The sysroot copy is what RetroArch's configure will pkg-config against; the
# $OUT copy is what ships next to the binary.
cp -a "$OUT"/lib/libav*.so* "$OUT"/lib/libsw*.so* "$SYSROOT/usr/lib/" 2>/dev/null || true
# ffmpeg bakes the configure-time --prefix into every .pc as an absolute path,
# which is wrong the moment the tree is mounted somewhere else -- and it is: this
# script mounts the output at /work/output, build-mlp1.sh mounts the repo at
# /workspace. Rewrite them to be relocatable via ${pcfiledir} so they resolve
# from wherever the directory happens to live.
for pc in "$OUT"/lib/pkgconfig/*.pc; do
    sed -i \
      -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
      -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
      -e 's|^libdir=.*|libdir=${prefix}/lib|' \
      -e 's|^includedir=.*|includedir=${prefix}/include|' \
      "$pc"
done
cp -a "$OUT"/lib/pkgconfig/*.pc "$SYSROOT/usr/lib/pkgconfig/" 2>/dev/null || true
cp -a "$OUT"/include/* "$SYSROOT/usr/include/" 2>/dev/null || true
# librockchip_mpp is a runtime dependency of libavcodec and the device's copy may
# not match this build, so ship ours beside it.
cp -a "$SYSROOT"/usr/lib/librockchip_mpp.so* "$OUT/lib/" 2>/dev/null || true

# Flatten to SONAME-named real files. The SD card is FAT32, which has no
# symlinks at all, so ffmpeg's usual libfoo.so -> libfoo.so.N -> libfoo.so.N.M.P
# chain cannot ship. The loader only ever asks for the SONAME, so one real file
# per library under that exact name is all that is needed -- and it avoids adb
# push silently dereferencing the chain into three copies of everything.
FLAT="$OUT/flat"
rm -rf "$FLAT"; mkdir -p "$FLAT"
for real in "$OUT"/lib/lib*.so.*.*; do
    [ -f "$real" ] || continue
    soname=$(${CROSS}readelf -d "$real" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
    [ -n "$soname" ] || { echo "no SONAME in $(basename "$real")"; exit 1; }
    cp "$real" "$FLAT/$soname"
done
cp -L "$SYSROOT"/usr/lib/librockchip_mpp.so.1 "$FLAT/" 2>/dev/null || true

# Every library gets $ORIGIN so it finds its siblings. RUNPATH, unlike the old
# RPATH, is NOT consulted for a dependency's own dependencies -- so RetroArch's
# runpath locates libavdevice, and then libavdevice cannot find libavfilter
# sitting next to it. Each library has to say where its siblings are.
for f in "$FLAT"/*.so.*; do
    patchelf --set-rpath '$ORIGIN' "$f"
    got=$(patchelf --print-rpath "$f")
    [ "$got" = '$ORIGIN' ] || { echo "runpath not set on $(basename "$f"): '$got'"; exit 1; }
done
echo "--- flattened + runpath'd: $(ls -1 "$FLAT" | wc -l) libs, $(find "$FLAT" -type l | wc -l) symlinks ---"

echo "--- SONAMEs (must not collide with the device's 4.4 set) ---"
for so in "$OUT"/lib/lib*.so.*; do
  case "$so" in *.so.*.*) continue ;; esac
  printf '  %-28s %s\n' "$(basename "$so")" \
    "$(${CROSS}readelf -d "$so" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
done
echo "--- h264_rkmpp present in libavcodec ---"
${CROSS}strings "$OUT"/lib/libavcodec.so 2>/dev/null | grep -x "h264_rkmpp" \
  || strings "$OUT"/lib/libavcodec.so 2>/dev/null | grep -x "h264_rkmpp" \
  || { echo "  MISSING - the encoder did not build in"; exit 1; }
echo "================ DONE -> $OUT ================"
