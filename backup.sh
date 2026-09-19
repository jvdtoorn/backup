#!/usr/bin/env bash
#
# Copy a source folder to a target folder with rsync, and write a CSV of the
# file extensions that were copied in this run to logs/<date>_<time>.csv
# (next to this script). Run it without arguments for help.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FILTER="$SCRIPT_DIR/backup.filter"
LOG_DIR="$SCRIPT_DIR/logs"

usage() {
  cat <<HELP
Usage: ./backup.sh [options] <source> <target>

Copies everything in <source> into <target>, skipping what the filter file
excludes. Shows overall progress while copying. Run the same command again to
continue an interrupted backup: files already in <target> are skipped.
Nothing is ever deleted from <target>.

Arguments:
  <source>   Folder to back up, e.g. ~ (same as ~/).
  <target>   Folder to copy into. Created if it doesn't exist yet.
             The contents of <source> land directly inside it.

Options:
  -f, --filter FILE   rsync filter rules deciding what to skip. Paths in it are
                      relative to <source>. Default: backup.filter next to this
                      script. If that file is missing, --filter is required.
  -n, --dry-run       Copy nothing, only write the extensions CSV.
  -h, --help          Show this help.

Regardless of the filter file, dotfiles named after a number (.1, .23, ...) are
always skipped, except the .42 directly in <source>.

Each run writes one line of the file extensions it copied to
$LOG_DIR/<date>_<time>.csv.
Use it to tune the filter file.

Examples:
  ./backup.sh ~ "/Volumes/Backup Disk/home"
  ./backup.sh --dry-run ~/Documents /Volumes/Backup/docs
  ./backup.sh -f ~/my.filter ~ /Volumes/Backup/home
HELP
}

die() { echo "Error: $1" >&2; echo "Run ./backup.sh --help for usage." >&2; exit 2; }

# Expand a literal leading "~" (in case the shell didn't, e.g. it was quoted).
expand_tilde() {
  case "$1" in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${1#"~/"}" ;;
    *) echo "$1" ;;
  esac
}

# Absolute path without trailing slash, also for folders that don't exist yet.
abs_path() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" && pwd)
  else
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    echo "$p"
  fi
}

[ $# -gt 0 ] || { usage; exit 0; }

DRY_RUN=0
FILTER_FILE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -f|--filter)
      [ $# -ge 2 ] || die "$1 needs a file"
      FILTER_FILE="$2"; shift ;;
    --filter=*) FILTER_FILE="${1#--filter=}" ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) die "unknown option: $1" ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
[ "${#POSITIONAL[@]}" -eq 2 ] || die "need exactly two folders: <source> <target> (got ${#POSITIONAL[@]})"

SRC_ARG="$(expand_tilde "${POSITIONAL[0]}")"
TARGET_ARG="$(expand_tilde "${POSITIONAL[1]}")"

[ -d "$SRC_ARG" ] || die "source is not an existing folder: $SRC_ARG"
SOURCE="$(abs_path "$SRC_ARG")"
TARGET="$(abs_path "$TARGET_ARG")"
[ "$SOURCE" != "$TARGET" ] || die "source and target are the same folder: $SOURCE"

if [ -n "$FILTER_FILE" ]; then
  FILTER_FILE="$(expand_tilde "$FILTER_FILE")"
  [ -f "$FILTER_FILE" ] || die "filter file not found: $FILTER_FILE"
elif [ -f "$DEFAULT_FILTER" ]; then
  FILTER_FILE="$DEFAULT_FILTER"
else
  die "no backup.filter found next to this script ($DEFAULT_FILTER). Pass one with --filter FILE."
fi
FILTER_FILE="$(cd "$(dirname "$FILTER_FILE")" && pwd)/$(basename "$FILTER_FILE")"

# macOS ships an old rsync (2.6.9 / openrsync) without the overall progress
# display. Need rsync >= 3.1, e.g. `brew install rsync`.
RSYNC="$(command -v rsync || true)"
RSYNC_VERSION="$("$RSYNC" --version 2>/dev/null | sed -n '1s/^rsync  *version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
if [ -z "$RSYNC_VERSION" ] || [ "${RSYNC_VERSION% *}" -lt 3 ] || { [ "${RSYNC_VERSION% *}" -eq 3 ] && [ "${RSYNC_VERSION#* }" -lt 1 ]; }; then
  echo "Need rsync 3.1 or newer for progress reporting (found: ${RSYNC:-none}). Install it with: brew install rsync" >&2
  exit 1
fi

EXTRA_ARGS=()
# If the target lives inside the source, don't copy the backup into itself.
case "$TARGET" in
  "${SOURCE%/}"/*) EXTRA_ARGS+=(--exclude="/${TARGET#"${SOURCE%/}"/}/") ;;
esac
if [ "$DRY_RUN" -eq 1 ]; then
  EXTRA_ARGS+=(--dry-run)
  mkdir -p "$LOG_DIR"
else
  mkdir -p "$LOG_DIR" "$TARGET" || { echo "Could not create target folder: $TARGET" >&2; exit 1; }
fi
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
[ "$DRY_RUN" -eq 1 ] && STAMP="${STAMP}_dry-run"
CSV="$LOG_DIR/$STAMP.csv"
ERRORS="$LOG_DIR/$STAMP.errors.txt"

TMP_DIR="$(mktemp -d)"
RSYNC_LOG="$TMP_DIR/rsync.log"
RSYNC_ERR="$TMP_DIR/rsync.err"

# Turn rsync's log of transferred files into one CSV line of unique extensions:
#   photo.PNG -> *.png    .zshrc -> .zshrc    Makefile -> (none)
write_csv() {
  [ -f "$RSYNC_LOG" ] || : > "$RSYNC_LOG"
  awk '
    match($0, /@@ >f[^ ]+ /) {
      path = substr($0, RSTART + RLENGTH)
      n = split(path, parts, "/")
      name = parts[n]
      hidden = (substr(name, 1, 1) == ".")
      rest = hidden ? substr(name, 2) : name
      dot = 0
      for (i = length(rest); i > 0; i--) if (substr(rest, i, 1) == ".") { dot = i; break }
      if (dot > 0 && dot < length(rest)) out = "*." tolower(substr(rest, dot + 1))
      else if (hidden) out = name
      else out = "(none)"
      if (out ~ /[,"]/) { gsub(/"/, "\"\"", out); out = "\"" out "\"" }
      print out
    }
  ' "$RSYNC_LOG" | sort -u | paste -sd, - > "$CSV"
}

FINISHED=0
cleanup() {
  # Runs on normal exit and on Ctrl-C, so an interrupted run still gets its CSV.
  write_csv
  # After Ctrl-C, rsync's own "received SIGINT" complaints aren't worth keeping.
  if [ "$FINISHED" -eq 1 ] && [ -s "$RSYNC_ERR" ]; then
    cp "$RSYNC_ERR" "$ERRORS"
    echo
    echo "$(wc -l < "$RSYNC_ERR" | tr -d ' ') warning/error lines from rsync, first few:"
    head -n 10 "$RSYNC_ERR"
    echo "Full list: $ERRORS"
  fi
  [ "$FINISHED" -eq 1 ] || echo "Interrupted. Run the same command again to continue."
  echo "Extensions copied in this run: $CSV"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Skip dotfiles named after a number (.1, .23, ...), whatever the length. rsync
# has no "one or more digits" pattern, so generate one rule per length. rsync
# drops rules longer than ~1000 characters (5 per digit), so exact rules stop at
# 199 digits and one last rule skips any dotfile starting with 200+ digits.
# These come after the filter file's rules. The one exception: /.42, directly
# in <source>.
NUMBERED_FILTER="$TMP_DIR/numbered.filter"
{
  echo "+ /.42"
  pattern="."
  for _ in $(seq 1 199); do
    pattern="$pattern[0-9]"
    echo "- $pattern"
  done
  echo "- $pattern[0-9]*"
} > "$NUMBERED_FILTER"

echo "Source:      ${SOURCE%/}/"
echo "Destination: $TARGET/"
[ "$DRY_RUN" -eq 1 ] && echo "Dry run: nothing will be copied."
echo "Scanning files first (no progress shown yet, can take a few minutes), then copying..."

# -a        keep permissions, times and symlinks
# -x        don't cross into other volumes mounted below ~
# --no-inc-recursive: scan everything first so the percentage is accurate
# --partial keep half-copied big files so a re-run can resume them
# --info=progress2: one line with overall percent, speed and time remaining
"$RSYNC" -ahx \
  --no-inc-recursive \
  --partial \
  --info=progress2,name0,stats1 \
  --log-file="$RSYNC_LOG" \
  --log-file-format='@@ %i %n' \
  --filter=". $FILTER_FILE" \
  --filter=". $NUMBERED_FILTER" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  "${SOURCE%/}/" "$TARGET/" 2> "$RSYNC_ERR"
STATUS=$?

FINISHED=1
# 23 = some files couldn't be read, 24 = files vanished while copying: both are
# normal for a live home folder and are reported by cleanup().
case "$STATUS" in
  0|23|24) exit 0 ;;
  *) echo "rsync failed with exit code $STATUS" >&2; exit "$STATUS" ;;
esac
