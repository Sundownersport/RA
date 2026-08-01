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
# DECIMAL megabytes, deliberately. "10 MB" is ambiguous -- 10 MiB is 10485760 and
# 10 MB is 10000000 -- and sizing this in MiB is a real trap: parts came out at
# 10018185 and 10009697 bytes, which pass a 10 MiB test and are still over
# 10 million bytes. Finder called them "10 MB" while the device called them
# "9.6 MB"; both were right, and the file was over the line either way. Since it is
# not certain which Discord enforces, come in under the smaller reading.
SPLIT_LIMIT_BYTES=10000000      # the limit each part must come in under
# No target under the limit, and no headroom, because nothing here is predicted:
# parts are assembled from pieces whose sizes have already been read off the
# filesystem. Earlier versions aimed at 9300000 to absorb the overshoot of a
# guess; see the split block for why the guessing went.
SPLIT_MAX_PARTS=64              # backstop; no real capture needs this many
SPLIT_MAX_PIECES=512            # keyframe pieces; a 3min clip makes ~42

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

# Join the pieces listed in $1 into the single MP4 at $2, stream-copied.
#
# -safe 0 because the list holds absolute paths. -f mp4 because the caller writes
# to a scratch name, and ffmpeg picks its muxer from the extension. faststart so
# each part streams in a browser rather than downloading whole first.
#
# Joining costs a little: ffmpeg writes the H.264 parameter sets in-band at each
# join, so one keyframe per piece grows. Measured exactly on the Metroid capture
# -- 41 of 10412 packets differed, every one a keyframe, each by precisely 103
# bytes, 4223 in total on a 44869870-byte file, or 0.009%. Frame count is
# unchanged (10412 either way), so nothing is duplicated or dropped; the parts
# simply carry their own SPS/PPS, which is valid and if anything more robust.
# It is also strictly additive, and the caller re-measures every finished part
# against the limit, so it cannot push one over unnoticed.
jw_concat_group() {
    "$FFMPEG" -v error -y -f concat -safe 0 -i "$1" -c copy \
              -movflags +faststart -f mp4 "$2" 2>/dev/null && [ -s "$2" ]
}

# ⛔ NOTHING here may work from a duration, and in particular nothing may read one
# out of the .mkv. This used to parse ffmpeg's "Duration:" line to size a split,
# and the capture's is wrong: RetroArch writes a FLAC track DURATION of actual +
# 4.512s (exactly 47 audio frames) and the Matroska segment duration takes the
# larger of the two tracks, so a capture reports up to 23% longer than it is.
# Measured across five of them -- 23.90 against 19.43, 24.29 against 19.83, 45.26
# against 40.80, 72.19 against 67.67, 10.55 against 6.04 -- while the packets are
# continuous and complete every time and the video track's own tag is always
# exact. Remuxing the same FLAC packets with -c copy writes the correct value, so
# the number is RetroArch's, not the data's. The split now packs measured bytes
# and never asks how long anything is, which sidesteps this entirely.

[ -x "$FFMPEG" ] || die "no ffmpeg beside this script at $FFMPEG"

# Directory mode: convert every capture that does not already have an up-to-date
# .mp4, then stop. Runs each through this same script so there is one code path,
# and keeps going if a single capture fails -- one corrupt file should not strand
# the rest of the session's clips.
#
# Only ONE of these may run at a time. jawakad dispatches on every exit to the
# launcher and conversion runs detached for seconds to minutes, so exiting one game
# and quickly finishing another starts a second copy over the same directory. Both
# would see the same capture as unconverted -- the first has not renamed its output
# yet -- and write the same .mp4.part, and on the split path one run's
# "rm -f BASE-part*.mp4" deletes the other's parts mid-write. The result is a
# corrupt file that still passes the non-empty check. A unique temp name is not
# enough on its own, because the part filenames are a shared namespace.
#
# The lock lives in /tmp rather than beside the captures: it is tmpfs, so a reboot
# during a conversion cannot strand it, and it keeps bookkeeping out of a folder
# the user browses. A holder killed without a reboot is handled by the pid check.
#
# Ownership is proven by a per-run token, not by a pid. An earlier version read the
# holder's pid, tested it with kill -0, and on failure did rm -rf + mkdir. That has
# no atomicity between the test and the takeover: two runs could both find the lock
# stale, and the second one's rm -rf would delete the first one's live lock, leaving
# both convinced they held it -- precisely the corruption the lock exists to stop.
# It also had two silent ways to fail: a lock directory whose pid file had not been
# written yet was stolen deterministically, and a pid that got recycled pinned the
# lock forever, disabling conversion until reboot with no symptom.
#
# mkdir alone is the whole mutual exclusion: it creates or it fails, atomically, and
# nothing takes a lock away from a live holder. Staleness is handled by an mtime age
# check instead of a pid, because a pid says nothing about whether THIS lock is the
# one that process took.
LOCK_DIR=/tmp/leaf-record-convert.lock
LOCK_TOKEN=$$-$(date +%s 2>/dev/null || echo 0)
LOCK_HELD=0
# Nothing here runs for hours: the longest real conversion is minutes. An hour means
# the holder is gone.
LOCK_STALE_SECONDS=3600

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/token" 2>/dev/null || {
            rmdir "$LOCK_DIR" 2>/dev/null || true   # cannot prove ownership, so do not claim it
            return 1
        }
        LOCK_HELD=1
        return 0
    fi

    # Held. Only reclaim it if it is old enough that no live run could own it, and
    # even then go through mkdir again so the reclaim itself stays atomic.
    lock_age=$(awk -v now="$(date +%s 2>/dev/null || echo 0)" \
                   -v then="$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)" \
                   'BEGIN { print (now > then) ? now - then : 0 }')
    [ "$lock_age" -lt "$LOCK_STALE_SECONDS" ] && return 1

    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/token" 2>/dev/null || {
            rmdir "$LOCK_DIR" 2>/dev/null || true
            return 1
        }
        LOCK_HELD=1
        return 0
    fi
    return 1
}

# Release only what we actually own. Without the token check, a run whose lock was
# reclaimed as stale would delete the reclaiming run's lock on its way out.
release_lock() {
    [ "$LOCK_HELD" = "1" ] || return 0
    if [ "$(cat "$LOCK_DIR/token" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    LOCK_HELD=0
}

if [ -d "$SRC" ]; then
    if ! acquire_lock; then
        echo "leaf-record-convert: another conversion is running, skipping"
        exit 0
    fi
    # INT and TERM must exit explicitly. A POSIX trap that only cleans up RETURNS
    # to where the script was interrupted, so the earlier version released the lock
    # and then carried on converting -- unlocked, for the rest of the run.
    trap 'release_lock' EXIT
    trap 'release_lock; exit 130' INT
    trap 'release_lock; exit 143' TERM

    # The per-file runs below are ours and are covered by the lock we just took;
    # they must not try to take it themselves or every one of them would decline.
    # A hand-run single-file invocation has no such parent and does lock.
    LEAF_RECORD_CONVERT_LOCKED=1
    export LEAF_RECORD_CONVERT_LOCKED

    rc=0
    found=0
    args=""
    [ "$SPLIT" = "1" ] && args="$args --split"
    [ "$DELETE_SOURCE" = "1" ] && args="$args --delete-source"

    # Re-scan after each pass. A clip finished while we were busy would otherwise
    # wait for the next game exit, and the run that would have picked it up was
    # the one we just turned away at the lock. Bounded, so a capture that fails
    # every time costs a few attempts rather than looping forever.
    round=0
    while [ "$round" -lt 3 ]; do
        round=$((round + 1))
        pending=0
        for capture in "$SRC"/*.mkv; do
            [ -e "$capture" ] || break       # nothing matched; glob stayed literal
            found=1
            base=${capture%.mkv}
            # Skip what is already done, so a later round is cheap and only the
            # genuinely new captures are handed to the converter again.
            if [ -f "${base}.mp4" ] && [ "${base}.mp4" -nt "$capture" ]; then
                continue
            fi
            if [ -f "${base}-part1.mp4" ] && [ "${base}-part1.mp4" -nt "$capture" ]; then
                continue
            fi
            pending=1
            # shellcheck disable=SC2086  # $args is our own fixed flag list, not user input
            "$0" "$capture" $args || rc=1
        done
        [ "$pending" = "1" ] || break
    done

    [ "$found" = "1" ] || echo "leaf-record-convert: no captures in $SRC"
    exit $rc
fi

[ -f "$SRC" ] || die "no such capture: $SRC"

case "$SRC" in
    *.mkv) ;;
    *) die "expected a .mkv capture or a directory, got: $SRC" ;;
esac

# Single-file mode locks too, unless a directory run above already holds it. Without
# this, running the script by hand on one capture while the daemon's directory pass
# is in flight races freely on the same .mp4.part and the same part filenames --
# which is the corruption the lock is for, entered through the other door.
if [ "${LEAF_RECORD_CONVERT_LOCKED:-0}" != "1" ]; then
    if ! acquire_lock; then
        echo "leaf-record-convert: another conversion is running, skipping"
        exit 0
    fi
    trap 'release_lock' EXIT
    trap 'release_lock; exit 130' INT
    trap 'release_lock; exit 143' TERM
fi

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

# Refuse to start if the card cannot hold the work. At peak this holds the .mkv,
# the full .mp4 and every part at once -- roughly the source size twice over --
# and the SD card is also where library.db, settings and save states live. Filling
# it does not just cost the recording: writes start failing across Leaf, and a
# dirty FAT32 at the next reboot can flip the whole card read-only. Declining is
# cheap; the capture is still there to convert once there is room.
src_kb=$(du -k "$SRC" 2>/dev/null | awk '{print $1; exit}')
free_kb=$(df -k "$(dirname "$SRC")" 2>/dev/null | awk 'NR==2 {print $4; exit}')
if [ -n "$src_kb" ] && [ -n "$free_kb" ] && [ "$free_kb" -lt $((src_kb * 2)) ]; then
    die "not enough free space to convert $(basename "$SRC") (need ~$((src_kb * 2 / 1024))MB, have $((free_kb / 1024))MB)"
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
# CUT AT EVERY KEYFRAME, THEN PACK BY BYTES. The split runs in two stream-copy
# passes: the segment muxer breaks the file at each keyframe, and consecutive
# pieces are then concatenated into parts, taking pieces until the next one would
# cross the limit.
#
# Packing beats sizing a window, and the difference is not small. Three shapes
# were tried before this one:
#
#   * seconds-per-part from the average bitrate -- wrong for VBR, since a busy
#     stretch runs far above the mean (peak second 4071k against a 2196k average)
#     and an average-sized window over an explosion sails past the target;
#   * `-ss <offset> -i ... -fs <target>` in a loop -- `-ss` before `-i` seeks
#     BACKWARD to the nearest keyframe, so a part began before the offset asked
#     for while the offset advanced by the part's own length. On a 40.8s Tekken
#     clip the parts held 2273 video packets against the source's 2041: 4.6
#     seconds duplicated across the seam;
#   * one `-segment_time` for the whole file, shrunk on retry until the biggest
#     part fit. Correct, but wasteful. A fixed DURATION cannot hold a fixed SIZE
#     when the bitrate varies, so the window has to be sized for the worst
#     stretch and every quieter stretch is then under-filled. Measured on a
#     2m54s Metroid Fusion capture: it shipped 7 parts of 9.53, 6.58, 6.43, 6.15,
#     9.76, 3.91 and 2.54 MB -- two of them barely a quarter full -- where
#     packing the same 44869870 bytes gives 5 of 9.54, 9.54, 9.63, 9.76 and
#     6.45 MB. Two extra uploads, every time.
#
# Nothing is predicted here, which is why there is no target under the limit and
# no retry: every piece size is read off the filesystem before it is committed to
# a part. Concatenating k pieces also comes out slightly UNDER their sum, since
# the result carries one container header instead of k -- measured at ~1.5KB per
# piece, 44932035 summed against 44869870 whole -- so packing to the limit errs
# in the safe direction.
#
# `-segment_time 1` means "cut at the first keyframe past every second", which
# for any real capture is simply "cut at every keyframe" -- the GOP is seconds
# long. It avoids having to know the keyframe interval, which varies by core.
#
# Every failure path here falls back to keeping the single file. A clip that is
# too big to post is a nuisance; a clip destroyed by a half-finished split is not
# recoverable, and the .mkv may already have been deleted on a previous run.
#
# Pieces and parts are built in a scratch directory and only moved into place
# once the whole set has passed its checks. Written straight to their final
# names, a crashed split left part1 newer than the capture -- which is exactly
# what the "already converted" test reads -- so a truncated split was skipped
# forever after. The directory name is fixed rather than derived from the game,
# so no ROM title can end up inside a printf pattern or a concat list.
SPLIT_DONE=0
if [ "$SPLIT" = "1" ] && [ "$(wc -c < "$TMP")" -gt "$SPLIT_LIMIT_BYTES" ]; then
    whole_bytes=$(($(wc -c < "$TMP")))
    SEGDIR="$(dirname "$SRC")/.leaf-split-tmp"
    ok=0

    rm -rf "$SEGDIR"
    if mkdir -p "$SEGDIR" 2>/dev/null && \
       "$FFMPEG" -v error -y -i "$TMP" -c copy \
            -f segment -segment_time 1 -reset_timestamps 1 \
            -segment_start_number 1 -segment_format mp4 \
            "$SEGDIR/g%05d.mp4" 2>/dev/null && \
       [ -s "$SEGDIR/g00001.mp4" ]; then

        # Piece sizes, read back from the filesystem. Independent of anything
        # that produced them.
        piece_total=0
        piece_count=0
        piece_max=0
        for f in "$SEGDIR"/g*.mp4; do
            [ -s "$f" ] || continue
            sz=$(($(wc -c < "$f")))
            piece_total=$((piece_total + sz))
            [ "$sz" -gt "$piece_max" ] && piece_max=$sz
            piece_count=$((piece_count + 1))
        done

        # A single keyframe-to-keyframe piece over the limit cannot be split any
        # finer without re-encoding, so packing cannot help and one file is the
        # honest answer.
        if [ "$piece_count" -lt 2 ]; then
            echo "leaf-record-convert: nothing to split in $(basename "$BASE"), keeping one file" >&2
        elif [ "$piece_count" -gt "$SPLIT_MAX_PIECES" ]; then
            echo "leaf-record-convert: $piece_count keyframe pieces in $(basename "$BASE"), keeping one file" >&2
        elif [ "$piece_max" -gt "$SPLIT_LIMIT_BYTES" ]; then
            echo "leaf-record-convert: a single keyframe span of $(basename "$BASE") is over the limit, keeping one file" >&2
        elif [ "$(awk -v p="$piece_total" -v w="$whole_bytes" 'BEGIN{print (p < w * 0.97)}')" = "1" ]; then
            # The pieces must account for the file before anything is built from
            # them. Checked in bytes off the filesystem, not from the numbers that
            # drove the cut.
            echo "leaf-record-convert: cut kept only $((piece_total * 100 / whole_bytes))% of $(basename "$BASE"), keeping one file" >&2
        else
            # Greedy first-fit over a sequence that has to stay in order is
            # optimal for this: it yields the fewest parts that each fit.
            ok=1
            part_n=1
            group_bytes=0
            list="$SEGDIR/list.txt"
            : > "$list"
            for f in "$SEGDIR"/g*.mp4; do
                [ -s "$f" ] || continue
                sz=$(($(wc -c < "$f")))
                if [ "$group_bytes" -gt 0 ] && \
                   [ $((group_bytes + sz)) -gt "$SPLIT_LIMIT_BYTES" ]; then
                    if ! jw_concat_group "$list" "$SEGDIR/p${part_n}.mp4"; then
                        ok=0
                        break
                    fi
                    part_n=$((part_n + 1))
                    group_bytes=0
                    : > "$list"
                fi
                printf "file '%s'\n" "$f" >> "$list"
                group_bytes=$((group_bytes + sz))
            done
            # The final group has no successor to trigger the flush above.
            if [ "$ok" = "1" ] && [ "$group_bytes" -gt 0 ]; then
                if jw_concat_group "$list" "$SEGDIR/p${part_n}.mp4"; then
                    part_n=$((part_n + 1))
                else
                    ok=0
                fi
            fi
            parts_made=$((part_n - 1))

            if [ "$ok" = "1" ] && [ "$parts_made" -gt "$SPLIT_MAX_PARTS" ]; then
                ok=0
            fi

            # Verify what was actually written, not what the loop believes it
            # wrote: every part present and non-empty, none over the limit, and
            # the set accounting for the whole file.
            if [ "$ok" = "1" ]; then
                built_bytes=0
                i=1
                while [ "$i" -le "$parts_made" ]; do
                    if [ ! -s "$SEGDIR/p${i}.mp4" ]; then
                        ok=0
                        break
                    fi
                    sz=$(($(wc -c < "$SEGDIR/p${i}.mp4")))
                    if [ "$sz" -gt "$SPLIT_LIMIT_BYTES" ]; then
                        echo "leaf-record-convert: part $i of $(basename "$BASE") came out over the limit" >&2
                        ok=0
                        break
                    fi
                    built_bytes=$((built_bytes + sz))
                    i=$((i + 1))
                done
                if [ "$ok" = "1" ] && \
                   [ "$(awk -v b="$built_bytes" -v w="$whole_bytes" 'BEGIN{print (b < w * 0.97)}')" = "1" ]; then
                    echo "leaf-record-convert: parts of $(basename "$BASE") hold only $((built_bytes * 100 / whole_bytes))%, keeping one file" >&2
                    ok=0
                fi
            fi

            if [ "$ok" = "1" ]; then
                rm -f "${BASE}"-part*.mp4
                i=1
                while [ "$i" -le "$parts_made" ]; do
                    mv "$SEGDIR/p${i}.mp4" "${BASE}-part${i}.mp4" || { ok=0; break; }
                    i=$((i + 1))
                done
                if [ "$ok" = "1" ]; then
                    SPLIT_DONE=1
                    rm -f "$TMP"
                    sync
                    echo "leaf-record-convert: $(basename "$BASE") split into $parts_made parts"
                else
                    rm -f "${BASE}"-part*.mp4
                    echo "leaf-record-convert: could not place parts for $(basename "$BASE"), keeping one file" >&2
                fi
            fi
        fi
    fi

    [ "$SPLIT_DONE" = "1" ] || [ "$ok" = "1" ] || \
        echo "leaf-record-convert: split failed for $(basename "$BASE"), keeping one file" >&2
    rm -rf "$SEGDIR"
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
