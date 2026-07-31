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
# ffmpeg's -fs stops writing once the limit is crossed, and it does so at coarse
# chunk boundaries rather than near the target: measured overshoot is 2.5-3.3%
# (230-320KB), and targets of 9.7M and 9.96M both produced the identical
# 10018185-byte file. 7% of headroom covers that with room to spare. If this ever
# proves too tight the fallback catches it -- the script verifies the largest part
# against SPLIT_LIMIT_BYTES and keeps a single file rather than ship parts that
# are too big to post.
SPLIT_TARGET_BYTES=9300000

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
            # Termination is tested HERE, before writing anything, so that a
            # failure below is unambiguously a failure. The previous shape ran
            # ffmpeg first and treated "it produced nothing" as "we reached the
            # end" for every part after the first -- so a card that filled up, or
            # an OOM kill, silently ended the split, declared success, and (with
            # --delete-source) deleted the .mkv. Half a recording, exit 0.
            if [ "$(awk -v o="$offset" -v d="$duration" 'BEGIN{print (o >= d - 0.5)}')" = "1" ]; then
                break
            fi

            part="${BASE}-part${n}.mp4"
            if ! "$FFMPEG" -v error -y -ss "$offset" -i "$TMP" -c copy \
                    -fs "$SPLIT_TARGET_BYTES" -movflags +faststart \
                    -f mp4 "$part" 2>/dev/null || [ ! -s "$part" ]; then
                rm -f "$part"
                ok=0
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
            n=$((n + 1))
            if [ "$n" -gt 64 ]; then        # backstop; no real capture needs this
                ok=0
                break
            fi
        done

        # Do the parts actually contain the whole recording? Checked in BYTES on
        # purpose. The obvious check -- sum the part durations and compare against
        # the source -- is worthless here, because the offset advances by exactly
        # the duration each part reports, so that sum always equals the offset and
        # the test can never fail. Bytes come from the filesystem instead, so they
        # are independent of the arithmetic driving the loop.
        #
        # This catches the silent gap: `-ss` before `-i` seeks BACKWARD to a
        # keyframe, so a part starts at or before the offset asked for while the
        # offset advances by the part's full length. The next part therefore begins
        # at or after where the previous one ended, and anything in between lands
        # in no part at all. Missing seconds are missing bytes.
        #
        # 3% covers per-part container overhead (each part carries its own moov).
        if [ "$ok" = "1" ]; then
            part_bytes=0
            for f in "${BASE}"-part*.mp4; do
                [ -e "$f" ] || continue
                part_bytes=$((part_bytes + $(wc -c < "$f")))
            done
            whole_bytes=$(wc -c < "$TMP")
            if [ "$(awk -v p="$part_bytes" -v w="$whole_bytes" 'BEGIN{print (p < w * 0.97)}')" = "1" ]; then
                ok=0
                echo "leaf-record-convert: split kept only $((part_bytes * 100 / whole_bytes))% of $(basename "$BASE"), keeping one file" >&2
            fi
        fi

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
