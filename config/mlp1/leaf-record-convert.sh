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
# usage: leaf-record-convert.sh <capture.mkv | directory> [--split] [--delete-source]
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FFMPEG="$SELF_DIR/ffmpeg"

AUDIO_BITRATE=128k
AAC_CODER=fast

# Discord's free upload limit. Real gameplay costs ~34-35s per 10MB at the 2500k
# capture preset (measured: a 71.7s Contra clip shipped 20.6MB), so anything past
# about half a minute needs splitting to be shareable at all.
SPLIT_LIMIT_BYTES=10485760      # 10 MB - the limit each part must come in under
# ffmpeg's -fs stops writing once the limit is crossed, so a part can exceed this
# by the last packet it was midway through. Half a megabyte is ample room for that.
SPLIT_TARGET_BYTES=9961472      # 9.5 MB

die() { echo "leaf-record-convert: $*" >&2; exit 1; }

usage() { die "usage: $(basename "$0") <capture.mkv | directory> [--split] [--delete-source]"; }

[ $# -ge 1 ] || usage

SRC=$1
shift
DELETE_SOURCE=0
SPLIT=0
while [ $# -gt 0 ]; do
    case $1 in
        --delete-source) DELETE_SOURCE=1 ;;
        --split)         SPLIT=1 ;;
        *)               usage ;;
    esac
    shift
done

# Seconds from ffmpeg's "Duration: HH:MM:SS.ss". Parsed from ffmpeg rather than
# ffprobe because the build ships only the one binary. Prints nothing it cannot
# parse, and every caller treats empty as "do not split" -- losing the split is
# an inconvenience, mangling the recording is not.
probe_seconds() {
    "$FFMPEG" -hide_banner -i "$1" 2>&1 \
        | sed -n 's/.*Duration: \([0-9][0-9]\):\([0-9][0-9]\):\([0-9][0-9]\.[0-9]*\).*/\1 \2 \3/p' \
        | head -1 \
        | awk '{ if (NF == 3) printf "%.3f", $1 * 3600 + $2 * 60 + $3 }'
}

[ -x "$FFMPEG" ] || die "no ffmpeg beside this script at $FFMPEG"

# Directory mode: convert every capture that does not already have an up-to-date
# .mp4, then stop. Runs each through this same script so there is one code path,
# and keeps going if a single capture fails -- one corrupt file should not strand
# the rest of the session's clips.
if [ -d "$SRC" ]; then
    rc=0
    found=0
    args=""
    [ "$SPLIT" = "1" ] && args="$args --split"
    [ "$DELETE_SOURCE" = "1" ] && args="$args --delete-source"
    for capture in "$SRC"/*.mkv; do
        [ -e "$capture" ] || break          # nothing matched; glob stayed literal
        found=1
        # shellcheck disable=SC2086  # $args is our own fixed flag list, not user input
        "$0" "$capture" $args || rc=1
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
BASE=${SRC%.mkv}

# Already converted and not stale: nothing to do. Makes the pass safe to re-run
# over a whole directory without burning CPU on work already done. A split
# capture has parts instead of a single .mp4, so check for those too -- otherwise
# every session would re-convert and re-split every long clip it has ever made.
if [ -f "$DST" ] && [ "$DST" -nt "$SRC" ]; then
    echo "leaf-record-convert: up to date, skipping $(basename "$DST")"
    exit 0
fi
if [ -f "${BASE}-part1.mp4" ] && [ "${BASE}-part1.mp4" -nt "$SRC" ]; then
    echo "leaf-record-convert: up to date (split), skipping $(basename "$BASE")"
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

# Split, if asked and if it is actually needed. A clip that already fits is left
# as a single file -- splitting something shareable would only make it worse.
#
# Parts replace the single .mp4 rather than joining it: if splitting is on you
# want postable pieces, and the full file is still reproducible from the .mkv.
# Everything is stream-copied, so this is fast and lossless; the audio was already
# encoded once, into the temp file.
#
# Every failure path here falls back to keeping the single file. A clip that is
# too big to post is a nuisance; a clip destroyed by a half-finished split is not
# recoverable, and the .mkv may already have been deleted on a previous run.
SPLIT_DONE=0
if [ "$SPLIT" = "1" ] && [ "$(wc -c < "$TMP")" -gt "$SPLIT_LIMIT_BYTES" ]; then
    duration=$(probe_seconds "$TMP")
    if [ -n "$duration" ]; then
        # Cut with ffmpeg's own size limit rather than a computed segment length.
        # Deriving seconds-per-part from the average bitrate looks reasonable and
        # is wrong: this is VBR, and a busy stretch runs far above the mean (peak
        # second 4071k against a 2196k average here), so an average-sized window
        # over an explosion sails past the target. -fs stops writing once the
        # limit is crossed, which holds whatever the content does.
        rm -f "${BASE}"-part*.mp4
        offset=0
        n=1
        ok=1
        while :; do
            part="${BASE}-part${n}.mp4"
            if ! "$FFMPEG" -v error -y -ss "$offset" -i "$TMP" -c copy \
                    -fs "$SPLIT_TARGET_BYTES" -movflags +faststart \
                    -f mp4 "$part" 2>/dev/null || [ ! -s "$part" ]; then
                rm -f "$part"
                [ "$n" = "1" ] && ok=0      # produced nothing at all
                break
            fi
            part_seconds=$(probe_seconds "$part")
            # A part with no readable or zero duration cannot advance the offset,
            # and looping on it would write parts until the card filled.
            if [ -z "$part_seconds" ] || [ "$(awk -v s="$part_seconds" 'BEGIN{print (s < 0.5)}')" = "1" ]; then
                rm -f "$part"
                ok=0
                break
            fi
            offset=$(awk -v o="$offset" -v s="$part_seconds" 'BEGIN{printf "%.3f", o + s}')
            [ "$(awk -v o="$offset" -v d="$duration" 'BEGIN{print (o >= d - 0.5)}')" = "1" ] && break
            n=$((n + 1))
            if [ "$n" -gt 64 ]; then        # backstop; no real capture needs this
                ok=0
                break
            fi
        done

        if [ "$ok" = "1" ] && [ -s "${BASE}-part1.mp4" ]; then
            parts=$(ls "${BASE}"-part*.mp4 2>/dev/null | wc -l | tr -d ' ')
            biggest=$(ls -S "${BASE}"-part*.mp4 2>/dev/null | head -1)
            if [ "$(wc -c < "$biggest")" -le "$SPLIT_LIMIT_BYTES" ]; then
                SPLIT_DONE=1
                rm -f "$TMP"
                sync
                echo "leaf-record-convert: $(basename "$BASE") split into $parts parts"
            else
                rm -f "${BASE}"-part*.mp4
                echo "leaf-record-convert: split overshot for $(basename "$BASE"), keeping one file" >&2
            fi
        else
            rm -f "${BASE}"-part*.mp4
            echo "leaf-record-convert: split failed for $(basename "$BASE"), keeping one file" >&2
        fi
    else
        echo "leaf-record-convert: could not read duration for $(basename "$BASE"), keeping one file" >&2
    fi
fi

if [ "$SPLIT_DONE" = "0" ]; then
    mv "$TMP" "$DST"
    sync
fi

# The SD card is FAT32 and a dirty card flips read-only, so sync before anything
# else touches it, and only remove the source once the output is durably in place.
if [ "$DELETE_SOURCE" = "1" ]; then
    rm -f "$SRC"
    sync
fi

# The split path already reported how many parts it made; $DST does not exist there.
[ "$SPLIT_DONE" = "1" ] || echo "leaf-record-convert: $(basename "$DST")"
