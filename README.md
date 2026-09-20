# backup

A small bash script that backs up a Mac with rsync: everything you made, none of what apps and tools regenerate. The rules live in two plain text files that take a minute to read and edit.

- **Regular files and folders** are copied unless `backup.ignore` excludes them (`node_modules/`, `*.log`, ...), except inside keep-only areas (see below).
- **Hidden files and folders** (`.name`) are skipped unless `backup.allow` lists them (`.git/`, `.ssh/`, `.zshrc`, ...). Unknown hidden state is left behind instead of copied blindly.
- `backup.ignore` wins over `backup.allow`.

It also has a dry run to audit what would be copied, safety limits against runaway folder trees, and logs that show which file types you are backing up so you can tune the ignore list.

## Requirements

macOS with its stock bash, and rsync 3.1 or newer. The rsync that ships with macOS is too old: `brew install rsync`. To read Desktop, Documents and similar folders, give your terminal Full Disk Access.

## Usage

```sh
./backup.sh ~ "/Volumes/Backup Disk/home"      # copy your home folder
./backup.sh -n ~ "/Volumes/Backup Disk/home"   # dry run: copy nothing, write the logs
./backup.sh --print-rules ~ /tmp/x             # show the rsync rules built from the lists
```

The contents of the source land directly in the target, which is created if it doesn't exist. Run the same command again to continue an interrupted backup or to update an existing one; only new and changed files are copied, and nothing is ever deleted from the target. A half-copied file waits in a hidden `.rsync-partial/` folder in the target until the next run finishes it.

Symlinks are copied as symlinks, other mounted volumes are not entered, and a target inside the source is left out of the copy.

| Option | |
| --- | --- |
| `-n`, `--dry-run` | Copy nothing, only write the logs. |
| `-i`, `--ignore FILE` | Use another ignore list (default: `backup.ignore` next to the script). |
| `-a`, `--allow FILE` | Use another allow list (default: `backup.allow` next to the script). |
| `--print-rules` | Print the generated rsync rules and exit. |

## The two lists

One entry per line, `#` starts a comment line. Both files start with a sensible list for a developer's Mac; edit them to taste.

| `backup.ignore` | matches |
| --- | --- |
| `*.log` | files with this extension |
| `node_modules/` | a folder, at any depth |
| `/Downloads/` | only at the top of the source |

| `backup.allow` | keeps |
| --- | --- |
| `.gitignore` | a file or folder with this name, at any depth |
| `/.zshrc` | only directly in the source folder |
| `.git/` | a folder and everything in it |
| `/.local/bin/` | only this subtree of `.local` |

The last form makes `.local` a **keep-only area**: it is entered, the listed subtree is kept, and everything else in it is skipped. That is how `~/Library` is handled: list the few folders worth keeping and its caches and app containers stay behind. Don't put such a folder in `backup.ignore`, because an ignore rule stops rsync from looking inside it.

## Tuning the ignore list

Every run writes a folder `logs/<date>_<time>/` (dry runs end in `_dry-run`), updated every few seconds while copying:

- `extensions.csv`: one line with the file types copied in that run, e.g. `(none),*.md,*.png,.gitignore`.
- `progress.log`: the first file of each new type, as `<unix time>: <full path>`.

```
1789888127: /Users/me/Documents/notes.txt
1789888128: /Users/me/Pictures/photo.png
```

Read `extensions.csv`, add whatever is machine-generated to `backup.ignore`, and run again. Files already copied stay in the backup. A dry run also writes `files.txt`, every path it would copy, which is the quickest way to check your lists.

## Safety limits

Before copying, the source is walked once. If it looks pathological, the run stops before anything is copied and names the folder responsible; nothing is silently skipped.

| Variable | Default | Limit |
| --- | --- | --- |
| `MAX_DEPTH` | 64 | levels below the source |
| `MAX_ENTRIES_PER_DIRECTORY` | 100000 | entries in one folder |
| `MAX_TOTAL_ENTRIES` | 5000000 | entries in the whole run |
| `MAX_PREFLIGHT_SECONDS` | 3600 | time for this check, in case a mount hangs |

Raise one for a single run by putting it in front of the command: `MAX_TOTAL_ENTRIES=8000000 ./backup.sh ...`.

Exit status: `0` when everything was copied, `23` when some files could not be copied (the backup is incomplete, see `errors.txt` in the log folder), `2` for a usage error, `1` or rsync's own code for other failures.

## A note on secrets

`backup.allow` deliberately keeps files that can hold secrets, such as SSH and GPG keys, `.env` files, cloud credentials, keychains and shell history, so that a restore is complete. Treat the backup disk accordingly: encrypt it and keep it safe.

## Tests

`tests/run.sh` runs the script against a fake home folder.

## License

See [LICENSE](LICENSE).
