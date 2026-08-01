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
# What each part aims for. Parts can only break on a keyframe, and the capture puts
# one every 5 seconds (measured: 9 keyframes across a 40.8s clip, at 0/5/10/...), so
# a part lands on whichever keyframe first passes the requested length and overshoots
# by up to one GOP. 7% of headroom covers that at the ~2500k capture bitrate, and the
# retry below covers the rest.
SPLIT_TARGET_BYTES=9300000
SPLIT_MAX_PARTS=64              # backstop; no real capture needs this many

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
# Cut with the SEGMENT MUXER, which is what makes the parts add up to the whole.
# Two earlier shapes did not:
#
#   * a computed seconds-per-part from the average bitrate -- wrong for VBR, since
#     a busy stretch runs far above the mean (peak second 4071k against a 2196k
#     average) and an average-sized window over an explosion sails past the target;
#   * a loop of `-ss <offset> -i ... -fs <target>` -- `-ss` before `-i` seeks
#     BACKWARD to the nearest keyframe, so a part starts before the offset asked
#     for while the offset advances by the part's own length. Measured on a 40.8s
#     Tekken clip: the two parts held 2273 video packets against the source's 2041,
#     i.e. 4.6 seconds duplicated across the seam, and part 2's duration header
#     (6.18s) disagreed with the 10.8s of video actually inside it.
#
# The segment muxer starts each new file exactly at the first keyframe past the
# requested length and never rewinds, so parts tile the recording end to end.
# Verified on the same clip: 1750 + 291 = 2041 video packets, matching the source
# exactly, and 11479519 bytes of parts against 11477960 whole.
#
# Size is then an OUTER loop: aim, measure the biggest part, shrink and re-cut if
# it came out over. Re-cutting is a stream copy over a file that is already local,
# so an extra attempt is cheap.
#
# Every failure path here falls back to keeping the single file. A clip that is
# too big to post is a nuisance; a clip destroyed by a half-finished split is not
# recoverable, and the .mkv may already have been deleted on a previous run.
#
# Segments are written into a scratch directory and only moved into place once the
# whole set has passed its checks. Writing them straight to their final names left
# a crashed run looking finished -- the "already converted" test keys on part1
# being newer than the capture, so a truncated split was skipped forever after.
# The name is fixed rather than derived from the game so no ROM title can turn
# into part of a printf pattern (a "%d" in a filename would be substituted).
SPLIT_DONE=0
if [ "$SPLIT" = "1" ] && [ "$(wc -c < "$TMP")" -gt "$SPLIT_LIMIT_BYTES" ]; then
    duration=$(probe_seconds "$TMP")
    whole_bytes=$(wc -c < "$TMP")
    SEGDIR="$(dirname "$SRC")/.leaf-split-tmp"
    if [ -n "$duration" ]; then
        ok=0
        attempt=1
        prev_biggest=0
        # First guess is proportional: the clip is one bitrate on average, so
        # target/whole of its length is roughly the length that holds a target.
        seg_time=$(awk -v d="$duration" -v w="$whole_bytes" -v t="$SPLIT_TARGET_BYTES" \
                       'BEGIN{ printf "%.3f", d * t / w }')
        while [ "$attempt" -le 4 ]; do
            # Below one segment interval there is nothing left to give: parts can
            # only break on keyframes, so asking for less just returns the same cut.
            [ "$(awk -v s="$seg_time" 'BEGIN{print (s < 1)}')" = "1" ] && break

            rm -rf "$SEGDIR"
            mkdir -p "$SEGDIR" 2>/dev/null || break

            if ! "$FFMPEG" -v error -y -i "$TMP" -c copy \
                    -f segment -segment_time "$seg_time" -reset_timestamps 1 \
                    -segment_start_number 1 -segment_format mp4 \
                    -segment_format_options movflags=+faststart \
                    "$SEGDIR/p%d.mp4" 2>/dev/null; then
                break
            fi
            [ -s "$SEGDIR/p1.mp4" ] || break

            seg_bytes=0
            biggest_bytes=0
            count=0
            for f in "$SEGDIR"/p*.mp4; do
                [ -s "$f" ] || continue
                # $(( )) around wc strips the leading whitespace some wc builds
                # print, which would otherwise travel into every comparison below.
                sz=$(($(wc -c < "$f")))
                seg_bytes=$((seg_bytes + sz))
                if [ "$sz" -gt "$biggest_bytes" ]; then
                    biggest_bytes=$sz
                fi
                count=$((count + 1))
            done

            # One segment means the guess was longer than the recording; more than
            # the backstop means something is very wrong with the arithmetic.
            if [ "$count" -lt 2 ] || [ "$count" -gt "$SPLIT_MAX_PARTS" ]; then
                break
            fi

            # The numbering has to be unbroken, because the move below walks it and
            # stops at the first name it cannot find. An empty file in the middle
            # would end that walk early and leave the tail of the recording behind
            # in the scratch directory, with the run still reporting success.
            i=1
            while [ "$i" -le "$count" ] && [ -s "$SEGDIR/p${i}.mp4" ]; do
                i=$((i + 1))
            done
            if [ "$i" -le "$count" ]; then
                echo "leaf-record-convert: segment $i missing for $(basename "$BASE"), keeping one file" >&2
                break
            fi

            # Independent check on the muxer's own bookkeeping, in BYTES read back
            # from the filesystem rather than from the numbers that drove the cut.
            # 3% covers each part carrying its own moov.
            if [ "$(awk -v p="$seg_bytes" -v w="$whole_bytes" 'BEGIN{print (p < w * 0.97)}')" = "1" ]; then
                echo "leaf-record-convert: split kept only $((seg_bytes * 100 / whole_bytes))% of $(basename "$BASE"), keeping one file" >&2
                break
            fi

            if [ "$biggest_bytes" -le "$SPLIT_LIMIT_BYTES" ]; then
                ok=1
                break
            fi

            # Overshot. Normally shrink by exactly how much the worst part missed
            # by, with a little extra so the next keyframe boundary does not land
            # on the line.
            #
            # That alone can stall, because parts break on keyframes and the
            # proportional shrink can land inside the same 5-second window -- so
            # the cut does not move and the attempt returns a byte-identical set.
            # Seen with a 3MB test limit: 6.952s and 6.151s both broke at 10s and
            # both produced a 3212250-byte part. When an attempt makes no progress,
            # step down hard enough to clear a whole keyframe interval instead.
            if [ "$attempt" -gt 1 ] && [ "$biggest_bytes" -ge "$prev_biggest" ]; then
                seg_time=$(awk -v s="$seg_time" 'BEGIN{ printf "%.3f", s * 0.6 }')
            else
                seg_time=$(awk -v s="$seg_time" -v b="$biggest_bytes" -v t="$SPLIT_TARGET_BYTES" \
                               'BEGIN{ printf "%.3f", s * t / b * 0.98 }')
            fi
            prev_biggest=$biggest_bytes
            attempt=$((attempt + 1))
        done

        if [ "$ok" = "1" ]; then
            rm -f "${BASE}"-part*.mp4
            n=1
            while [ -s "$SEGDIR/p${n}.mp4" ]; do
                mv "$SEGDIR/p${n}.mp4" "${BASE}-part${n}.mp4" || { ok=0; break; }
                n=$((n + 1))
            done
            if [ "$ok" = "1" ]; then
                SPLIT_DONE=1
                rm -f "$TMP"
                sync
                echo "leaf-record-convert: $(basename "$BASE") split into $((n - 1)) parts"
            else
                rm -f "${BASE}"-part*.mp4
                echo "leaf-record-convert: could not place parts for $(basename "$BASE"), keeping one file" >&2
            fi
        else
            echo "leaf-record-convert: split failed for $(basename "$BASE"), keeping one file" >&2
        fi
        rm -rf "$SEGDIR"
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
