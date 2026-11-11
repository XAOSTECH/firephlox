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
| `-y`, `--yes` | Skip the cache-purge confirmation prompt |
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

Injects a delimited managed block into `user.js` inside every active profile under `~/snap/firefox/common/.mozilla/firefox/`. The block is idempotent — re-running firephlox replaces it cleanly without disturbing your own preferences. It disables health-report and usage uploads and keeps GPU hardware acceleration enabled.

### Task 3 · Cache and telemetry purge

Removes `datareporting/`, `saved-telemetry-pings/`, and `crashes/` from every active profile. A path guard prevents deletion outside the Snap profile tree.

### Task 4 · Apple Music True Shuffle

Deploys a self-contained WebExtension (`apple-music-shuffle@firephlox`) that injects a True Shuffle button into the Apple Music web player (`music.apple.com`). The extension uses a Durstenfeld / Fisher-Yates shuffle on the MusicKit queue — statistically unbiased, unlike the platform's native shuffle. Extensions installed via enterprise `ExtensionSettings` policy are not required to be signed by Mozilla.

The XPI is stored at `/var/snap/firefox/common/extensions/apple-music-shuffle@firephlox.xpi`. To diagnose whether it loaded, open the browser console on `music.apple.com` and look for `[firephlox shuffle] content script loaded`.

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
  docs/
    README.md        — this file
```
