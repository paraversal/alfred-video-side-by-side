#!/bin/bash
#
# Side by Side — compare two versions of the same video, split down the middle.
# Left half: the compressed file. Right half: the original.
#
# Called by the Alfred File Action with exactly two file paths as arguments.
# mpv is launched detached; this script returns immediately.

set -u

MPV="${SBS_MPV_BIN:-/opt/homebrew/bin/mpv}"
FFPROBE="${SBS_FFPROBE_BIN:-/opt/homebrew/bin/ffprobe}"
AWK=/usr/bin/awk
OSASCRIPT=/usr/bin/osascript

SCRIPT_DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd) || exit 1
LUA_SCRIPT="$SCRIPT_DIR/sbs.lua"

notify() {
    local title="$1"
    local message="$2"

    /usr/bin/osascript - "$title" "$message" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

die() {
    printf 'side-by-side: %s\n' "$1" >&2
    notify "Side by Side" "$1"
    exit 1
}

if [ "$#" -ne 2 ]; then
    die "Select exactly two videos."
fi

FILE_A="$1"
FILE_B="$2"

for file in "$FILE_A" "$FILE_B"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        die "“${file##*/}” isn’t a readable file."
    fi
done

if [ "$FILE_A" = "$FILE_B" ]; then
    die "Choose two different videos."
fi

if [ ! -x "$FFPROBE" ]; then
    die "ffprobe is missing — install it with: brew install ffmpeg"
fi
if [ ! -x "$MPV" ]; then
    die "mpv is missing — install it with: brew install mpv"
fi
if [ ! -f "$LUA_SCRIPT" ]; then
    die "The workflow is incomplete (sbs.lua is missing)."
fi

SIZE_A=$(/usr/bin/stat -f%z "$FILE_A" 2>/dev/null) || die "Couldn’t read “${FILE_A##*/}”."
SIZE_B=$(/usr/bin/stat -f%z "$FILE_B" 2>/dev/null) || die "Couldn’t read “${FILE_B##*/}”."

# Bigger file = original (right). Smaller file = compressed (left).
if [ "$SIZE_A" -gt "$SIZE_B" ]; then
    ORIG="$FILE_A"
    COMP="$FILE_B"
    ORIG_BYTES="$SIZE_A"
    COMP_BYTES="$SIZE_B"
else
    ORIG="$FILE_B"
    COMP="$FILE_A"
    ORIG_BYTES="$SIZE_B"
    COMP_BYTES="$SIZE_A"
fi

probe_video() {
    local file="$1"
    local info width height side_rotation tag_rotation rotation

    info=$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=width,height:stream_side_data=rotation:stream_tags=rotate \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null) || return 1

    width=$(printf '%s\n' "$info" | "$AWK" -F= '$1 == "width" { print $2; exit }')
    height=$(printf '%s\n' "$info" | "$AWK" -F= '$1 == "height" { print $2; exit }')

    case "$width" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$height" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$width" -lt 1 ] || [ "$height" -lt 1 ]; then
        return 1
    fi

    # Display-matrix rotation is newer; the rotate tag is the older fallback.
    side_rotation=$(printf '%s\n' "$info" | "$AWK" -F= \
        '$1 == "rotation" || $1 == "rotate" { print $2; exit }')
    tag_rotation=$(printf '%s\n' "$info" | "$AWK" -F= \
        '$1 == "TAG:rotate" { print $2; exit }')
    rotation="${side_rotation:-${tag_rotation:-0}}"

    # Keep only the four meaningful orientations. A malformed value becomes 0.
    rotation=$(LC_ALL=C "$AWK" -v r="$rotation" 'BEGIN {
        r = r + 0
        r = r % 360
        if (r < 0) r += 360
        if (r >= 45 && r < 135) print 90
        else if (r >= 135 && r < 225) print 180
        else if (r >= 225 && r < 315) print 270
        else print 0
    }')

    printf '%s %s %s\n' "$width" "$height" "$rotation"
}

COMP_META=$(probe_video "$COMP") || die "“${COMP##*/}” doesn’t have a readable video stream."
ORIG_META=$(probe_video "$ORIG") || die "“${ORIG##*/}” doesn’t have a readable video stream."

read -r COMP_W COMP_H COMP_ROT <<< "$COMP_META"
read -r ORIG_W ORIG_H ORIG_ROT <<< "$ORIG_META"

# A filter graph bypasses mpv's automatic rotation, so rotation is applied
# inside the graph. Portrait/landscape changes with a 90/270 degree rotation.
ORIG_DISPLAY_W="$ORIG_W"
ORIG_DISPLAY_H="$ORIG_H"
case "$ORIG_ROT" in
    90|270)
        ORIG_DISPLAY_W="$ORIG_H"
        ORIG_DISPLAY_H="$ORIG_W"
        ;;
esac

# The right half defines the output. Round the width to a multiple of four so
# both halves are even-sized, which keeps 4:2:0 chroma happy through hstack.
TARGET_W=$(( (ORIG_DISPLAY_W / 4) * 4 ))
TARGET_H=$(( (ORIG_DISPLAY_H / 2) * 2 ))
if [ "$TARGET_W" -lt 16 ] || [ "$TARGET_H" -lt 16 ]; then
    die "The original’s video resolution is unusable."
fi

rotation_filter() {
    case "$1" in
        90)  printf 'transpose=cclock,' ;;
        180) printf 'hflip,vflip,' ;;
        270) printf 'transpose=clock,' ;;
        *)   printf '' ;;
    esac
}

COMP_CHAIN="$(rotation_filter "$COMP_ROT")scale=${TARGET_W}:${TARGET_H},setsar=1,crop=iw/2:ih:0:0[l]"
ORIG_CHAIN="$(rotation_filter "$ORIG_ROT")scale=${TARGET_W}:${TARGET_H},setsar=1,crop=iw/2:ih:iw/2:0[r]"
FILTER="[vid1]${COMP_CHAIN};[vid2]${ORIG_CHAIN};[l][r]hstack=inputs=2[vo]"

human_size() {
    LC_ALL=C "$AWK" -v b="$1" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (b >= 1000 && i < 5) {
            b /= 1000
            i++
        }
        if (i == 1) printf "%d B", b
        else if (i == 2) printf "%.0f KB", b
        else printf "%.1f %s", b, unit[i]
    }'
}

COMP_SIZE=$(human_size "$COMP_BYTES")
ORIG_SIZE=$(human_size "$ORIG_BYTES")
COMP_MAIN="$COMP_SIZE"
COMP_NOTE="compressed · same size"

if [ "$ORIG_BYTES" -gt "$COMP_BYTES" ]; then
    read -r PCT RATIO <<< "$(LC_ALL=C "$AWK" \
        -v c="$COMP_BYTES" -v o="$ORIG_BYTES" 'BEGIN {
            p = (1 - c / o) * 100
            if (p < 0) p = 0
            if (p >= 10) printf "%.0f ", p
            else printf "%.1f ", p
            printf "%.1f\n", o / c
        }')"

    COMP_MAIN="$COMP_SIZE · −${PCT}%"
    if LC_ALL=C "$AWK" -v r="$RATIO" 'BEGIN { exit !(r >= 1.2) }'; then
        COMP_NOTE="compressed · ${RATIO}× smaller"
    else
        COMP_NOTE="compressed"
    fi
fi

ORIG_MAIN="$ORIG_SIZE"
ORIG_NOTE="original"

TITLE="Side by Side — ${COMP##*/}  ↔  ${ORIG##*/}"

# Log beside Alfred's cached workflow data when Alfred provides it.
if [ -n "${alfred_workflow_cache:-}" ]; then
    LOG_DIR="$alfred_workflow_cache"
else
    TMP_BASE="${TMPDIR:-/tmp}"
    TMP_BASE="${TMP_BASE%/}"
    LOG_DIR="${TMP_BASE}/side-by-side-workflow"
fi
if ! /bin/mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="${TMPDIR:-/tmp}"
fi
LOG="$LOG_DIR/side-by-side.log"
# If neither Alfred's cache nor the temp directory is writable, keep playback
# working by discarding the diagnostic log instead of failing the redirection.
if ! ( : >> "$LOG" ) 2>/dev/null; then
    LOG=/dev/null
fi

{
    printf '\n--- %s ---\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
    printf 'compressed: %s (%s bytes)\n' "$COMP" "$COMP_BYTES"
    printf 'original:   %s (%s bytes)\n' "$ORIG" "$ORIG_BYTES"
    printf 'rotation:   compressed=%s original=%s\n' "$COMP_ROT" "$ORIG_ROT"
    printf 'target:     %sx%s\n' "$TARGET_W" "$TARGET_H"
    printf 'labels:     %s / %s / %s / %s\n' \
        "$COMP_MAIN" "$COMP_NOTE" "$ORIG_MAIN" "$ORIG_NOTE"
    printf 'filter:     %s\n' "$FILTER"
} >> "$LOG" 2>&1

ARGS=(
    --no-config
    --force-window=yes
    --autofit=100%x100%
    --title="$TITLE"
    --mute=yes
    --loop-file=inf
    --input-media-keys=no
    --media-controls=no
    --hwdec=auto-copy
    --osc=no
    --osd-level=0
    --sid=no
    --sub-auto=no
    --script="$LUA_SCRIPT"
    --script-opt="sbs-left-main=$COMP_MAIN"
    --script-opt="sbs-left-note=$COMP_NOTE"
    --script-opt="sbs-right-main=$ORIG_MAIN"
    --script-opt="sbs-right-note=$ORIG_NOTE"
    --external-file="$ORIG"
    --lavfi-complex="$FILTER"
    "$COMP"
)

{
    printf 'mpv: %s\n' "$MPV"
    for arg in "${ARGS[@]}"; do
        printf '  %s\n' "$arg"
    done
} >> "$LOG" 2>&1

/usr/bin/nohup "$MPV" "${ARGS[@]}" </dev/null >> "$LOG" 2>&1 &
printf 'mpv pid:    %s\n' "$!" >> "$LOG"
exit 0
