# JunkFinder tasks

Swift 6 CLI for macOS 15. Scans `~`, prints junk. Only `junk clean` removes anything (T8): Junk tier only, after confirmation.
Reference: `docs/research.md` (rule ids C1, D4, I1, B1... come from its rule table). Where this file differs from the research, this file wins; differences are listed under v1 deviations.

**Loop:** for each `todo` task in order: `swift-macos-dev` implements → `junk-reviewer` reviews → FAIL goes back to the implementer with the findings (max 2 fix rounds, then stop and ask the human) → PASS stages the work (`git add -A`) and marks the task `done`.

**v1 scope (trimmed from the research):** rules C1, C1r, C2, D1, D3, D4, D5, I1, B1 below. Deferred: clone ranges, zip inspection, CACHEDIR.TAG, `--check-access`/`--open-settings`, Spotlight last-used, project-staleness gates.

**v1 deviations from the research (intended, not bugs):**
- B1 threshold 500 MB (research: 1 GB), so more candidates reach Review.
- D4 matches only `target` with sibling `Cargo.toml`; Maven `pom.xml` is not matched.
- D4 and `.build` (D5) are always Review. Stale `node_modules` (D5) and Composer `vendor` (D6) are Junk (T9); the gate checks the folder's newest file, not the whole project (human's call).
- D1/D3 cover only the paths listed in T2; C2 folds in C3 (`Library/Logs/DiagnosticReports`).
- Deny list denies whole `pypoetry` and `org.R-project.R` folders (research: `virtualenvs`, `renv` subpaths), since C1 works on direct children of `Library/Caches`.
- No owner cleanup commands printed yet; each finding carries a one-line reason.
- I1 `.dmg`/`.iso` are Review, not Junk (may be a user's encrypted disk image); `.pkg`/`.mpkg`/`.xip` stay Junk. (T6)
- D5 is not matched under hidden top-level folders (`~/.npm/_npx`, editor extensions): those are tool internals, not projects. (T7)

Statuses: `todo` · `in-progress` · `review` · `done` · `blocked`

---

## T1 Scaffold the package
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

Acceptance:
- `Package.swift`: tools 6.0, macOS 15, targets `JunkCore` (library), `junk` (executable, depends on JunkCore), `JunkCoreTests` (Swift Testing). No dependencies.
- `./test.sh` (already present, Command Line Tools workaround) runs one passing smoke test.
- `swift run junk` prints a placeholder line and exits 0. (superseded by T4: runs the real scan)
- `.gitignore` ignores `.build/`.

## T2 Rule matcher (pure logic, TDD)
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

`classify(_ item: Item, now: Date) -> Match?` where `Item` holds: path relative to `~`, kind (file / dir / package), names of siblings, allocated size, modified date, date added. `Match` holds category (caches & logs / dev junk / old installers / big files), tier (junk / review), rule id, one-line reason.

Rules (first match wins, order: deny → D → C1r → C → I → B):
- **Deny (never):** `Library/Caches/{CloudKit*, com.apple.FontRegistry*, com.apple.Spotlight*, com.apple.spotlight*, com.apple.bird, com.apple.CloudDocs*, com.apple.finder, pypoetry, org.R-project.R, kitty}` → nil.
- **D1 junk:** `Library/Developer/Xcode/DerivedData`, `Library/Developer/CoreSimulator/Caches`.
- **D3 junk:** `Library/Caches/{Homebrew, Yarn, pip, CocoaPods, composer}`, `.npm/_cacache`, `.cargo/registry/cache`.
- **D4 review:** dir named `target` with sibling `Cargo.toml`. Bare `target` → nil.
- **D5 review:** `node_modules` with sibling `package.json`; `.build` with sibling `Package.swift`.
- **C1r review:** `Library/Caches/{ms-playwright*, JetBrains*, com.jetbrains.toolbox*}`; reason "large download/index; slow to rebuild".
- **C1 junk:** direct child of `Library/Caches` not denied, not D3, not C1r.
- **C2 junk:** regular file under `Library/Logs/**` (includes DiagnosticReports) modified > 7 days ago.
- **I1 junk:** file or package (not a symlink) in `Downloads` (depth ≤ 2) with extension dmg / pkg / mpkg / iso / xip, date added > 30 days ago (fall back to modified when date added is nil). (superseded by T6 #1: `.dmg`/`.iso` are Review)
- **B1 review:** any file or package ≥ 500 MB (allocated, 1 MB = 1,000,000 bytes) not matched above; reason says "stale" when modified > 180 days ago. (superseded by T7: B1 needs modified > 180 d, no label)

Acceptance — tests written first, each must fail before implementing:
- Every rule has a positive and a negative test; the deny list has one test per pattern family.
- Boundaries: log 6 d vs 8 d; dmg added 29 d vs 31 d; 499 MB vs 500 MB; modified 179 d vs 181 d for the stale label (now T7's B1 age gate).
- Precedence: `Library/Caches/Homebrew` → D3 not C1; `Library/Caches/JetBrains` → C1r not C1; `node_modules` holding a 2 GB file → D5 only.
- `target` with `Cargo.toml` → D4; `target` with `pom.xml` only → nil.

## T3 Scanner
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

`scan(root: URL, now: Date) -> ScanResult` (findings + skipped locations).
- First thing in `main`: `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`.
- Root resolved with `resolvingSymlinksInPath()`. `FileManager.enumerator` with `.skipsPackageDescendants` and prefetched keys from research "APIs to use". No `.skipsHiddenFiles`.
- Skip list (never descend): `Library/Mobile Documents`, `Library/CloudStorage`, `Library/Containers`, `Library/Group Containers`, `Library/Mail`, `Library/Messages`, `Library/Safari`, `Library/Cookies`, `Library/Calendars`, `Library/Keychains`, `Library/Application Support`, `.Trash`, `.ssh`, `.gnupg`, `.aws`, `.cache`, `.config`, `.local`, `.rustup`, `.nvm`, `.cargo/bin`, `go/bin`, `.pyenv/versions`, `.sbt/boot`, `.stack/programs`, `Pictures`, `Music`, `Desktop`, `Documents`.
- Directory matches are sized by summing allocated bytes of everything inside, then `skipDescendants()`. Packages sized as one unit.
- Hard links counted once by (volume id, file id) when link count > 1. Symlinks never followed. Directories on a different volume than the root are skipped and recorded.
- errorHandler always continues; classifies EPERM → protected, EACCES → owner, EDEADLK → cloud-only; records the top-level path once.

Acceptance — integration tests with fixtures in a temp dir under `~`:
- hard link pair counted once; sparse file (1 MB written at offset 99 MB) sized ~1 MB; symlink to outside dir and symlink loop not followed, scan ends.
- `chmod 000` dir → recorded as owner, scan continues (restore permissions in cleanup).
- `node_modules/a/node_modules/b` with `package.json` → one finding, total counted once.
- `Foo.app` holding a 600 MB sparse-free file → one B1 finding for the bundle, inner file absent.
- A skip-list dir with junk inside → no findings from it.
- Symlink to a `.dmg` in `Downloads` → no finding (symlinks never reach `classify`).
- `node_modules` (with `package.json`) holding a 600 MB file → one D5 finding, no B1 for the inner file.
- Error classifier unit test with injected NSError (Cocoa 257 / POSIX EPERM, POSIX EACCES, POSIX EDEADLK).

## T4 Report output and CLI
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

- `render(_ result: ScanResult, now: Date) -> String`: sections per category, each sorted by size descending, paths shown with `~`, human sizes (1000-based like Finder: `1.2 GB`, `340 MB`, `12 KB`), age (`modified 214 d ago` / `added 95 d ago`), reason.
- Separate totals: "Junk (reclaimable)" and "Review (check before deleting)".
- One summary line for skipped locations by kind; never prints 0 bytes for a blocked folder.
- Footer caveats (research "Output caveats"): allocated bytes, hard links once, clones counted at full size, snapshots, Finder figures won't match, lower bound.
- `swift run junk` runs scan on `~` and prints the report.

Acceptance (TDD): render tests on a fixed `ScanResult` assert exact section order, sorting, totals, size formatting boundaries (999 KB / 1.0 MB, 999 MB / 1.0 GB), the skipped line, and the footer.

## T5 Real run and README
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

- Run `swift run -c release junk` on this Mac; record wall time.
- Spot-check 3 findings against `du -sk` (within 1%).
- README: what it does, list-only promise, how to run, Full Disk Access note (what it adds and what it can't; grant to the terminal, revoke after), what is skipped and why.
- Report any surprise (prompts seen, wrong sizes, noisy rules) as findings for the human; do not fix silently.

## T6 Security hardening (from the T3/T4 break review)
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

Each fix starts with a test that reproduces the attack; run it and show it failing, then the smallest change to green.
- #1 I1: `.dmg` and `.iso` → tier Review, reason "installer or disk image; make sure it isn't your only copy". `.pkg`/`.mpkg`/`.xip` stay Junk with the current reason. Update the I1 tests.
- #2 Reasons: C1 → "app cache; quit the app before deleting"; D1 → "Xcode build cache; quit Xcode first".
- #3 Report: every path printed (finding rows and the skipped line) has control characters (< 0x20 and 0x7F) replaced with `?`. Test: a finding whose path contains `\n` and `\u{1B}[1A` renders on one line with `?` in their place.

Later (re-check after fix): C1 controls U+0080–U+009F (8-bit CSI) and bidi overrides (U+202A–U+202E, U+2066–U+2069) still pass through `safe()`.

## T7 Real-run noise (from the T5 findings)
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

TDD for each behaviour change (rules and render are pure; scanner via fixtures).
- Newest-child age: directory and package findings use the newest `contentModificationDate` of any regular file inside (collected during the existing size sub-walk) as `modified`, falling back to the item's own date when empty.
- Sub-walk stays on the root volume: a directory inside a matched dir/package whose `volumeIdentifier` differs from the root's is skipped and recorded as a mount point. (verified by inspection only; needs a second volume to fixture-test.)
- Zero-size dir/package matches (e.g. empty `Library/Caches/Yarn`) are dropped.
- D5: no match when the path's first component starts with `.` (e.g. `.npm/_npx/x/node_modules`, `.windsurf/extensions/x/node_modules`).
- B1 needs modified > 180 d (research age gate); drop the "stale" label since every B1 is now stale. Boundary test 179 d vs 181 d.
- Footer gains one line: "Not scanned by design: Trash, Mail, cloud folders, app containers, Application Support, Desktop, Documents, Pictures, Music." README updated to match.
- `formatSize`: values that round to 100.0 MB/GB print "100 MB"/"100 GB". Test at 99_950_000.

Deferred (not in T7): grouping C2 log files per folder, B2 path rules (Ollama/LM Studio models), scan speed.

## T8 `junk clean <section>...`: remove a group of Junk findings
- Agent: swift-macos-dev · Reviewer: junk-reviewer
- Status: done

Decided by the human: Trash by default, `--permanent` deletes outright; Junk tier only; groups by section; show the list, then ask y/N.

CLI (no dependencies): `junk` prints the report as today. `junk clean <section>... [--yes] [--permanent]`.
- Sections → rules: `caches` → C1; `logs` → C2; `dev` → D1, D3; `installers` → I1 Junk (`.pkg`/`.mpkg`/`.xip`). `big` is refused: "Big files are Review only; delete them by hand". Unknown or missing section → usage message, exit 2.
- Only `tier == .junk` findings are ever selected. Review findings (C1r, D4, D5, I1 `.dmg`/`.iso`, B1) are never removed, even when their section is named.
- Running-app guard (research open question 12, Mole's live-owner rule): a C1 finding whose folder name equals a running app's bundle identifier, and D1 while Xcode (`com.apple.dt.Xcode`) is running, are left out and listed as "skipped: app running". The executable reads `NSWorkspace.shared.runningApplications` and passes the bundle ids in; JunkCore stays AppKit-free.
- Plan step is pure (`cleanPlan(result, sections, runningBundleIDs) -> (remove: [Finding], skipped: [(Finding, reason)])`), TDD.
- Before the prompt: print each selected path with its size, the skipped ones with their reason, and the total. Prompt `Move N items (X GB) to Trash? [y/N]`; with `--permanent`: `Permanently delete N items (X GB)? This cannot be undone. [y/N]`. Anything but `y`/`yes` aborts with exit 0 and removes nothing. `--yes` skips the prompt. If stdin is not a TTY and `--yes` is absent: refuse, exit 2 (never hang, never assume yes).
- Per-item re-checks right before removal (the scan can be minutes old): path still exists; it is not a symlink; no component between the root and it is a symlink (the resolved path equals the expected path); it is still under the root and on the root's volume. A failed check skips that item and is reported, never removed.
- Removal: `FileManager.trashItem` (default) or `removeItem` (`--permanent`), one finding at a time. An error on one item is reported and the rest continue.
- Summary: `Moved N items (X GB) to Trash; M skipped; K failed.` (or `Deleted …`). With Trash, add "Space is freed when you empty the Trash." Exit 0 when nothing failed, 1 otherwise.
- Printed paths go through the same control-character sanitiser as the report.
- README: replace the list-only promise with the clean command, its sections, Junk-only scope, Trash vs `--permanent`, the running-app guard, and that the scan runs first (2–3 min).

Acceptance (TDD for the plan, the re-checks and argument parsing):
- Plan: each section selects exactly its rules; Review findings in a named section are never selected; `big` refused; running app → skipped with reason; Xcode running → D1 skipped, D3 still selected.
- Arguments: no section, unknown section, `big`, flags in any order, `--yes`/`--permanent` combinations.
- Re-checks with fixtures under `~`: a finding replaced by a symlink before removal → not removed; a finding whose parent was swapped for a symlink to a dir outside the root → nothing outside the root touched; a finding deleted before removal → reported as skipped, no crash.
- Removal with fixtures: `--permanent` removes the fixture dirs; the Trash path is tested with one tiny fixture whose `resultingItemURL` is then removed, so nothing is left in the user's real Trash.
- No test or code path removes anything outside fixtures; the real `~` is never cleaned during development.

## T9 Stale `node_modules` / Composer `vendor` → Junk; `junk clean node_modules vendor`
- Agent: main session · Reviewer: break review
- Status: done

Decided by the human: a `node_modules` (sibling `package.json`) or `vendor` (sibling `composer.json`, new rule D6) whose newest file is more than 30 days old is Junk; with any file changed in the last 30 days it stays Review. Junk also needs a lock file next to it (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lockb`, `bun.lock`; `composer.lock`), else a reinstall may pull different versions (break review #1). Clean sections `node_modules` → D5 Junk, `vendor` → D6 Junk; `dev` does not include them.

Acceptance:
- Rules: 31 d → Junk, 29 d → Review for both; `.build` stays Review at any age; `vendor` without `composer.json` (e.g. Go `go.mod`) → nil; `.composer/vendor` (hidden top level) → nil.
- Plan: each section selects only its stale folders; recent ones never selected.
- Scanner: `vendor` gets sibling lookup.

