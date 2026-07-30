#!/bin/sh
# Turn a Leaf capture into something a phone, a browser or Discord will play.
#
# Capture has to be cheap enough to run underneath a game, so it records FLAC in
# Matroska: real-time AAC breaks audio OUTPUT on FCEUmm, and Matroska survives a
# recording cut short by a crash or a flat battery where MP4 would leave an
# unplayable file. Neither of those choices travels well, which is the whole point
# of recording a clip. This runs after RetroArch has exited, where nothing is
# real-time any more.
#
# The video stream is COPIED, never re-encoded. Verified on device: the video
# MD5 is identical before and after (915 packets both sides). So this costs no
# quality and no VPU work, and the capture bitrate is also the final bitrate --
# nothing here can shrink the video.
#
# Measured on device, 15s clip: 151ms video copy + mux, 148ms FLAC decode, and
# the rest is the AAC encoder. aac_coder=fast halves the total (2.56s -> 1.32s)
# and Eric A/B'd it against the default twoloop coder on dense Hard Corps audio
# and could not tell them apart. Half the CPU on a handheld is worth having.
#
# Takes a single capture or a directory. jawakad passes the directory once, after
# RetroArch exits, because one session can produce several clips and it should not
# have to track which. Converting is idempotent -- an up-to-date .mp4 is skipped --
# so re-running over the whole directory costs nothing.
#
# usage: leaf-record-convert.sh <capture.mkv | directory> [--delete-source]
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FFMPEG="$SELF_DIR/ffmpeg"

AUDIO_BITRATE=128k
AAC_CODER=fast

die() { echo "leaf-record-convert: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $(basename "$0") <capture.mkv> [--delete-source]"

SRC=$1
DELETE_SOURCE=0
[ "${2:-}" = "--delete-source" ] && DELETE_SOURCE=1

[ -x "$FFMPEG" ] || die "no ffmpeg beside this script at $FFMPEG"

# Directory mode: convert every capture that does not already have an up-to-date
# .mp4, then stop. Runs each through this same script so there is one code path,
# and keeps going if a single capture fails -- one corrupt file should not strand
# the rest of the session's clips.
if [ -d "$SRC" ]; then
    rc=0
    found=0
    for capture in "$SRC"/*.mkv; do
        [ -e "$capture" ] || break          # nothing matched; glob stayed literal
        found=1
        if [ "$DELETE_SOURCE" = "1" ]; then
            "$0" "$capture" --delete-source || rc=1
        else
            "$0" "$capture" || rc=1
        fi
    done
    [ "$found" = "1" ] || echo "leaf-record-convert: no captures in $SRC"
    exit $rc
fi

[ -f "$SRC" ] || die "no such capture: $SRC"

case "$SRC" in
    *.mkv) ;;
    *) die "expected a .mkv capture or a directory, got: $SRC" ;;
esac

DST=${SRC%.mkv}.mp4

# Already converted and not stale: nothing to do. Makes the pass safe to re-run
# over a whole directory without burning CPU on work already done.
if [ -f "$DST" ] && [ "$DST" -nt "$SRC" ]; then
    echo "leaf-record-convert: up to date, skipping $(basename "$DST")"
    exit 0
fi

# Write to a temp name and rename only on success. MP4 writes its index at
# finalisation, so a conversion interrupted midway leaves a file that looks
# complete to a file browser but will not play. The rename is what makes the
# .mp4 appearing mean the .mp4 works.
#
# -f mp4 is REQUIRED because of that temp name: ffmpeg picks the muxer from the
# output extension, and ".mp4.part" is not one it knows, so it fails with
# "Unable to choose an output format". Writing straight to .mp4 hides this.
TMP="${DST}.part"
rm -f "$TMP"

if ! "$FFMPEG" -v error -y -i "$SRC" \
        -c:v copy \
        -c:a aac -aac_coder "$AAC_CODER" -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        -f mp4 "$TMP"; then
    rm -f "$TMP"
    die "conversion failed for $(basename "$SRC")"
fi

# A zero-length or absurdly small result means ffmpeg exited 0 without writing
# anything useful; better to keep the capture and say so than to swap in a dud.
if [ ! -s "$TMP" ]; then
    rm -f "$TMP"
    die "conversion produced an empty file for $(basename "$SRC")"
fi

mv "$TMP" "$DST"
sync

# The SD card is FAT32 and a dirty card flips read-only, so sync before anything
# else touches it, and only remove the source once the .mp4 is durably in place.
if [ "$DELETE_SOURCE" = "1" ]; then
    rm -f "$SRC"
    sync
fi

echo "leaf-record-convert: $(basename "$DST")"
