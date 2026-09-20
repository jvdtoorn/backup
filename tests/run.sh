#!/usr/bin/env bash
#
# Tests for backup.sh: what the filter lists keep and skip, and whether the
# traversal limits stop a pathological tree.
#
# Everything happens in a temp folder with a fake home; the real home is never
# touched. backup.sh is reached through a symlink so its logs/ folder lands in
# the temp folder too, and the repo's logs/ stays clean.
#
# Usage: tests/run.sh [--slow]
#   --slow  also build a folder with 100,000 real entries (takes a minute).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOW=0
[ "${1:-}" = "--slow" ] && SLOW=1

TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
ln -s "$REPO/backup.sh" "$TMP/bin/backup.sh"
BACKUP="$TMP/bin/backup.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

# Run backup.sh on a fake home. $1 = fake home, $2 = target, rest = options.
run_backup() {
  local home="$1" target="$2"; shift 2
  HOME="$home" "$BACKUP" ${1+"$@"} -i "$REPO/backup.ignore" -a "$REPO/backup.allow" \
    '~' "$target" > "$TMP/out.txt" 2> "$TMP/err.txt"
}

# Run backup.sh with explicit arguments (source and target as given).
run_paths() { "$BACKUP" -i "$REPO/backup.ignore" -a "$REPO/backup.allow" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt"; }

# ===========================================================================
echo "== what is copied =="
# ===========================================================================
H="$TMP/home"
T="$TMP/target"
mkdir -p "$H"
HP="$(cd "$H" && pwd -P)"      # backup.sh reports real paths; on macOS /var is /private/var

mk() { mkdir -p "$H/$(dirname "$1")"; printf 'x' > "$H/$1"; }

# regular files, blacklist, lockfiles, databases
mk notes.txt
mk Documents/report.md
mk Documents/scratch.tmp
mk app.log
mk data.db
mk proj/yarn.lock
mk proj/Cargo.lock
mk proj/Gemfile.lock
mk proj/poetry.lock
mk proj/package-lock.json
mk proj/more.txt
# numbered dotfiles: only /.42 survives
mk .42
mk .5
mk .123
mk sub/.42
# unknown hidden state is dropped
mk .unknownrc
mk .unknowndir/state
# ssh
mk .ssh/id_ed25519
mk .ssh/config
mk .ssh/known_hosts
mk .ssh/known_hosts.old
mk .ssh/agent/listener
# project dotfiles and folders
mk proj/.gitignore
mk proj/src/.gitignore
mk proj/.env
mk proj/.env.local
mk proj/.github/workflows/ci.yml
mk proj/.vscode/settings.json
mk proj/.idea/workspace.xml
mk proj/.devcontainer/devcontainer.json
mk proj/.cursor/rules.md
# a real repository with a local-only commit
(
  cd "$H/proj" &&
  git init -q . &&
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local only"
) > /dev/null 2>&1
# a linked worktree stores .git as a FILE
mkdir -p "$H/worktree"
printf 'gitdir: /somewhere/.git/worktrees/wt\n' > "$H/worktree/.git"
# hidden names inside a folder that is kept whole are kept too (rsync includes
# the whole subtree), and the preflight has to count them
mk .config/.hidden/state
mk .ssh/.hidden-key
mk proj/.git/.hidden-in-git
# extensions that used to be blacklisted without evidence
mk data/model.pkl
mk data/repo.bundle
mk data/book.opf
mk data/App.xcsettings
mk data/schema.types
# caches inside folders that are kept whole
mk .aws/credentials
mk .aws/cli/cache/token.json
mk .aws/sso/cache/login.json
mk .kube/config
mk .kube/cache/discovery
mk .kube/http-cache/blob
mk .terraform.d/plugin-cache/big.zip
mk .terraform.d/credentials.tfrc.json
mk .pulumi/credentials.json
mk .pulumi/plugins/resource-x/bin
# regenerable folders
mk proj/node_modules/lib/index.js
mk proj/venv/bin/python
mk proj/__pycache__/mod.pyc
mk proj/build/out.bin
mk proj/dist/bundle.js
mk Makefile
mk proj/target/debug/app
mk proj/coverage/index.html
# shell config, also deeper down (dotfiles repo case)
mk .zshrc
mk .zsh_history
mk Code/dotfiles/.zshrc
mk .DS_Store
# folders allowed at any depth, trimmed in ~
mk .vscode/extensions/big.vsix
mk .cursor/mcp.json
mk .cursor/extensions/huge.blob
# mixed tool folders: keep-only
mk .gradle/gradle.properties
mk .gradle/caches/8.5/big.bin
mk .oh-my-zsh/custom/mine.zsh
mk .oh-my-zsh/plugins/git/git.plugin.zsh
mk .local/bin/tool
mk .local/share/app/state.json
mk .local/pipx/venvs/big
# ~/Library is a keep-only area
mk "Library/Preferences/com.apple.finder.plist"
mk "Library/Fonts/Custom.ttf"
mk "Library/Caches/com.apple.Safari/cache.bin"
mk "Library/Containers/com.docker.docker/Data/vm.raw"
mk "Library/Application Support/Code/User/settings.json"
mk "Library/Application Support/Code/User/History/1/entry"
mk "Library/Application Support/Spotify/PersistentCache/big"
mk "Library/Application Support/Claude/claude_desktop_config.json"
mk "Library/Application Support/Claude/vm_bundles/huge.img"
# JetBrains: the ignore rule ".../JetBrains/*/caches/" only covers a caches
# folder one level down, since "*" does not match a "/" in rsync. One deeper
# is copied by rsync, so the preflight has to count it (find's own -path
# wildcard would match it and prune it).
mk "Library/Application Support/JetBrains/IntelliJ2025/options/ide.xml"
mk "Library/Application Support/JetBrains/IntelliJ2025/caches/index.bin"
mk "Library/Application Support/JetBrains/IntelliJ2025/plugins/foo/caches/deep.bin"

run_backup "$H" "$T"
check "exit status" "$?" "0"
# each run gets its own folder under logs/; the newest one is this run's
latest_run() { local d; d="$(ls -td "$TMP/bin/logs/"*/ | head -1)"; echo "${d%/}"; }
RUN1="$(latest_run)"

kept()    { if [ -e "$T/$1" ]; then ok; else bad "should be kept: $1"; fi; }
skipped() { if [ -e "$T/$1" ]; then bad "should be skipped: $1"; else ok; fi; }

kept notes.txt
kept Documents/report.md
skipped Documents/scratch.tmp
skipped app.log
kept data.db
kept proj/yarn.lock
kept proj/Cargo.lock
kept proj/Gemfile.lock
kept proj/poetry.lock
kept proj/package-lock.json

kept .42
skipped .5
skipped .123
skipped sub/.42
skipped .unknownrc
skipped .unknowndir

kept .config/.hidden/state
kept .ssh/.hidden-key
kept proj/.git/.hidden-in-git
kept data/model.pkl
kept data/repo.bundle
kept data/book.opf
kept data/App.xcsettings
kept data/schema.types
kept .aws/credentials
skipped .aws/cli/cache
skipped .aws/sso/cache
kept .kube/config
skipped .kube/cache
skipped .kube/http-cache
skipped .terraform.d/plugin-cache
kept .terraform.d/credentials.tfrc.json
kept .pulumi/credentials.json
skipped .pulumi/plugins

kept .ssh/id_ed25519
kept .ssh/config
skipped .ssh/known_hosts
skipped .ssh/known_hosts.old
skipped .ssh/agent

kept proj/.gitignore
kept proj/src/.gitignore
kept proj/.env
kept proj/.env.local
kept proj/.github/workflows/ci.yml
kept proj/.vscode/settings.json
kept proj/.idea/workspace.xml
kept proj/.devcontainer/devcontainer.json
kept proj/.cursor/rules.md
kept proj/.git/HEAD
kept proj/.git/refs
kept worktree/.git

skipped proj/node_modules
skipped proj/venv
skipped proj/__pycache__
skipped proj/build
skipped proj/dist
skipped proj/target
skipped proj/coverage

kept .zshrc
kept .zsh_history
kept Code/dotfiles/.zshrc
skipped .DS_Store

skipped .vscode/extensions
kept .cursor/mcp.json
skipped .cursor/extensions

kept .gradle/gradle.properties
skipped .gradle/caches
kept .oh-my-zsh/custom/mine.zsh
skipped .oh-my-zsh/plugins
kept .local/bin/tool
kept .local/share/app/state.json
skipped .local/pipx

kept "Library/Preferences/com.apple.finder.plist"
kept "Library/Fonts/Custom.ttf"
skipped "Library/Caches"
skipped "Library/Containers"
kept "Library/Application Support/Code/User/settings.json"
skipped "Library/Application Support/Code/User/History"
skipped "Library/Application Support/Spotify"
kept "Library/Application Support/Claude/claude_desktop_config.json"
skipped "Library/Application Support/Claude/vm_bundles"
kept "Library/Application Support/JetBrains/IntelliJ2025/options/ide.xml"
skipped "Library/Application Support/JetBrains/IntelliJ2025/caches"
kept "Library/Application Support/JetBrains/IntelliJ2025/plugins/foo/caches/deep.bin"

# the git repository must be usable after a restore
if git -C "$T/proj" log --oneline 2>/dev/null | grep -q "local only"; then ok
else bad "restored repository lost its local commit"; fi

# ===========================================================================
echo "== CSV and dry-run file list =="
# ===========================================================================
CSV="$RUN1/extensions.csv"
if [ -s "$CSV" ]; then
  line="$(cat "$CSV")"
  case "$line" in *'*.txt'*)  ok ;; *) bad "CSV misses *.txt: $line" ;; esac
  case "$line" in *'.zshrc'*) ok ;; *) bad "CSV misses .zshrc: $line" ;; esac
  case "$line" in *'(none)'*) ok ;; *) bad "CSV misses (none): $line" ;; esac
  case "$line" in *'*.log'*)  bad "CSV lists a skipped extension: $line" ;; *) ok ;; esac
else
  bad "no CSV written"
fi

run_backup "$H" "$TMP/target-dry" -n
RUN2="$(latest_run)"
case "$RUN2" in *_dry-run) ok ;; *) bad "dry run folder is not marked: $RUN2" ;; esac
FILES="$RUN2/files.txt"
if [ -f "$FILES" ] && grep -q "notes.txt" "$FILES"; then ok
else bad "dry run wrote no usable file list"; fi
if [ -d "$TMP/target-dry" ]; then bad "dry run created the target folder"; else ok; fi

# The safety limits only mean something if the preflight sees everything rsync
# would copy. files.txt lists every path rsync would create ("./" is the root).
counted="$(sed -n 's/^Preflight: \([0-9]*\) entries.*/\1/p' "$TMP/out.txt")"
would_copy=$(( $(wc -l < "$FILES" | tr -d ' ') - 1 ))
if [ -n "$counted" ] && [ "$counted" -ge "$would_copy" ]; then ok
else bad "preflight counted ${counted:-nothing}, but rsync would copy $would_copy entries"; fi

# ===========================================================================
echo "== run folder and progress.log =="
# ===========================================================================
# a run folder holds exactly extensions.csv and progress.log (errors.txt only
# appears when rsync reported errors, files.txt only after a dry run)
check "files in a run folder" "$(ls -A "$RUN1" | tr '\n' ' ')" "extensions.csv progress.log "
check "files in a dry-run folder" "$(ls -A "$RUN2" | tr '\n' ' ')" "extensions.csv files.txt progress.log "

check_progress() {   # <label> <run folder>
  local label="$1" prog="$2/progress.log" kinds lines now first
  [ -s "$prog" ] || { bad "$label: progress.log is empty or missing"; return; }
  # "<unix time>: <full path>", nothing else
  check "$label: line format" "$(grep -cvE '^[0-9]{10}: /' "$prog")" "0"
  # one entry per kind in the CSV, no more
  kinds="$(tr ',' '\n' < "$2/extensions.csv" | grep -c .)"
  lines="$(wc -l < "$prog" | tr -d ' ')"
  check "$label: one entry per extension" "$lines" "$kinds"
  # the full path of a real file, not a path relative to the source
  check "$label: full paths" "$(grep -c ": $HP/" "$prog")" "$lines"
  # the time is when it was copied, i.e. just now
  now="$(date +%s)"; first="$(head -1 "$prog" | cut -d: -f1)"
  if [ $((now - first)) -ge 0 ] && [ $((now - first)) -lt 120 ]; then ok
  else bad "$label: timestamp $first is not recent (now $now)"; fi
  # a kind is only logged once, however many files have it
  check "$label: *.txt once" "$(grep -c '\.txt$' "$prog")" "1"
  check "$label: .gitignore once" "$(grep -c '/\.gitignore$' "$prog")" "1"
  check "$label: .zshrc once (hidden file name)" "$(grep -c '/\.zshrc$' "$prog")" "1"
  check "$label: extensionless file logged" "$(grep -c '/Makefile$' "$prog")" "1"
  # files that were not copied never show up
  check "$label: skipped files absent" "$(grep -cE '/(app\.log|\.unknownrc|\.5)$' "$prog")" "0"
}
check_progress "real run" "$RUN1"
check_progress "dry run" "$RUN2"

# a second run into the same target has nothing new to copy: both logs are empty
sleep 1
run_backup "$H" "$T"
RUN3="$(latest_run)"
if [ "$RUN3" != "$RUN1" ]; then ok; else bad "second run reused the first run's folder"; fi
if [ ! -s "$RUN3/progress.log" ] && [ ! -s "$RUN3/extensions.csv" ]; then ok
else bad "continuation run logged files that were already copied"; fi

# ===========================================================================
echo "== traversal limits =="
# ===========================================================================
deep() { local n="$1" p="" i; for ((i = 0; i < n; i++)); do p="$p/a"; done; echo "$p"; }

# a tree at exactly the depth limit is fine
D="$TMP/deep64"; mkdir -p "$D$(deep 64)"
run_backup "$D" "$TMP/out-deep64" -n
check "depth 64 accepted" "$?" "0"

# one level more aborts, naming the path and the limit
D="$TMP/deep65"; mkdir -p "$D$(deep 65)"
run_backup "$D" "$TMP/out-deep65" -n
if [ "$?" -ne 0 ]; then ok; else bad "depth 65 was accepted"; fi
grep -q "MAX_DEPTH=64" "$TMP/err.txt" && ok || bad "error misses the limit name"
grep -q "$D/a/a/a" "$TMP/err.txt" && ok || bad "error misses the offending path"
[ -d "$TMP/out-deep65" ] && bad "aborted run still made a target" || ok

# per-folder ceiling
W="$TMP/wide"; mkdir -p "$W/many"
i=0; while [ "$i" -lt 11 ]; do : > "$W/many/f$i"; i=$((i + 1)); done
MAX_ENTRIES_PER_DIRECTORY=10 run_backup "$W" "$TMP/out-wide" -n
if [ "$?" -ne 0 ]; then ok; else bad "11 entries passed a limit of 10"; fi
grep -q "MAX_ENTRIES_PER_DIRECTORY=10" "$TMP/err.txt" && ok || bad "error misses the per-folder limit"
grep -q "$W/many" "$TMP/err.txt" && ok || bad "error misses the offending folder"
MAX_ENTRIES_PER_DIRECTORY=11 run_backup "$W" "$TMP/out-wide2" -n
check "11 entries pass a limit of 11" "$?" "0"

# global ceiling
MAX_TOTAL_ENTRIES=5 run_backup "$W" "$TMP/out-total" -n
if [ "$?" -ne 0 ]; then ok; else bad "global ceiling was not enforced"; fi
grep -q "MAX_TOTAL_ENTRIES=5" "$TMP/err.txt" && ok || bad "error misses the global limit"

# an excluded folder costs nothing: 40 files in node_modules, budget of 10
P="$TMP/pruned"; mkdir -p "$P/proj/node_modules"
i=0; while [ "$i" -lt 40 ]; do : > "$P/proj/node_modules/f$i"; i=$((i + 1)); done
: > "$P/proj/main.py"
MAX_TOTAL_ENTRIES=10 run_backup "$P" "$TMP/out-pruned" -n
check "excluded folders don't use the budget" "$?" "0"

# symlink loops are not followed
L="$TMP/loop"; mkdir -p "$L/dir"
ln -s "$L" "$L/dir/back"
ln -s "$L/dir" "$L/dir/self"
: > "$L/dir/file"
run_backup "$L" "$TMP/out-loop" -n
check "symlink loop survived" "$?" "0"


# hidden names inside a folder that is kept whole must count against the limits
X="$TMP/hiddeninside"; mkdir -p "$X/.config/.hidden"
i=0; while [ "$i" -lt 12 ]; do : > "$X/.config/.hidden/f$i"; i=$((i + 1)); done
MAX_TOTAL_ENTRIES=10 run_backup "$X" "$TMP/out-hidden" -n
if [ "$?" -ne 0 ]; then ok; else bad "hidden entries inside a kept folder were not counted"; fi
MAX_ENTRIES_PER_DIRECTORY=10 run_backup "$X" "$TMP/out-hidden2" -n
if [ "$?" -ne 0 ]; then ok; else bad "hidden folder inside a kept folder escaped the per-folder limit"; fi

# same for a folder kept by an entry that applies at any depth (".git/")
X2="$TMP/hiddeninside2"; mkdir -p "$X2/proj/.git/.hidden"
i=0; while [ "$i" -lt 12 ]; do : > "$X2/proj/.git/.hidden/f$i"; i=$((i + 1)); done
MAX_ENTRIES_PER_DIRECTORY=10 run_backup "$X2" "$TMP/out-hidden3" -n
if [ "$?" -ne 0 ]; then ok; else bad "hidden folder inside .git/ escaped the limits"; fi

# "*" in an ignore rule must not match a "/" (as in rsync): the rule
# ".../JetBrains/*/caches/" covers IntelliJ/caches, not IntelliJ/plugins/foo/caches,
# which rsync copies and the preflight therefore has to count
J="$TMP/jetbrains"; JD="$J/Library/Application Support/JetBrains/IntelliJ"
mkdir -p "$JD/plugins/foo/caches" "$JD/caches"
i=0; while [ "$i" -lt 12 ]; do : > "$JD/plugins/foo/caches/f$i"; : > "$JD/caches/g$i"; i=$((i + 1)); done
MAX_ENTRIES_PER_DIRECTORY=10 run_backup "$J" "$TMP/out-jb" -n
if [ "$?" -ne 0 ]; then ok; else bad "a caches folder rsync copies escaped the limits"; fi
grep -q "plugins/foo/caches" "$TMP/err.txt" && ok || bad "error should name plugins/foo/caches, got: $(grep 'at:' "$TMP/err.txt")"
# ... while the one the rule does cover stays pruned: 12 entries in it are fine
/bin/rm -rf "$JD/plugins"
MAX_ENTRIES_PER_DIRECTORY=10 run_backup "$J" "$TMP/out-jb2" -n
check "the ignored caches folder is still pruned" "$?" "0"

# the same for a wildcard rule that is not anchored: "a/*/cache/" matches
# p/a/x/cache but not p/a/x/y/cache
Q="$TMP/unanchored"; mkdir -p "$Q/p/a/x/cache" "$Q/p/a/x/y/cache"
i=0; while [ "$i" -lt 12 ]; do : > "$Q/p/a/x/cache/f$i"; : > "$Q/p/a/x/y/cache/f$i"; i=$((i + 1)); done
printf 'a/*/cache/\n' > "$TMP/custom.ignore"
MAX_ENTRIES_PER_DIRECTORY=10 run_paths -n -i "$TMP/custom.ignore" "$Q" "$TMP/out-q"
if [ "$?" -ne 0 ]; then ok; else bad "a folder the wildcard rule does not cover escaped the limits"; fi
grep -q "a/x/y/cache" "$TMP/err.txt" && ok || bad "error should name a/x/y/cache, got: $(grep 'at:' "$TMP/err.txt")"
/bin/rm -rf "$Q/p/a/x/y"
MAX_ENTRIES_PER_DIRECTORY=10 run_paths -n -i "$TMP/custom.ignore" "$Q" "$TMP/out-q2"
check "the folder the wildcard rule covers is pruned" "$?" "0"

MAX_PREFLIGHT_SECONDS=abc run_backup "$W" "$TMP/out-bad" -n
check "invalid limit rejected" "$?" "2"

# ===========================================================================
echo "== the safety scan can't hang the run =="
# ===========================================================================
# A find that never answers, standing in for a stuck mount. The run has to
# give up at the deadline, say so, copy nothing, and leave nothing running.
mkdir -p "$TMP/hang"
printf '#!/bin/sh\nexec sleep 37\n' > "$TMP/hang/find"; chmod +x "$TMP/hang/find"
SECONDS=0
PATH="$TMP/hang:$PATH" MAX_PREFLIGHT_SECONDS=2 run_backup "$W" "$TMP/out-hang" -n
status=$?
elapsed=$SECONDS
if [ "$status" -ne 0 ]; then ok; else bad "a hung scan was reported as success"; fi
if [ "$elapsed" -lt 15 ]; then ok; else bad "gave up after ${elapsed}s, deadline was 2s"; fi
grep -q "MAX_PREFLIGHT_SECONDS=2" "$TMP/err.txt" && ok || bad "error misses the deadline"
[ -d "$TMP/out-hang" ] && bad "target created although the scan never finished" || ok
sleep 1
if pgrep -f 'sleep 37' > /dev/null; then bad "the stuck scan is still running"; pkill -f 'sleep 37'; else ok; fi

# Ctrl-C during the scan must stop it too (it runs in the background, where
# Ctrl-C does not reach it by itself).
cat > "$TMP/ctrlc.sh" <<EOF
#!/bin/bash
set -m
PATH="$TMP/hang:\$PATH" HOME="$W" "$BACKUP" -n -i "$REPO/backup.ignore" -a "$REPO/backup.allow" '~' "$TMP/out-ctrlc" > "$TMP/ctrlc.out" 2>&1 &
pid=\$!
sleep 2
kill -INT -\$pid
wait \$pid
echo \$? > "$TMP/ctrlc.status"
EOF
chmod +x "$TMP/ctrlc.sh"; "$TMP/ctrlc.sh"; sleep 2
check "Ctrl-C during the scan exits 130" "$(cat "$TMP/ctrlc.status")" "130"
if pgrep -f 'sleep 37' > /dev/null; then bad "the scan survived Ctrl-C"; pkill -f 'sleep 37'; else ok; fi

# A find that fails must fail the scan. Without that, a broken expression makes
# find print nothing and the scan reports a clean walk of 0 entries.
mkdir -p "$TMP/badfind"
printf '#!/bin/sh\necho "find: -regex: bad expression" >&2\nexit 1\n' > "$TMP/badfind/find"; chmod +x "$TMP/badfind/find"
PATH="$TMP/badfind:$PATH" run_backup "$W" "$TMP/out-badfind" -n
check "a failing find fails the scan" "$?" "1"
grep -q "safety scan failed" "$TMP/err.txt" && ok || bad "no scan-failed message"
[ -d "$TMP/out-badfind" ] && bad "target created after a failed scan" || ok

# ... but folders find may not enter are normal (no Full Disk Access) and only
# a note; rsync runs into them as well and reports exit 23 itself
L2="$TMP/locked"; mkdir -p "$L2/closed" "$L2/open"; : > "$L2/open/a.txt"; : > "$L2/closed/b.txt"; chmod 000 "$L2/closed"
run_backup "$L2" "$TMP/out-locked"
check "unreadable folder: run goes on, rsync reports exit 23" "$?" "23"
grep -q "could not be inspected during the check" "$TMP/out.txt" && ok || bad "no note about the unreadable folder"
chmod 755 "$L2/closed"

# ===========================================================================
echo "== exit status =="
# ===========================================================================
# rsync exit 23 means some files could not be copied: the backup is incomplete,
# so it must not look like success.
U="$TMP/unreadable"; mkdir -p "$U/dir"
echo ok > "$U/readable.txt"; echo secret > "$U/dir/locked.txt"; chmod 000 "$U/dir/locked.txt"
run_backup "$U" "$TMP/out-unreadable"
check "unreadable file gives exit status 23" "$?" "23"
kept_file() { if [ -e "$1" ]; then ok; else bad "should exist: $1"; fi; }
kept_file "$TMP/out-unreadable/readable.txt"
grep -q "INCOMPLETE" "$TMP/err.txt" && ok || bad "no INCOMPLETE notice on stderr"
RUN_E="$(latest_run)"
if [ -s "$RUN_E/errors.txt" ]; then ok; else bad "errors.txt missing from $RUN_E"; fi
chmod 644 "$U/dir/locked.txt"

# ===========================================================================
echo "== source and target paths =="
# ===========================================================================
# The target lying inside the source is only caught if paths are compared as
# they really are, not as they are spelled.
C="$TMP/canon"; mkdir -p "$C"; echo data > "$C/file.txt"

# "x/../bk" is just "bk"; "x" must not be created on the way
run_paths "$C" "$C/x/../bk"; run_paths "$C" "$C/x/../bk"
[ -f "$C/bk/file.txt" ] && ok || bad "target with .. was not created where it points"
[ -e "$C/bk/bk" ] && bad "target with .. copied itself into itself" || ok
[ -e "$C/x" ] && bad "a folder was created for the .. component" || ok

# the source reached through a symlink
ln -s "$C" "$TMP/canon-link"
run_paths "$TMP/canon-link" "$C/bk2"; run_paths "$TMP/canon-link" "$C/bk2"
[ -f "$C/bk2/file.txt" ] && ok || bad "target below a symlinked source was not created"
[ -e "$C/bk2/bk2" ] && bad "target below a symlinked source copied itself" || ok

# the same folder spelled differently
run_paths "$TMP/canon-link" "$C"
check "same folder through a symlink" "$?" "2"
grep -q "same folder" "$TMP/err.txt" && ok || bad "no same-folder message"
run_paths "$C" "$C/sub/.."
check "same folder through .." "$?" "2"

# ===========================================================================
echo "== interrupted copy resumes without leaving a truncated file =="
# ===========================================================================
PD="$TMP/partial"; mkdir -p "$PD/home" "$TMP/wrap"
head -c 1500000 /dev/urandom > "$PD/home/big.bin"
printf '#!/bin/sh\nexec "%s" --bwlimit=300 "$@"\n' "$(command -v rsync)" > "$TMP/wrap/rsync"
chmod +x "$TMP/wrap/rsync"
cat > "$TMP/interrupt.sh" <<EOF
#!/bin/bash
set -m
PATH="$TMP/wrap:\$PATH" HOME="$PD/home" "$BACKUP" -i "$REPO/backup.ignore" -a "$REPO/backup.allow" '~' "$PD/out" > "$TMP/int.out" 2>&1 &
pid=\$!
sleep 3
kill -INT -\$pid
wait \$pid
echo \$? > "$TMP/int.status"
EOF
chmod +x "$TMP/interrupt.sh"; "$TMP/interrupt.sh"; sleep 1
check "interrupted run exits 130" "$(cat "$TMP/int.status")" "130"
[ -e "$PD/out/big.bin" ] && bad "a truncated file sits under its real name" || ok
if [ -s "$PD/out/.rsync-partial/big.bin" ]; then ok; else bad "no partial file in .rsync-partial"; fi
run_paths_home() { HOME="$PD/home" "$BACKUP" -i "$REPO/backup.ignore" -a "$REPO/backup.allow" '~' "$PD/out" > "$TMP/out.txt" 2> "$TMP/err.txt"; }
run_paths_home
check "rerun completes" "$?" "0"
cmp -s "$PD/home/big.bin" "$PD/out/big.bin" && ok || bad "file differs from the source after the rerun"
[ -e "$PD/out/.rsync-partial/big.bin" ] && bad "partial file left behind after completing" || ok

if [ "$SLOW" -eq 1 ]; then
  echo "== 100,000 entries in one folder (slow) =="
  B="$TMP/big"; mkdir -p "$B/lots"
  seq 1 100000 | (cd "$B/lots" && xargs -n 2000 touch)
  run_backup "$B" "$TMP/out-big" -n
  check "100,000 entries accepted" "$?" "0"
  touch "$B/lots/one-too-many"
  run_backup "$B" "$TMP/out-big2" -n
  if [ "$?" -ne 0 ]; then ok; else bad "100,001 entries were accepted"; fi
  grep -q "MAX_ENTRIES_PER_DIRECTORY=100000" "$TMP/err.txt" && ok || bad "error misses the limit"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
