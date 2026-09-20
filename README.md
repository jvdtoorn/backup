# backup

A Bash script for backing up a macOS home directory with rsync.

- Regular files and folders are copied unless `backup.ignore` excludes them, except inside keep-only areas.
- Hidden files and folders are skipped unless `backup.allow` includes them.
- `backup.ignore` takes precedence over `backup.allow`.

The script also supports dry runs, traversal limits, resumable partial transfers, and per-run logs.

## Requirements

- macOS
- The Bash version included with macOS
- rsync 3.1 or newer

Install a newer rsync with:

```sh
brew install rsync
```

Protected locations such as Desktop and Documents may require Full Disk Access for the terminal running the script.

## Usage

```sh
./backup.sh ~ "/Volumes/Backup Disk/home"
./backup.sh -n ~ "/Volumes/Backup Disk/home"
./backup.sh --print-rules ~ /tmp/x
```

Running the same command again updates an existing backup. Files removed from the source are not deleted from the target.

Symlinks are copied as symlinks, mounted filesystems below the source are not traversed, and a target inside the source is excluded automatically.

| Option | Description |
| --- | --- |
| `-n`, `--dry-run` | Copy nothing and write the logs for the files that would be copied. |
| `-i`, `--ignore FILE` | Use a different ignore list. |
| `-a`, `--allow FILE` | Use a different allow list. |
| `--print-rules` | Print the generated rsync filter rules and exit. |
| `-h`, `--help` | Show command-line help. |

## Filters

Both filter files contain one entry per line. Lines beginning with `#` are comments.

`backup.ignore` contains paths and patterns that should not be copied:

```text
*.log
node_modules/
/Downloads/
```

`backup.allow` lists hidden files and directories that should be copied:

```text
.gitignore
/.zshrc
.git/
/.local/bin/
```

A nested anchored allow entry such as `/.local/bin/` creates a keep-only area: the parent is traversed only far enough to retain the listed subtree. `~/Library` uses this mechanism to keep selected data without copying the entire directory.

## Logs

Each run creates `logs/<date>_<time>/`.

- `extensions.csv` lists file types transferred during the run.
- `progress.log` records the first transferred file seen for each file type.
- `files.txt` is created during a dry run and lists what rsync would copy.
- `errors.txt` is created when rsync reports copy errors.

Use a dry run to review the effective backup before copying data:

```sh
./backup.sh -n ~ "/Volumes/Backup Disk/home"
```

## Safety limits

Before copying, the source is scanned once.

| Variable | Default |
| --- | ---: |
| `MAX_DEPTH` | 64 |
| `MAX_ENTRIES_PER_DIRECTORY` | 100000 |
| `MAX_TOTAL_ENTRIES` | 5000000 |
| `MAX_PREFLIGHT_SECONDS` | 3600 |

If a limit is exceeded, the run stops before copying starts. Limits can be overridden for a single run:

```sh
MAX_TOTAL_ENTRIES=8000000 ./backup.sh ...
```

## Sensitive data

The allow list includes locations that may contain credentials or other sensitive data, including SSH and GPG keys, `.env` files, cloud credentials, keychains, and shell history.

Protect the backup destination accordingly.

## Tests

```sh
tests/run.sh
```

For the slower traversal test:

```sh
tests/run.sh --slow
```

## Contributing

This repository is open to contributions. If you find a bug, an edge case, or a way to improve the robustness or overall quality of the backup script, feel free to create a merge request. Improvements are welcome.

## License

See [LICENSE](LICENSE).
