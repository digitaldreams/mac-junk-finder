# How JunkFinder works

The details behind the [README](../README.md): every rule, every safety check, and what is never scanned.

A macOS command line tool that scans your home folder and lists disk space you can probably reclaim, and can clean the safe part on request. It sorts findings into **Junk** (rebuilds itself) and **Review** (large, may be the only copy of something), with a reason next to each.

## Reading vs cleaning

`junk` on its own is read-only: it never deletes, moves or modifies anything, does not read file contents and does not follow symlinks. Only `junk clean` removes anything, and only after you confirm.

## Clean

```sh
junk clean <caches|logs|dev|installers|node_modules|vendor>... [--yes] [--permanent]
```

- Sections: `caches` (C1, app caches), `logs` (C2), `dev` (D1 Xcode DerivedData and simulator caches, D3 package manager caches), `installers` (old `.pkg`/`.mpkg`/`.xip` in Downloads), `node_modules` (D5, next to `package.json`) and `vendor` (D6, next to `composer.json`) when no file inside changed in the last 30 days. `big` is refused: big files are Review only, delete them by hand.
- Junk tier only. Review findings (C1r, D4, D5, `.dmg`/`.iso`, B1) are never removed, even when their section is named.
- The scan runs first (2-3 min), then the selected paths with sizes and the total are printed and you are asked `[y/N]`. Anything but `y`/`yes` removes nothing. `--yes` skips the prompt; without a terminal and without `--yes` it refuses (exit 2).
- Items go to the Trash by default; space is freed when you empty it. `--permanent` deletes outright and cannot be undone.
- Running-app guard: a cache folder named after a running app's bundle id, and Xcode's build caches while Xcode runs, are skipped and listed as "skipped: app running".
- Right before each removal the item is re-checked (still exists, not a symlink, no symlink on the way, still under `~` on the same volume). A failed check skips the item. One failure does not stop the rest. Exit 0 if nothing failed, 1 otherwise, 2 for bad arguments.

## Run and test

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
- Rules: caches, logs, dev caches, `target`/`node_modules`/`vendor` project folders, old installers, big stale files.
- `node_modules` and Composer `vendor` are Junk when no file inside changed in over 30 days (every install rewrites a lock file inside) and the project has a lock file (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock(b)`, `composer.lock`), Review otherwise. Edits to the project's own code don't count. `target` and `.build` are always Review.
- `node_modules`, `vendor` and `.build` are not matched under hidden top-level folders (`~/.npm/_npx`, editor extensions in `~/.windsurf` etc.): those are tool internals, not projects.
- A folder's age is the newest modification time of any file inside it. Empty matched folders are not listed.
- Maven `target` (with `pom.xml`) is not matched.
- Big files (B1) need to be 500 MB or more and not modified in over 180 days.
- No owner cleanup commands (`brew cleanup`, ...) are printed yet.
- No `--check-access` flag, no zip inspection, no `CACHEDIR.TAG` detection.
