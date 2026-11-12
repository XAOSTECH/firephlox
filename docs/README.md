# firephlox

<p align="center"><img src="../assets/icon.png" width="220" alt="Dr. Phlox emblem – Have No Fear, Phlox Is Here!"></p>

Surgery for the Snap-confined Firefox browser on Ubuntu. Named after Dr. Phlox of *Star Trek: Enterprise* — precise, targeted, and always optimistic about the patient's prognosis.

## Requirements

- Ubuntu with the Firefox Snap installed and launched at least once
- `python3` (present by default on Ubuntu)
- `sudo` access (required only for writing to `/etc/firefox/policies/` and `/var/snap/firefox/common/`)

## Usage

```sh
cd ubu-tools/firephlox
./firephlox [options]
```

| Option | Effect |
|---|---|
| `-n`, `--dry-run` | Print every action without writing or deleting anything |
| `-y`, `--yes` | Skip confirmation prompts; auto-advance elimination rounds |
| `-r`, `--restore` | Undo all firephlox changes on the active profile |
| `--restore=<id>` | Report firephlox-managed pref remnants in a specific snapshot |
| `-t`, `--triage` | Inspect the active profile for corruption and known-bad configuration |
| `--triage=<id>` | Triage a specific snap data snapshot instead of the active profile |
| `--revive=<id>` | Transplant settings from a snap data snapshot into the active profile |
| `--fresh` | With `--revive`: wipe the current profile first (clean slate transplant) |
| `--backup` | With `--revive --fresh`: archive the wiped profile to `.pre-revive-*` instead of deleting |
| `--prefs-only=<ns>` | With `--revive`: transplant only prefs whose keys start with the given comma-separated namespaces |
| `--exclude=<cat>` | With `--revive`: skip data categories (`sqlite`, `credentials`, `config`, `extensions`, `prefs`) |
| `--eliminate=<id>` | Progressive pref-namespace elimination test to identify a corrupted pref |
| `--smart` | With `--eliminate`: grouped pass, then auto-splits the culprit batch |
| `--full` | With `--eliminate`: one term per round (maximum precision) |
| `--culprits=<n>` | With `--eliminate`: search for up to n pathogens in sequence (default 1) |
| `--cleanup` | Remove accumulated `.pre-revive-*` backup directories and stale staging artefacts |
| `--no-purge` | Skip Task 3 (cache and telemetry purge) |
| `--no-shuffle` | Skip Task 4 (True Shuffle extension deployment) |
| `-h`, `--help` | Show usage and exit |

After the first run, **fully quit Firefox** (check the system tray) and relaunch it. Enterprise-managed extensions install at startup, not mid-session.

## Tasks

### Task 1 · Enterprise policy injection

Writes identical `policies.json` files to two locations:

- `/etc/firefox/policies/policies.json` — the Mozilla-documented system-wide path for all Linux distributions
- `/var/snap/firefox/common/distribution/policies.json` — a supplementary path used by Canonical's Ubuntu snap packaging

The policies zero `toolkit.telemetry.cachedClientID`, redirect the telemetry server to `127.0.0.1`, disable unified telemetry, Firefox Studies, and the new DAU tracking IDs (`datareporting.dau.*`).

### Task 2 · Profile hardening

Injects a delimited managed block into `user.js` inside every active profile. The block is idempotent — re-running replaces it cleanly without disturbing existing preferences.

### Task 3 · Cache and telemetry purge

Removes `datareporting/`, `saved-telemetry-pings/`, and `crashes/` from every active profile. A path guard prevents deletion outside the snap profile tree.

### Task 4 · Apple Music True Shuffle

Deploys a self-contained WebExtension (`apple-music-shuffle@firephlox`) that injects a True Shuffle button into the Apple Music web player. The extension uses a Durstenfeld / Fisher-Yates shuffle on the MusicKit queue.

## Restore

```sh
./firephlox --restore          # undo all firephlox changes on active profile
./firephlox --restore=<id>     # inspect a snapshot for firephlox remnants (read-only)
```

`--restore` removes policies, strips the `user.js` managed block, removes extension XPIs, and scrubs firephlox-managed pref values (`xpinstall.signatures.required`, zeroed UUIDs, etc.) from `prefs.js`. Run as your own user — not with `sudo`.

## Triage

```sh
./firephlox --triage           # diagnose the active profile
./firephlox --triage=<id>      # diagnose a specific snap data snapshot
```

Non-destructive. Checks SQLite integrity on all core databases, validates `prefs.js` syntax (detects partial writes from crashes), flags known-bad pref values, reports crash dumps, extension orphans, and snap interface connections. When run on a snapshot, writes a findings file to `~/.cache/firephlox/triage-<id>.findings` — `--revive` reads this automatically and applies any exclusion recommendations.

## Revive

```sh
snap saved firefox             # list available snapshots
./firephlox --revive=<id>      # transplant into active profile
./firephlox --revive=<id> --fresh              # wipe first, then transplant
./firephlox --revive=<id> --fresh --backup     # archive the wiped profile before transplanting
./firephlox --revive=<id> --prefs-only=browser,network,extensions
./firephlox --revive=<id> --fresh --exclude=prefs
```

Surgical transplant from a snap data snapshot. The source snapshot is never modified or deleted. All staging is performed in `~/.cache/firephlox/stage.*` (main filesystem, not `/tmp`).

**Transplanted by default:**
- All SQLite databases passing integrity check: `permissions.sqlite` (cookie exceptions, site permissions), `cookies.sqlite`, `places.sqlite` (bookmarks, history), `formhistory.sqlite`, `favicons.sqlite`, `cert9.db`
- Credential pair `logins.json` + `key4.db` (transplanted together or not at all)
- Configuration files: containers, search engines, extension prefs/settings, extension registry
- Extension XPI files and extension IndexedDB storage (uBlock rules, etc.) — firephlox's own extension excluded
- Preferences from `prefs.js` → written to `user.js` with firephlox-managed values, telemetry IDs, codec hashes, and path-specific values excluded

**`--fresh`:** Archives or wipes the current profile before transplanting, giving a clean slate. The snap snapshot is the authoritative backup; `--backup` additionally archives the wiped profile locally.

**`--prefs-only=ns1,ns2`:** Whitelist mode — transplants only prefs whose keys start with the given namespaces (e.g. `browser.contentblocking,network.trr`). Bypasses the standard exclusion list.

**`--exclude=cat`:** Skip entire data categories: `sqlite`, `credentials`, `config`, `extensions`, `prefs`.

## Eliminate

```sh
./firephlox --eliminate=<id>              # standard grouped pass (7 rounds)
./firephlox --eliminate=<id> --smart      # grouped then auto-splits culprit batch
./firephlox --eliminate=<id> --full       # one namespace term per round
./firephlox --eliminate=<id> --smart --culprits=2   # find two pathogens automatically
./firephlox --eliminate=<id> --smart --exclude=gfx  # skip a known culprit, find the next
```

Progressive elimination test for identifying which pref namespace contains a corrupted value. Each round transplants a cumulative set of pref namespaces, launches Firefox on the canonical test subject ([Fantastic Planet, 1973](https://archive.org/details/fantastic__planet1973)), and waits for the user to close it.

After Firefox closes a **5-second countdown** is shown. Press Ctrl+C during the countdown to flag that round's batch as the culprit and print the conclusion. If the countdown completes the round passes and the next begins. Add `-y` to skip the countdown and auto-advance (useful for unattended runs).

**Modes:**
- **Standard** — 7 grouped rounds (fastest when the suspect area is unknown)
- `--smart` — standard first pass, then automatically splits the failing batch into individual rounds
- `--full` — every individual namespace term gets its own round (maximum precision)
- `--culprits=N` — repeats the protocol automatically, excluding each found pathogen, until N are identified

**After finding a culprit,** the conclusion prints:
1. The full `--prefs-only=` command covering every namespace except the pathogen(s)
2. A `--eliminate=<id> --exclude=<culprit>` command to find the next pathogen

## Cleanup

```sh
./firephlox --cleanup          # remove accumulated backup and staging artefacts
./firephlox --cleanup --dry-run
```

Removes `.pre-revive-*` directories left by `--backup` runs and any stale `stage.*` staging directories from interrupted extractions. Reports the total disk space reclaimed.

## Verification

After running, open `about:policies` in Firefox to confirm all policies are active. `about:addons` will show the True Shuffle extension as a managed installation.

## Structure

```
firephlox/
  firephlox          — orchestrator entry point
  assets/
    icon.png         — Dr. Phlox emblem (rendered)
    icon.svg         — Dr. Phlox emblem (source)
    shuffle.js       — Apple Music True Shuffle content script
  lib/
    colours.sh       — shared ANSI colour palette
    titles.sh        — banner and section headings
    common.sh        — logging, privilege escalation, profile discovery
    triage.sh        — reusable diagnostic helpers (sqlite check, pref reader)
  src/
    01_prereqs.sh    — pre-flight safety checks
    02_policies.sh   — enterprise policy injection
    03_userjs.sh     — profile user.js hardening
    04_purge.sh      — telemetry cache purge
    05_verify.sh     — path-mapping verification
    06_shuffle.sh    — True Shuffle extension build and deployment
    07_sign_amo.sh   — optional AMO signing via the Mozilla add-ons API
    restore.sh       — restore Firefox to its pre-firephlox state
    triage.sh        — non-destructive profile diagnostics
    revive.sh        — transplant settings from a snap data snapshot
    eliminate.sh     — progressive pref-namespace elimination test
  docs/
    README.md        — this file
    FINDINGS.md      — incident report: 2026-11-11 profile corruption
```


## Requirements

- Ubuntu with the Firefox Snap installed and launched at least once
- `python3` (present by default on Ubuntu)
- `sudo` access (required only for writing to `/etc/firefox/policies/` and `/var/snap/firefox/common/`)

## Usage

```sh
cd ubu-tools/firephlox
./firephlox [options]
```

| Option | Effect |
|---|---|
| `-n`, `--dry-run` | Print every action without writing or deleting anything |
| `-y`, `--yes` | Skip confirmation prompts |
| `-r`, `--restore` | Undo all firephlox changes and return Firefox to its default state |
| `-t`, `--triage` | Inspect the active profile for corruption and known-bad configuration |
| `--revive=<id>` | Dissect a snap data snapshot and transplant its settings into the active profile |
| `--no-purge` | Skip Task 3 (cache and telemetry purge) |
| `--no-shuffle` | Skip Task 4 (True Shuffle extension deployment) |
| `-h`, `--help` | Show usage and exit |

After the first run, **fully quit Firefox** (check the system tray) and relaunch it. Enterprise-managed extensions install at startup, not mid-session.

## Tasks

### Task 1 · Enterprise policy injection

Writes identical `policies.json` files to two locations:

- `/etc/firefox/policies/policies.json` — the Mozilla-documented system-wide path for all Linux distributions; Firefox reads this via its AppArmor profile
- `/var/snap/firefox/common/distribution/policies.json` — a supplementary path used by Canonical's Ubuntu snap packaging

The policies lock `toolkit.telemetry.cachedClientID` to a zeroed UUID, redirect the telemetry server to `127.0.0.1`, and disable unified telemetry and Firefox Studies.

### Task 2 · Profile hardening

Injects a delimited managed block into `user.js` inside every active profile under `~/snap/firefox/common/.mozilla/firefox/`. The block is idempotent — re-running firephlox replaces it cleanly without disturbing your own preferences.

### Task 3 · Cache and telemetry purge

Removes `datareporting/`, `saved-telemetry-pings/`, and `crashes/` from every active profile. A path guard prevents deletion outside the Snap profile tree.

### Task 4 · Apple Music True Shuffle

Deploys a self-contained WebExtension (`apple-music-shuffle@firephlox`) that injects a True Shuffle button into the Apple Music web player (`music.apple.com`). The extension uses a Durstenfeld / Fisher-Yates shuffle on the MusicKit queue — statistically unbiased, unlike the platform's native shuffle. Extensions installed via enterprise `ExtensionSettings` policy are not required to be signed by Mozilla.

## Restore

```sh
./firephlox --restore
```

Reverses every persistent change. Combine with `--dry-run` to preview without writing or deleting anything.

**Undone by restore:**
- `policies.json` removed from both system locations; `/etc/firefox/policies/` removed if now empty (Task 1)
- firephlox managed block stripped from every profile's `user.js`; file removed when nothing else remains (Task 2)
- `apple-music-shuffle@firephlox.xpi` removed from all three locations (Task 4)
- Signed XPI cache (`~/.cache/firephlox/`) removed if present (Task 5)

**Not affected:** Purged telemetry caches (Task 3) cannot be restored, but Firefox recreates those directories automatically on the next launch.

> Run as your own user — do **not** prefix with `sudo`. The script escalates internally for system paths only. Running as root targets `/root` for profile operations, which skips user-profile tasks silently.

## Triage

```sh
./firephlox --triage
```

Non-destructive diagnostic pass over the active profile. Never writes or deletes anything. Checks:

- Firefox version compatibility with the current profile (`compatibility.ini`)
- SQLite integrity of `permissions.sqlite`, `cookies.sqlite`, `places.sqlite` and other core databases
- Known-problematic preferences (`privacy.resistFingerprinting`, `dataSubmissionPolicyAcceptedVersion`, etc.)
- Session state file presence and size
- Crash report count
- Extension inventory and orphaned XPI files
- Snap interface connections (`hardware-observe`, `opengl`)

Useful as a first step before deciding whether to restore or revive. Pairs naturally with `--revive`.

## Revive

```sh
snap saved firefox          # list available snapshots and their IDs
./firephlox --revive=<id>
```

Surgical transplant of settings from a broken or older snap data snapshot into the currently active profile — without using `snap restore` and without touching or deleting the source snapshot.

**What it does:**
1. Locates the snapshot ZIP in `/var/lib/snapd/snapshots/`
2. Extracts it to a temporary staging area (non-destructive)
3. Finds the Firefox profile inside the snapshot
4. Runs a triage-lite integrity check on the source `permissions.sqlite`
5. Extracts cookie exceptions (allow, block, session rules)
6. Reports what was found and asks for confirmation
7. Transplants the cookie exceptions into the active profile's `permissions.sqlite`
8. Cleans up the staging area

**What it transplants:** Cookie permission exceptions — which sites are allowed to persist cookies, which are blocked, and which are session-only. This is the per-site override list that survives when "Delete cookies and site data when Firefox is closed" is enabled globally.

**What it does not transplant:** Corrupt databases, general preferences, or any data that fails an integrity check.

The source snapshot is **never modified or deleted**, even after a successful transplant. Run `--dry-run` first to preview without making any changes.

## Verification

After running, open `about:policies` in Firefox to confirm all policies are active. `about:addons` will show the True Shuffle extension as a managed installation that cannot be removed by the user.

## Structure

```
firephlox/
  firephlox          — orchestrator entry point
  assets/
    icon.svg         — Dr. Phlox emblem (also used as extension icon)
    shuffle.js       — Apple Music True Shuffle content script
  lib/
    colours.sh       — shared ANSI colour palette
    titles.sh        — banner and section headings
    common.sh        — logging, privilege escalation, profile discovery
  src/
    01_prereqs.sh    — pre-flight safety checks
    02_policies.sh   — enterprise policy injection
    03_userjs.sh     — profile user.js hardening
    04_purge.sh      — telemetry cache purge
    05_verify.sh     — path-mapping verification
    06_shuffle.sh    — True Shuffle extension build and deployment
    07_sign_amo.sh   — optional AMO signing via the Mozilla add-ons API
    08_restore.sh    — restore Firefox to its pre-firephlox state
    09_triage.sh     — non-destructive profile diagnostics
    10_revive.sh     — transplant settings from a snap data snapshot
  docs/
    README.md        — this file
```
