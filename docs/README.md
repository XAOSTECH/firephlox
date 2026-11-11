# firephlox

Telemetry surgery for the Snap-confined Firefox browser on Ubuntu. Named after Dr. Phlox of *Star Trek: Enterprise* — precise, targeted, and always optimistic about the patient's prognosis.

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
