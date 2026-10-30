---
name: mac-cleanup
description: Guided macOS disk cleanup journey — measure "System Data", find what is really eating space (Docker/OrbStack, local databases, chat app media, app VM bundles, browser AI models, dev caches), report it, then remove only what the user confirms item by item. Use whenever the user says "mac cleanup", "clean my mac", "free disk space", "what's in System Data", "analyze my system data", "junk journey", or "/mac-cleanup".
---

# Mac cleanup journey

Run from the JunkFinder repo. Five phases, in order. Phases 1–3 are **read-only**. Nothing is removed until phase 4, and only per item the user picked.

## Hard rules

- Read-only until the user picks items. Every removal is confirmed with AskUserQuestion, one question per item group, with size, last-used date, and whether it can be undone.
- Prefer undoable: Trash over `rm`, in-app cleanup over touching app files, `docker rm` of stopped containers over volumes. Say "cannot be undone" plainly for `DROP DATABASE`, `docker volume prune`, `--permanent`.
- Quit the owning app before touching its files (WhatsApp, Claude, Chrome, Xcode).
- Never run `junk clean` or delete anything under `~` unless the user picked it in this session.
- Chat/app databases: read counts and file paths only, never message text.
- Don't size `~/Library/Containers` or `~/Library/Group Containers` as a whole without need: size named children (avoids TCC prompts for other apps' data).
- After each removal, verify (item gone) and show `df -H /System/Volumes/Data` before → after.

## Shell gotchas (macOS zsh)

- No `timeout` command. Unmatched globs abort zsh: start with `setopt null_glob`.
- `du -sk` gives KiB; print decimal GB like Finder: `awk '{printf "%7.1f GB %s\n", $1*1.024/1e6, $2}'`.
- `du` reads allocated bytes and does not download iCloud dataless files.

## Phase 1 — Overview

```sh
df -H / /System/Volumes/Data
tmutil listlocalsnapshots /          # local Time Machine snapshots (purgeable)
ls -la /private/var/vm               # sleepimage/swap: leave alone
swift run -c release junk            # JunkFinder report for ~ (list only, 2–3 min)
```

## Phase 2 — Find the big items

Size these, then drill into anything ≥ 1 GB one level at a time (`du -sk -- "$dir"/* | sort -rn | head`).

| Area | Paths |
|---|---|
| Home dev caches | `~/.npm ~/.cache ~/.bun ~/.cargo ~/.rustup ~/.gradle ~/.m2 ~/.pyenv ~/.nvm ~/.ollama ~/.vscode ~/.cursor ~/.windsurf ~/Library/Caches ~/Library/Logs` |
| Xcode | `~/Library/Developer/{Xcode/DerivedData,Xcode/Archives,Xcode/iOS DeviceSupport,CoreSimulator/Devices}` |
| App data | each child of `~/Library/Application Support` (e.g. `Claude/vm_bundles`, `Google/Chrome/OptGuideOnDeviceModel`, `Code/User/workspaceStorage`) |
| Containers | `~/Library/Group Containers/*orbstack*`, `*WhatsApp*`, `~/Library/Containers/com.docker.docker`, `com.microsoft.teams2` |
| iPhone backups | `~/Library/Application Support/MobileSync/Backup` |
| Homebrew data | `/usr/local/var/*` and `/opt/homebrew/var/*` (MySQL, Postgres data dirs) |
| System (leave alone) | `/private/var/folders`, `/System/Volumes/Data/System/Library/AssetsV2` |

### Specific checks

**Local databases** (MySQL example; Postgres: `pg_database_size`):
```sh
mysql -u root -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1e9,2) gb FROM information_schema.tables GROUP BY 1 ORDER BY 2 DESC;"
ls -lt /usr/local/var/mysql/<db> | head -3   # last write date
```

**Docker / OrbStack** — containers not started in 60+ days, unused images, orphan volumes:
```sh
docker system df
cut=$(date -u -v-60d +%Y-%m-%dT%H:%M:%S)
docker ps -aq | xargs docker inspect -f '{{.State.StartedAt}}|{{.State.Status}}|{{.Name}}|{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}' \
  | awk -F'|' -v c="$cut" '$2!="running" && $1<c'
docker images --format '{{.Repository}}:{{.Tag}}|{{.Size}}|{{.ID}}'   # mark those no remaining container uses
docker system df -v | sed -n '/Local Volumes/,/Build cache/p'          # LINKS 0 = orphan
```
`CreatedSince` is the image build date, not last use. OrbStack returns freed space to macOS by itself.

**WhatsApp orphan media** — Settings → Manage Storage only shows media it still tracks; cleared chats can leave GBs on disk:
```sh
W=~/Library/Group\ Containers/group.net.whatsapp.WhatsApp.shared
du -sk "$W"/Message/Media/* | sort -rn | head
# per big folder <jid>: does the chat exist, and how many media items does it still reference?
sqlite3 -readonly "file:$W/ChatStorage.sqlite?mode=ro" "SELECT s.ZCONTACTJID, s.ZPARTNERNAME, COUNT(i.Z_PK) FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION=s.Z_PK LEFT JOIN ZWAMEDIAITEM i ON i.ZMESSAGE=m.Z_PK AND i.ZMEDIALOCALPATH IS NOT NULL WHERE s.ZCONTACTJID LIKE '<jid-number>%' GROUP BY s.Z_PK;"
# referenced files to keep:
sqlite3 -readonly "file:$W/ChatStorage.sqlite?mode=ro" "SELECT i.ZMEDIALOCALPATH FROM ZWAMEDIAITEM i JOIN ZWAMESSAGE m ON i.ZMESSAGE=m.Z_PK JOIN ZWACHATSESSION s ON m.ZCHATSESSION=s.Z_PK WHERE s.ZCONTACTJID LIKE '<jid-number>%' AND i.ZMEDIALOCALPATH IS NOT NULL;"
```
No chat row → whole folder is orphaned. Chat row → everything except the listed paths is orphaned.

## Phase 3 — Report

One table, biggest first: `# | What | Size | Where | Is it junk?` (junk / your data / regenerates / leave alone). Then:
- **Leave alone**: swap/sleepimage, `/private/var/folders`, AssetsV2, snapshots (purgeable).
- **Quick wins (no data loss)**: caches, stopped stale containers, unused images.
- **Your call**: databases, chat media, app VM bundles, browser AI models (disable in-app, else they re-download).
- What JunkFinder's rules already cover vs miss (candidate tasks for `tasks.md`).

## Phase 4 — Remove (only what the user picks)

Ask with AskUserQuestion, recommended option first. Known-good actions:

| Item | Action |
|---|---|
| Old MySQL DB | Offer `mysqldump <db> \| gzip > ~/<db>.sql.gz` first; then `mysql -u root -e "DROP DATABASE <db>;"` |
| Stale containers | `docker rm <names>` |
| Unused images | `docker image prune -a` |
| Orphan/old volumes | `docker volume prune -a` — deletes DB data, cannot be undone; list volumes first |
| WhatsApp tracked media | User does it in-app: Settings → Storage and Data → Manage Storage |
| WhatsApp orphans | Quit WhatsApp, move orphan files/folders to Trash (keep referenced paths) |
| Chrome AI model | Chrome Settings → System → On-device AI off (deleting the folder alone re-downloads) |
| Claude `vm_bundles` | Quit Claude; Trash; re-downloads on next sandbox use |
| `~` junk (caches, logs, dev, installers, node_modules, vendor) | `swift run -c release junk clean <section>...` — prompts y/N itself; Trash by default. `node_modules`/`vendor` only when nothing inside changed for 30+ days |

## Phase 5 — Close

Show free space before → after and total reclaimed. List what was left and why. Offer to add new rules (paths JunkFinder missed) as tasks.
