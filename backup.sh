#!/usr/bin/env bash
#
# Copy a source folder to a target folder with rsync, and log what kind of files
# were copied in this run to logs/<date>_<time>/ (next to this script):
# extensions.csv and progress.log. Run it without arguments for help.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IGNORE="$SCRIPT_DIR/backup.ignore"
DEFAULT_ALLOW="$SCRIPT_DIR/backup.allow"
LOG_DIR="$SCRIPT_DIR/logs"
LOCAL_DIR="$SCRIPT_DIR/.local"

# Circuit breakers for the traversal. These are not filter rules: they exist so
# a malformed, cyclic or unexpectedly huge tree makes the run stop with an
# explanation instead of walking forever. Override them per run, e.g.
#   MAX_DEPTH=100 ./backup.sh ~ /Volumes/Backup/home
MAX_DEPTH=${MAX_DEPTH:-64}
MAX_ENTRIES_PER_DIRECTORY=${MAX_ENTRIES_PER_DIRECTORY:-100000}
MAX_TOTAL_ENTRIES=${MAX_TOTAL_ENTRIES:-5000000}
# The tree-shape limits can't notice a folder that simply stops answering
# (unhealthy disk, a stuck network or FUSE mount), so the check has a deadline.
MAX_PREFLIGHT_SECONDS=${MAX_PREFLIGHT_SECONDS:-3600}

usage() {
  cat <<HELP
Usage: ./backup.sh [options] <source> <target>

Copies everything in <source> into <target>, skipping what the ignore list
excludes and every hidden file or folder (name starting with ".") that the
allow list doesn't name. Shows overall progress while copying.
Run the same command again to continue an interrupted backup: files already in
<target> are skipped. Nothing is ever deleted from <target>.

Arguments:
  <source>   Folder to back up, e.g. ~ (same as ~/).
  <target>   Folder to copy into. Created if it doesn't exist yet.
             The contents of <source> land directly inside it.

Options:
  -i, --ignore FILE   Patterns to skip, one per line (rsync syntax, paths
                      relative to <source>). Default: backup.ignore next to
                      this script; required if that file is missing.
  -a, --allow FILE    Hidden files/folders to keep, one per line. Default:
                      backup.allow next to this script; required if that
                      file is missing.
  -n, --dry-run       Copy nothing; write the run's logs and the list of files
                      that would have been copied. Shows no progress.
      --print-rules   Print the rsync filter rules built from the two lists and
                      exit, without walking or copying anything.
      --no-local      Leave out the rules in the .local folder (see below).
  -h, --help          Show this help.

The ignore list wins over the allow list. Both files explain their syntax.

A .local folder next to this script may hold its own backup.ignore and
backup.allow. Their entries are added to the two lists above, for this machine
only (the folder is git-ignored). --no-local leaves them out.

Before copying, the source is walked once to check the limits below. Crossing
one stops the run before anything is copied, naming the folder responsible.
Set one in the environment to change it for a single run.

HELP
  printf '  %-25s %7s  %s\n' \
    MAX_DEPTH "$MAX_DEPTH" "levels below <source>" \
    MAX_ENTRIES_PER_DIRECTORY "$MAX_ENTRIES_PER_DIRECTORY" "entries in one folder" \
    MAX_TOTAL_ENTRIES "$MAX_TOTAL_ENTRIES" "entries in the whole run" \
    MAX_PREFLIGHT_SECONDS "$MAX_PREFLIGHT_SECONDS" "seconds for this check itself"
  cat <<HELP

Exit status: 0 when everything was copied (also when some files vanished while
copying), 23 when rsync could not copy some files, which means the backup is
incomplete (see errors.txt in the run's log folder), 2 for a usage error, and 1
or rsync's own code for any other failure, including a crossed safety limit.

Each run writes a folder logs/<date>_<time>/ next to this script with two
files, refreshed every few seconds while copying:
  extensions.csv   one line with the file extensions copied in this run.
                   Use it to tune the ignore list.
  progress.log     "<unix time>: <full path>" whenever the copied file kind
                   changes (extension, hidden file name, or no extension).

Examples:
  ./backup.sh ~ "/Volumes/Backup Disk/home"
  ./backup.sh --dry-run ~/Documents /Volumes/Backup/docs
  ./backup.sh -i ~/my.ignore -a ~/my.allow ~ /Volumes/Backup/home
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

# The real, symlink-free absolute path of a folder, also for one that doesn't
# exist yet (the target). The part that doesn't exist is taken as spelled,
# except that "." and ".." are resolved in it too. This is what the "target
# lies inside the source" check relies on, so "~/x/../backup", a symlink to
# ~ and a differently spelled ~ all have to come out the same.
canonical_path() {
  local path="$1" cur="/" next comp
  local -a parts
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  IFS=/ read -r -a parts <<< "$path"
  for comp in ${parts[@]+"${parts[@]}"}; do
    case "$comp" in
      ""|.) ;;
      ..) cur="$(dirname "$cur")" ;;      # cur has no symlinks, so this is the real parent
      *)
        next="${cur%/}/$comp"
        if [ -d "$next" ]; then cur="$(cd "$next" 2>/dev/null && pwd -P)" || cur="$next"
        else cur="$next"
        fi ;;
    esac
  done
  echo "$cur"
}

for limit in MAX_DEPTH MAX_ENTRIES_PER_DIRECTORY MAX_TOTAL_ENTRIES MAX_PREFLIGHT_SECONDS; do
  eval "value=\$$limit"
  case "$value" in
    ''|*[!0-9]*) die "$limit must be a positive whole number (got: $value)" ;;
    0) die "$limit must be a positive whole number (got: 0)" ;;
  esac
done

[ $# -gt 0 ] || { usage; exit 0; }

DRY_RUN=0
PRINT_RULES=0
USE_LOCAL=1
IGNORE_FILE=""
ALLOW_FILE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --print-rules) PRINT_RULES=1 ;;
    --no-local) USE_LOCAL=0 ;;
    -i|--ignore)
      [ $# -ge 2 ] || die "$1 needs a file"
      IGNORE_FILE="$2"; shift ;;
    --ignore=*) IGNORE_FILE="${1#--ignore=}" ;;
    -a|--allow)
      [ $# -ge 2 ] || die "$1 needs a file"
      ALLOW_FILE="$2"; shift ;;
    --allow=*) ALLOW_FILE="${1#--allow=}" ;;
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
SOURCE="$(canonical_path "$SRC_ARG")"
TARGET="$(canonical_path "$TARGET_ARG")"
[ "$SOURCE" != "$TARGET" ] || die "source and target are the same folder: $SOURCE"

# Absolute path of a list file: the explicit one, else the default next to this script.
resolve_list() {   # <explicit path or ""> <default path> <option name>
  local path="$1" default="$2" option="$3"
  if [ -n "$path" ]; then
    path="$(expand_tilde "$path")"
    [ -f "$path" ] || die "file not found: $path"
  elif [ -f "$default" ]; then
    path="$default"
  else
    die "no $(basename "$default") found next to this script ($default). Pass one with $option FILE."
  fi
  echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}
IGNORE_FILE="$(resolve_list "$IGNORE_FILE" "$DEFAULT_IGNORE" --ignore)" || exit 2
ALLOW_FILE="$(resolve_list "$ALLOW_FILE" "$DEFAULT_ALLOW" --allow)" || exit 2

# macOS ships an old rsync (2.6.9 / openrsync) without the overall progress
# display. Need rsync >= 3.1, e.g. `brew install rsync`.
RSYNC="$(command -v rsync || true)"
RSYNC_VERSION="$("$RSYNC" --version 2>/dev/null | sed -n '1s/^rsync  *version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
if [ -z "$RSYNC_VERSION" ] || [ "${RSYNC_VERSION% *}" -lt 3 ] || { [ "${RSYNC_VERSION% *}" -eq 3 ] && [ "${RSYNC_VERSION#* }" -lt 1 ]; }; then
  echo "Need rsync 3.1 or newer for progress reporting (found: ${RSYNC:-none}). Install it with: brew install rsync" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
# The preflight runs in the background (so it can be given a deadline), where
# Ctrl-C doesn't reach it: whatever ends the script has to stop it explicitly.
PF_PID=""
stop_preflight() {
  [ -n "$PF_PID" ] || return 0
  pkill -TERM -P "$PF_PID" 2>/dev/null
  kill "$PF_PID" 2>/dev/null
  if kill -0 "$PF_PID" 2>/dev/null; then
    sleep 1
    pkill -KILL -P "$PF_PID" 2>/dev/null
    kill -KILL "$PF_PID" 2>/dev/null
  fi
  PF_PID=""
  return 0
}
trap 'stop_preflight; rm -rf "$TMP_DIR"' EXIT      # replaced by cleanup() once the copy starts
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Build the rsync rules from the two lists. rsync uses the first rule that
# matches a path, so the order is:
#   0. the target folder, if it sits inside the source (never copy into itself)
#   1. ignore list                     (always wins)
#   2. allowed files / folders         (includes)
#   3. catch-alls for keep-only areas  (- X/*: only the allowed paths under X)
#   4. every other hidden name         (- .*)
# Anything not matched is copied.
#
# A leading "/" anchors an entry to the top of the source; without one it
# matches that name at any depth. A trailing "/" means a folder and everything
# in it. An allow entry with a folder inside it (/Library/Preferences/) turns
# its parent into a keep-only area: the parent is included, the entry is
# included, and a catch-all skips everything else in that parent.
# ---------------------------------------------------------------------------
list_entries() {   # file content without comments, blank lines or edge spaces
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$1"
}

# Local rules: a .local folder next to the script may hold its own backup.ignore
# and backup.allow, for this machine only. Their entries are added to the
# lists above, so ignore still wins over allow across both: a local ignore can
# also exclude something the repository allows.
LOCAL_IGNORE=""
LOCAL_ALLOW=""
if [ "$USE_LOCAL" -eq 1 ]; then
  [ -f "$LOCAL_DIR/backup.ignore" ] && LOCAL_IGNORE="$LOCAL_DIR/backup.ignore"
  [ -f "$LOCAL_DIR/backup.allow" ] && LOCAL_ALLOW="$LOCAL_DIR/backup.allow"
fi
merge_lists() {   # the given files one after another, each ending in a newline
  local f
  for f in "$@"; do
    if [ -n "$f" ]; then cat "$f"; echo; fi
  done
}
IGNORE_LIST="$TMP_DIR/ignore.list"
ALLOW_LIST="$TMP_DIR/allow.list"
merge_lists "$IGNORE_FILE" "$LOCAL_IGNORE" > "$IGNORE_LIST"
merge_lists "$ALLOW_FILE" "$LOCAL_ALLOW" > "$ALLOW_LIST"

RULES_FILE="$TMP_DIR/backup.rules"
ALLOW_INCLUDES="$TMP_DIR/allow.includes"
ALLOW_CATCHALLS="$TMP_DIR/allow.catchalls"
: > "$RULES_FILE"
: > "$ALLOW_INCLUDES"
: > "$ALLOW_CATCHALLS"

# The target must be excluded before anything else can include it by accident.
TARGET_REL=""
case "$TARGET" in
  "${SOURCE%/}"/*)
    TARGET_REL="/${TARGET#"${SOURCE%/}"/}"
    echo "- $TARGET_REL/" >> "$RULES_FILE" ;;
esac

list_entries "$IGNORE_LIST" | sed 's/^/- /' >> "$RULES_FILE"

while IFS= read -r entry; do
  is_dir=0
  case "$entry" in */) is_dir=1; entry="${entry%/}" ;; esac
  [ -n "$entry" ] || continue
  # An entry with a folder inside it (/.local/bin) keeps only that subtree:
  # include its parent folders, and skip whatever else is in them afterwards.
  case "${entry#/}" in
    */*)
      case "$entry" in
        /*) ;;
        *) echo "Warning: skipping '$entry' in $ALLOW_FILE: paths with a folder inside need a leading /" >&2
           continue ;;
      esac
      ancestor=""
      rest="${entry#/}"
      while [ "${rest#*/}" != "$rest" ]; do
        ancestor="$ancestor/${rest%%/*}"
        rest="${rest#*/}"
        echo "+ $ancestor/" >> "$ALLOW_INCLUDES"
        echo "- $ancestor/*" >> "$ALLOW_CATCHALLS"
      done ;;
  esac
  if [ "$is_dir" -eq 1 ]; then
    echo "+ $entry/***" >> "$ALLOW_INCLUDES"
  else
    echo "+ $entry" >> "$ALLOW_INCLUDES"
  fi
done < <(list_entries "$ALLOW_LIST")

cat "$ALLOW_INCLUDES" "$ALLOW_CATCHALLS" >> "$RULES_FILE"
echo "- .*" >> "$RULES_FILE"

if [ "$PRINT_RULES" -eq 1 ]; then
  cat "$RULES_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight: walk the source once with the safety limits, and stop the run if
# one of them is crossed. The walk prunes the same folders the rules above
# exclude, so skipped trees (node_modules, caches, ~/Library/Caches, unknown
# hidden folders) cost nothing and can't trip a limit.
#
# It must never prune something rsync would still enter, or the limits would
# stop guaranteeing anything: whatever rsync can traverse has to be counted
# here. Where the two can't be matched exactly this errs towards counting too
# much, never too little. tests/run.sh checks that the count is at least the
# number of entries rsync says it would copy.
# ---------------------------------------------------------------------------
SRC_BASE="${SOURCE%/}"      # empty when the source is "/"

# find's -path takes shell wildcards and -regex takes extended regular
# expressions; these make a literal path safe to put in either.
fnmatch_escape() { printf '%s' "$1" | sed -e 's/[][*?\\]/\\&/g'; }
ere_escape()     { printf '%s' "$1" | sed -e 's/[][*.+?(){}|^$\\]/\\&/g'; }   # not "[.": BSD sed reads it as a collating symbol
# An rsync wildcard as a regular expression. In rsync "*" and "?" never match a
# "/" (only "**" does), but in find's -path they do, which would prune deeper
# folders that rsync still copies. Character classes ("[a-z]") stay literal:
# they prune less, never more.
glob_to_ere() {
  printf '%s' "$1" | awk '{
    out = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") { out = out ".*"; i++ } else out = out "[^/]*"
      } else if (c == "?") out = out "[^/]"
      else if (index("\\.+(){}|^$[]", c) > 0) out = out "\\" c
      else out = out c
    }
    print out
  }'
}
SRC_G="$(fnmatch_escape "$SRC_BASE")"
SRC_E="$(ere_escape "$SRC_BASE")"

PRUNE=()
add_prune() {
  if [ "${#PRUNE[@]}" -gt 0 ]; then PRUNE+=( -o ); fi
  PRUNE+=( '(' "$@" ')' )
}

[ -n "$TARGET_REL" ] && add_prune -path "$(fnmatch_escape "$SRC_BASE$TARGET_REL")"

# 1. everything the ignore list excludes
while IFS= read -r pat; do
  dir_only=0
  case "$pat" in */) dir_only=1; pat="${pat%/}" ;; esac
  [ -n "$pat" ] || continue
  wild=0
  case "$pat" in *[\*\?\[]*) wild=1 ;; esac
  case "$pat" in
    */*)
      if [ "$wild" -eq 1 ]; then
        ere="$(glob_to_ere "$pat")"
        case "$pat" in
          /*) pexpr=( -regex "^$SRC_E$ere\$" ) ;;   # anchored to the top of the source
          *)  pexpr=( -regex ".*/$ere\$" ) ;;       # a path fragment, at any depth
        esac
      else
        case "$pat" in
          /*) pexpr=( -path "$SRC_G$pat" ) ;;
          *)  pexpr=( -path "*/$pat" ) ;;
        esac
      fi ;;
    *) pexpr=( -name "$pat" ) ;;                    # a name, at any depth
  esac
  [ "$dir_only" -eq 1 ] && pexpr+=( -type d )
  add_prune "${pexpr[@]}"
done < <(list_entries "$IGNORE_LIST")

# 2. hidden names the allow list doesn't mention (the "- .*" rule). Two things
#    keep a hidden name from being pruned:
#    - it is (or starts) an allow entry: only the first path segment of an
#      entry counts here; what to keep inside a folder that is only partly
#      allowed is decided by the keep-only pruning below.
#    - it sits inside a folder that an allow entry keeps whole (".git/",
#      "/.ssh/"). rsync includes everything in there, hidden names too, so
#      the walk has to count them as well.
HIDDEN=( -name '.*' )
while IFS= read -r name; do
  [ -n "$name" ] && HIDDEN+=( ! -name "$name" )
done < <(list_entries "$ALLOW_LIST" | sed -e 's|^/||' -e 's|/.*$||' | grep '^\.' | sort -u)
while IFS= read -r entry; do
  case "$entry" in */) entry="${entry%/}" ;; *) continue ;; esac
  case "$entry" in
    /*)  HIDDEN+=( ! -path "$SRC_G$entry/*" ) ;;
    */*) ;;                                         # skipped with a warning above
    *)   HIDDEN+=( ! -path "*/$entry/*" ) ;;
  esac
done < <(list_entries "$ALLOW_LIST")
add_prune "${HIDDEN[@]}"

# 3. keep-only areas: in a folder that only exists to hold an allowed subtree,
#    skip every child that isn't on the way to one.
sed -e 's/^- //' -e 's|/\*$||' "$ALLOW_CATCHALLS" | sort -u > "$TMP_DIR/keeponly"
while IFS= read -r base; do
  [ -n "$base" ] || continue
  kexpr=( -path "$SRC_G$base/*" )
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    kexpr+=( ! -path "$SRC_G$base/$child" ! -path "$SRC_G$base/$child/*" )
  done < <(awk -v base="$base" '
      { line = $0; sub(/^\+ /, "", line) }
      index(line, base "/") == 1 {
        rest = substr(line, length(base) + 2)
        sub(/\/\*\*\*$/, "", rest); sub(/\/.*$/, "", rest)
        if (rest != "") print rest
      }' "$ALLOW_INCLUDES" | sort -u)
  add_prune "${kexpr[@]}"
done < "$TMP_DIR/keeponly"

echo "Source:      ${SOURCE%/}/"
echo "Destination: $TARGET/"
if [ -n "$LOCAL_IGNORE$LOCAL_ALLOW" ]; then
  echo "Local rules: ${LOCAL_IGNORE:+ignore }${LOCAL_ALLOW:+allow }from $LOCAL_DIR (--no-local to skip)"
fi
[ "$DRY_RUN" -eq 1 ] && echo "Dry run: nothing will be copied."
echo "Checking safety limits (depth $MAX_DEPTH, $MAX_ENTRIES_PER_DIRECTORY per folder, $MAX_TOTAL_ENTRIES in total, $MAX_PREFLIGHT_SECONDS s)..."

# find walks one folder at a time and never follows symlinks; -x keeps it on
# one volume, like rsync's -x. awk counts while the paths stream past and stops
# the moment a limit is crossed, which ends the walk too (find gets SIGPIPE).
# Note: a file name containing a newline is counted as two entries. That can
# only make the count too high, never too low.
PREFLIGHT="$TMP_DIR/preflight.out"
PF_STATUS="$TMP_DIR/preflight.status"     # find's and awk's exit status, written when done
PF_LAST="$TMP_DIR/preflight.last"         # a path the walk got to, for the deadline message
# The whole alternation needs its own parentheses: -o binds looser than the
# implicit -a, so "e1 -o e2 -prune" would only prune what e2 matched.
FIND_EXPR=()
if [ "${#PRUNE[@]}" -gt 0 ]; then FIND_EXPR=( '(' "${PRUNE[@]}" ')' -prune -o ); fi
FIND_EXPR+=( -print )
run_preflight() {
  find -E -x "$SOURCE" -mindepth 1 -maxdepth "$((MAX_DEPTH + 1))" \
    "${FIND_EXPR[@]}" 2> "$TMP_DIR/find.err" |
  awk -v src="$SRC_BASE" -v lastfile="$PF_LAST" \
      -v maxd="$MAX_DEPTH" -v maxe="$MAX_ENTRIES_PER_DIRECTORY" -v maxt="$MAX_TOTAL_ENTRIES" '
    function fail(what, limit, where) {
      printf("\nError: %s (%s)\n  at: %s\n", what, limit, where) > "/dev/stderr"
      failed = 1
      exit 3
    }
    BEGIN { srclen = length(src) }
    {
      total++
      rel = substr($0, srclen + 2)
      depth = split(rel, seg, "/")
      if (depth > maxd)
        fail("folder depth limit exceeded", "MAX_DEPTH=" maxd, $0)
      if (total > maxt)
        fail("too many entries in this backup", "MAX_TOTAL_ENTRIES=" maxt, $0)
      parent = substr($0, 1, length($0) - length(seg[depth]) - 1)
      count = ++entries[parent]
      if (count > maxe)
        fail("too many entries in one folder", "MAX_ENTRIES_PER_DIRECTORY=" maxe, parent)
      if (depth > deepest) deepest = depth
      if (count > widest) { widest = count; widest_dir = parent }
      if (total % 1000 == 0) { print $0 > lastfile; close(lastfile) }
    }
    END {
      if (failed) exit 3
      printf("%d %d %d %s\n", total, deepest, widest, widest_dir)
    }
  ' > "$PREFLIGHT"
  PF_ST=("${PIPESTATUS[@]}")               # find's status, then awk's
  echo "${PF_ST[0]} ${PF_ST[1]}" > "$PF_STATUS"
}

# In the background, so a walk that hangs can be given up on: the loop below
# only waits for it until the deadline. (It polls for the status file rather
# than trusting kill -0 alone, which also succeeds for a finished child that
# hasn't been reaped yet.)
run_preflight &
PF_PID=$!
PF_START=$SECONDS
PF_TIMED_OUT=0
while [ ! -e "$PF_STATUS" ] && kill -0 "$PF_PID" 2>/dev/null; do
  if [ $((SECONDS - PF_START)) -ge "$MAX_PREFLIGHT_SECONDS" ]; then PF_TIMED_OUT=1; break; fi
  sleep 0.5
done

if [ "$PF_TIMED_OUT" -eq 1 ]; then
  stop_preflight
  {
    echo
    echo "Error: the safety scan did not finish within MAX_PREFLIGHT_SECONDS=$MAX_PREFLIGHT_SECONDS seconds"
    if [ -s "$PF_LAST" ]; then echo "  last path it reported: $(cat "$PF_LAST")"
    else echo "  it stalled before reaching its first 1000 entries"; fi
    echo "Nothing was copied. A scan that stalls usually means a folder on unhealthy storage or a"
    echo "stuck network or FUSE mount. Exclude that folder in $IGNORE_FILE, or raise"
    echo "MAX_PREFLIGHT_SECONDS for one run."
  } >&2
  exit 1
fi
wait "$PF_PID" 2>/dev/null
PF_PID=""
FIND_STATUS=1; PREFLIGHT_STATUS=1
[ -f "$PF_STATUS" ] && read -r FIND_STATUS PREFLIGHT_STATUS < "$PF_STATUS"

if [ "$PREFLIGHT_STATUS" -ne 0 ]; then
  echo "Nothing was copied. Raise the limit for one run if this folder is fine, e.g." >&2
  echo "  MAX_DEPTH=$((MAX_DEPTH * 2)) MAX_ENTRIES_PER_DIRECTORY=$((MAX_ENTRIES_PER_DIRECTORY * 2)) MAX_TOTAL_ENTRIES=$((MAX_TOTAL_ENTRIES * 2)) ./backup.sh ..." >&2
  echo "or exclude the folder in $IGNORE_FILE." >&2
  exit 1
fi
# awk read everything, so find has finished by itself; its status counts too.
# Otherwise a find that failed right away (a bad expression, say) prints
# nothing, and awk would report a clean walk of 0 entries. find exits 1 for any
# error, including folders it may not enter, which is normal without Full Disk
# Access and which rsync will run into as well: those alone are a note, not a
# failure.
P_UNREADABLE=0
if [ "$FIND_STATUS" -ne 0 ]; then
  if [ "$FIND_STATUS" -eq 1 ] && [ -s "$TMP_DIR/find.err" ] &&
     ! grep -qv -E ': (Permission denied|Operation not permitted|No such file or directory)$' "$TMP_DIR/find.err"; then
    P_UNREADABLE="$(wc -l < "$TMP_DIR/find.err" | tr -d ' ')"
  else
    {
      echo
      echo "Error: the safety scan failed (find exited with status $FIND_STATUS)"
      head -n 5 "$TMP_DIR/find.err" | sed 's/^/  /'
      echo "Nothing was copied."
    } >&2
    exit 1
  fi
fi
read -r P_TOTAL P_DEPTH P_WIDEST P_WIDEST_DIR < "$PREFLIGHT"
echo "Preflight: ${P_TOTAL:-0} entries to consider, deepest ${P_DEPTH:-0} levels, largest folder ${P_WIDEST:-0} entries${P_WIDEST_DIR:+ ($P_WIDEST_DIR)}."
[ "$P_UNREADABLE" -eq 0 ] || echo "Note: $P_UNREADABLE paths could not be inspected during the check (no permission, or gone); what is in them is not counted."

# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  mkdir -p "$LOG_DIR"
else
  mkdir -p "$LOG_DIR" "$TARGET" || { echo "Could not create target folder: $TARGET" >&2; exit 1; }
fi
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
[ "$DRY_RUN" -eq 1 ] && STAMP="${STAMP}_dry-run"
# One folder per run. It holds the two log files, plus errors.txt when rsync
# reported unreadable files and files.txt after a dry run.
RUN_DIR="$LOG_DIR/$STAMP"
mkdir -p "$RUN_DIR" || { echo "Could not create log folder: $RUN_DIR" >&2; exit 1; }
CSV="$RUN_DIR/extensions.csv"
PROGRESS="$RUN_DIR/progress.log"
ERRORS="$RUN_DIR/errors.txt"
FILES="$RUN_DIR/files.txt"
CSV_TMP="$RUN_DIR/.extensions.csv.tmp"
CSV_INTERVAL=10   # seconds between live updates of the logs while copying

RSYNC_LOG="$TMP_DIR/rsync.log"
RSYNC_ERR="$TMP_DIR/rsync.err"
PROGRESS_OFFSET="$TMP_DIR/progress.offset"   # lines of RSYNC_LOG already handled
PROGRESS_LAST="$TMP_DIR/progress.last"         # kind of the last transferred file handled
echo 0 > "$PROGRESS_OFFSET"
: > "$PROGRESS_LAST"
: > "$PROGRESS"

# The kind of file a path is, for both logs (awk function, prepended to their
# programs):
#   photo.PNG -> *.png    .zshrc -> .zshrc    Makefile -> (none)
# Only the file name counts. A dotfile is identified by its whole name, unless
# it also has an extension (.env.local -> *.local).
AWK_KIND='
function kind_of(name,   hidden, rest, dot, i) {
  hidden = (substr(name, 1, 1) == ".")
  rest = hidden ? substr(name, 2) : name
  dot = 0
  for (i = length(rest); i > 0; i--) if (substr(rest, i, 1) == ".") { dot = i; break }
  if (dot > 0 && dot < length(rest)) return "*." tolower(substr(rest, dot + 1))
  if (hidden) return name
  return "(none)"
}'

# Turn rsync's log of transferred files into one CSV line of unique kinds.
# The CSV is built in a temp file and renamed over the real one, so anyone
# opening it mid-run sees the previous or the new version, never a half-written
# one.
write_csv() {
  [ -f "$RSYNC_LOG" ] || : > "$RSYNC_LOG"
  awk "$AWK_KIND"'
    match($0, /@@ >f[^ ]+ /) {
      path = substr($0, RSTART + RLENGTH)
      n = split(path, parts, "/")
      out = kind_of(parts[n])
      if (out ~ /[,"]/) { gsub(/"/, "\"\"", out); out = "\"" out "\"" }
      print out
    }
  ' "$RSYNC_LOG" | sort -u | paste -sd, - > "$CSV_TMP" && mv -f "$CSV_TMP" "$CSV"
}

# Add the first file whenever the transferred file kind changes to progress.log,
# as "<unix time>: <full path>". A kind is an extension, a hidden file name, or
# "(none)" for extensionless files. If the transfer goes *.txt -> *.jpg -> *.txt,
# all three transitions are recorded. Unlike the CSV this only looks at the lines
# rsync wrote since the last call, so it stays cheap on a log with millions of
# lines. The time is the one rsync logged for that file, which every line starts
# with as "YYYY/MM/DD HH:MM:SS" (a dry run asks for it with %t). Only one process
# may call this at a time; see live_update and cleanup.
update_progress() {
  [ -f "$RSYNC_LOG" ] || return 0
  local offset total
  offset="$(cat "$PROGRESS_OFFSET")"
  total="$(wc -l < "$RSYNC_LOG" | tr -d ' ')"     # complete lines only
  [ "$total" -gt "$offset" ] || return 0
  tail -n +"$((offset + 1))" "$RSYNC_LOG" | head -n "$((total - offset))" |
  awk -v src="${SOURCE%/}" -v lastfile="$PROGRESS_LAST" -v outfile="$PROGRESS" "$AWK_KIND"'
    BEGIN {
      last = ""
      if ((getline line < lastfile) > 0) last = line
      close(lastfile)
    }
    match($0, /@@ >f[^ ]+ /) {
      path = substr($0, RSTART + RLENGTH)
      n = split(path, parts, "/")
      kind = kind_of(parts[n])
      if (kind == last) next
      last = kind
      cmd = "date -j -f \"%Y/%m/%d %H:%M:%S\" \"" substr($0, 1, 19) "\" +%s"
      stamp = ""
      cmd | getline stamp
      close(cmd)
      if (stamp !~ /^[0-9]+$/) { "date +%s" | getline stamp; close("date +%s") }
      entries[++count] = stamp ": " src "/" path
    }
    END {
      for (i = 1; i <= count; i++) print entries[i] >> outfile
      print last > lastfile
      close(lastfile)
    }
  ' && echo "$total" > "$PROGRESS_OFFSET"
}

# A dry run is the way to audit the lists, so it also writes down every path
# rsync would have copied, with rsync's own itemize code in front of it.
write_files_list() {
  [ "$DRY_RUN" -eq 1 ] || return 0
  [ -f "$RSYNC_LOG" ] || return 0
  awk 'match($0, /@@ /) { print substr($0, RSTART + 3) }' "$RSYNC_LOG" > "$FILES"
}

# Refresh both logs every few seconds while rsync runs. Stops by itself if the
# main script is gone. On TERM it finishes the update it is in the middle of
# and then stops, so cleanup() can safely take over update_progress: killing
# it half-way would leave progress.log and its bookkeeping out of step.
MAIN_PID=$$
live_update() {
  local stop=0 nap=""
  trap 'stop=1; [ -n "$nap" ] && kill "$nap" 2>/dev/null' TERM
  while [ "$stop" -eq 0 ] && kill -0 "$MAIN_PID" 2>/dev/null; do
    sleep "$CSV_INTERVAL" & nap=$!
    wait "$nap" 2>/dev/null
    nap=""
    [ "$stop" -eq 0 ] || break
    write_csv
    update_progress
  done
}
LIVE_PID=""

FINISHED=0
STATUS_NOTE=""       # last thing cleanup() prints, so it is what the user sees at the end
cleanup() {
  # Runs on normal exit and on Ctrl-C, so an interrupted run still gets its logs.
  if [ -n "$LIVE_PID" ]; then
    kill "$LIVE_PID" 2>/dev/null
    wait "$LIVE_PID" 2>/dev/null
  fi
  write_csv
  update_progress
  write_files_list
  rm -f "$CSV_TMP"
  # After Ctrl-C, rsync's own "received SIGINT" complaints aren't worth keeping.
  if [ "$FINISHED" -eq 1 ] && [ -s "$RSYNC_ERR" ]; then
    cp "$RSYNC_ERR" "$ERRORS"
    echo
    echo "$(wc -l < "$RSYNC_ERR" | tr -d ' ') warning/error lines from rsync, first few:"
    head -n 10 "$RSYNC_ERR"
    echo "Full list: $ERRORS"
  fi
  [ "$FINISHED" -eq 1 ] || echo "Interrupted. Run the same command again to continue."
  echo "Extensions:  $CSV"
  echo "Progress:    $PROGRESS"
  [ "$DRY_RUN" -eq 1 ] && [ -f "$FILES" ] && echo "Files:       $FILES"
  [ -z "$STATUS_NOTE" ] || echo "$STATUS_NOTE" >&2
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Scanning files (no progress shown, can take a few minutes)..."
else
  echo "Scanning files first (no progress shown yet, can take a few minutes), then copying..."
fi

write_csv               # an (empty) valid CSV exists from the start
live_update &
LIVE_PID=$!

# -a        keep permissions, times and symlinks
# -x        don't cross into other volumes mounted below ~
# --no-inc-recursive: scan everything first so the percentage is accurate
# --partial-dir  keep half-copied files so a re-run can resume them, but in a
#           hidden .rsync-partial folder inside the target folder, not under
#           their real name: a plain --partial would leave a truncated file
#           that looks like a finished one until the next run completes it
# --info=progress2: one line with overall percent, speed and elapsed time
#
# A real run reports what it copied through --log-file. A dry run cannot:
# rsync only logs a transfer that really happened, so the log would list the
# folders and none of the files. There the itemized output on stdout is the
# only complete source, so it is collected into the same file instead of the
# progress display, which has nothing to show in a dry run anyway. %t puts the
# same timestamp in front of each line that --log-file adds by itself.
MODE_ARGS=(--dry-run --out-format='%t @@ %i %n')
if [ "$DRY_RUN" -eq 0 ]; then
  MODE_ARGS=(--info=progress2,name0,stats1
             --log-file="$RSYNC_LOG" --log-file-format='@@ %i %n')
fi
run_rsync() {
  "$RSYNC" -ahx \
    --no-inc-recursive \
    --partial-dir=.rsync-partial \
    "${MODE_ARGS[@]}" \
    --filter=". $RULES_FILE" \
    "${SOURCE%/}/" "$TARGET/"
}
if [ "$DRY_RUN" -eq 1 ]; then
  run_rsync > "$RSYNC_LOG" 2> "$RSYNC_ERR"
else
  run_rsync 2> "$RSYNC_ERR"
fi
STATUS=$?

FINISHED=1
# 24 = files vanished while copying: normal for a live home folder, and the
#      backup holds everything that was still there, so it is not a failure.
# 23 = some files couldn't be copied (unreadable, permission denied, ...). The
#      backup is incomplete, so the exit status says so. Callers and scripts
#      that treat 0 as "backed up" must not be told that it was.
case "$STATUS" in
  0)  exit 0 ;;
  24) STATUS_NOTE="Some files vanished while copying (rsync exit 24). Normal for a live folder."
      exit 0 ;;
  23) STATUS_NOTE="INCOMPLETE: rsync could not copy some files (exit 23). See $ERRORS. Exiting with status 23."
      exit 23 ;;
  *)  echo "rsync failed with exit code $STATUS" >&2; exit "$STATUS" ;;
esac
