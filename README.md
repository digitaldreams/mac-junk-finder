# JunkFinder

A read-only macOS command line tool that scans your home folder and lists disk space you can probably reclaim. It sorts findings into **Junk** (rebuilds itself) and **Review** (large, may be the only copy of something), with a reason next to each.

## List-only promise

JunkFinder never deletes, moves or modifies anything. It does not read file contents and does not follow symlinks. You decide what to do with the list.

## Run

```sh
swift run -c release junk
```

A full scan of a large home folder takes minutes. Release mode is somewhat faster than debug (about 2.5 min vs 3 min on the test Mac).

Tests: `./test.sh` (not `swift test`). The script works around Swift Testing on Command Line Tools without full Xcode. Extra arguments pass through, e.g. `./test.sh --filter ScannerTests`.

## Full Disk Access

Two kinds of area are left out, and both make totals a lower bound:

- **Built-in excluded areas** are never scanned and are not listed in the output (see the list below). This includes `.Trash` and `Library/Mail`: in v1 they are always excluded, and Full Disk Access (FDA) changes nothing for them.
- **Unreadable areas** are folders macOS refuses to open. They are listed on the "Skipped" line as "protected by macOS privacy" (a real run showed 31, for example `Library/Assistant/SiriVocabulary` and `Library/Daemon Containers`). Without FDA no prompt appears, they are just skipped.

FDA only matters for the second kind. To include those folders:

1. System Settings > Privacy & Security > Full Disk Access, add your terminal app.
2. Quit and reopen the terminal.
3. Run `junk`.
4. Revoke the permission afterwards.

## What is skipped, and why (built-in excluded areas)

- iCloud and cloud storage (`Library/Mobile Documents`, `Library/CloudStorage`): deletions sync and enumeration wakes providers.
- `.Trash`, `Library/Mail`, `Library/Messages`, `Library/Safari`, `Library/Cookies`, `Library/Calendars`: privacy-protected user data.
- `Library/Containers`, `Library/Group Containers`: other apps' data.
- `Library/Application Support` as a whole: app data you may expect to see here is not scanned.
- `.cache`, `.config`, `.local` as wholes.
- Credentials: `Library/Keychains`, `.ssh`, `.gnupg`, `.aws`.
- `Pictures` and `Music` (Photos and Music libraries).
- Toolchains: `.cargo/bin`, `.rustup`, `.nvm`, `.sbt/boot`, `.stack/programs`, `.pyenv/versions`, `go/bin`.
- `Desktop` and `Documents`: no rule needs them and they can trigger permission prompts.
- Other volumes and mount points, including inside a matched folder's contents (listed on the Skipped line, e.g. `~/OrbStack`).

The report footer ends with a line naming the areas not scanned by design: Trash, Mail, cloud folders, app containers, Application Support, Desktop, Documents, Pictures, Music.

Sizes are allocated bytes, hard links count once, and "reclaimable" may overstate what you free (APFS clones, snapshots).

## v1 limits

- Every `~/Library/Caches/<child>` is flagged Junk (C1) unless it is on the deny list or the Review list (C1r).
- Old installers are matched only in `~/Downloads` and one subfolder level below it. `.dmg` and `.iso` files are Review (may be an encrypted disk image); `.pkg`, `.mpkg`, `.xip` are Junk.
- Rules: caches, logs, dev caches, `target`/`node_modules`-style project folders, old installers, big stale files.
- Project folders (`target`, `node_modules`) are always Review; the staleness check that would make them Junk is not built.
- `node_modules` and `.build` are not matched under hidden top-level folders (`~/.npm/_npx`, editor extensions in `~/.windsurf` etc.): those are tool internals, not projects.
- A folder's age is the newest modification time of any file inside it. Empty matched folders are not listed.
- Maven `target` (with `pom.xml`) is not matched.
- Big files (B1) need to be 500 MB or more and not modified in over 180 days.
- No owner cleanup commands (`brew cleanup`, ...) are printed yet.
- No `--check-access` flag, no zip inspection, no `CACHEDIR.TAG` detection.
