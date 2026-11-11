# FINDINGS – Firefox snap profile corruption incident (2026-11-11)

Factual record of a Firefox profile corruption incident on Ubuntu with
the Firefox snap, the diagnostic steps taken, and the lessons it
produced for firephlox and for Firefox snap profile maintenance generally.

---

## Incident overview

**Date:** 2026-11-11
**Firefox version:** 160.0-1 (snap rev 9181)
**Firefox 160 release date:** 2026-11-10 (the day before)
**Platform:** Ubuntu with Firefox installed via snap

The user reported three concurrent symptoms immediately after a session
in which a streaming media description was modified while a stream was
in the process of loading:

- A privacy/data-policy consent screen appeared on every new tab and
  browser launch
- Any attempt to play media – from any source, including local Plex –
  caused the browser tab to visually freeze (interactive under the hood,
  not reflected on screen)
- Hardware acceleration settings could not be changed via the Firefox
  settings UI

---

## Environment at the time of the incident

firephlox had been run on this installation prior to the incident.
The `--restore` flag had also been run at some point, removing the
enterprise `policies.json` files and the `user.js` managed block.

Three `snap saved` snapshots existed:
| Set ID | Age | Version | Notes |
|---|---|---|---|
| 2 | ~96 days | 153.0.3-1 (rev 8736) | manual – known-good baseline |
| 6 | ~14.5 h | 160.0-1 (rev 9181) | manual – taken during the incident |
| 7 | ~14.4 h | 160.0-1 (rev 9181) | auto – taken during the incident |

---

## Diagnostic findings

### Databases – all intact

All six core SQLite databases in the broken profile passed integrity
checks: `permissions.sqlite`, `cookies.sqlite`, `places.sqlite`,
`formhistory.sqlite`, `storage.sqlite`, `favicons.sqlite`.

### prefs.js – syntax intact but contains firephlox remnants

`prefs.js` contained 386 entries, all syntactically valid. No truncated
or malformed lines were found.

The following value was present and is a known firephlox remnant –
set by firephlox's `user.js` managed block and persisted in `prefs.js`
after `user.js` was removed:

| Pref key | Value | Source |
|---|---|---|
| `xpinstall.signatures.required` | `false` | firephlox user.js managed block |

The following prefs were present and are new Firefox 128+ telemetry IDs
not covered by the original firephlox policies:

- `datareporting.dau.cachedUsageProfileGroupID`
- `datareporting.dau.cachedUsageProfileID`

### No enterprise policies remained

Both `policies.json` paths were absent at the time of investigation,
confirming `--restore` had been run before the incident snapshot was
taken.

---

## Recovery procedure

Snapshot 2 was used as the base (clean profile from the Firefox 153 era).
Snapshot 6 was used as the donor (broken profile containing the desired
settings).

**Step 1 – Triage snapshot 6:**
```sh
./firephlox --triage=6
```
Result: all databases intact, prefs.js syntax intact, one warning
(`xpinstall.signatures.required = false`). No findings file written.

**Step 2 – Inspect for firephlox remnants:**
```sh
./firephlox --restore=6
```
Result: `xpinstall.signatures.required` confirmed as a firephlox-managed
remnant value in the specimen.

**Step 3 – Full revive with fresh clone:**
```sh
./firephlox --revive=6 --fresh
```
Result: 345 of 386 prefs transplanted (41 excluded by the standard
filter). All databases, extensions, and extension storage transplanted.
Video playback restored. Cookie exception list retained.

**Confirmed working:** video playback and cookie exceptions after the
345-pref transplant.

---

## What was excluded from the pref transplant and why

| Excluded namespace | Reason |
|---|---|
| `datareporting.*` | Telemetry reporting control prefs |
| `toolkit.telemetry.*` | Telemetry framework – includes installation UUIDs |
| `media.gmp-*` | Codec binary hashes and version strings tied to the installed snap revision; transplanting a mismatched hash can cause decoder failures |
| `distribution.*` | Snap distribution markers (Canonical branding) – host-specific |
| `identity.fxaccounts.account.device.*` | Device hostname – host-specific |
| `browser.sessionstore.*` | Session state – not transferable between instances |
| `browser.cache.*` | Cache state – ephemeral |
| `services.sync.*` | Firefox Sync credentials |
| `xpinstall.signatures.required` | firephlox-managed value |
| `layers.acceleration.disabled` | firephlox-managed value |
| `media.hardware-video-decoding.enabled` | firephlox-managed value |
| `media.ffmpeg.vaapi` | firephlox-managed value |
| `privacy.resistFingerprinting` | Known to strip referrer headers on cross-site requests, breaking CDN-authenticated video (HTTP 403) |
| firephlox-locked pref values | Any pref whose value exactly matches a value firephlox writes via policies.json (zeroed UUID, `http://127.0.0.1`, `{}`) is not transplanted – the value would re-lock the destination and require another restore cycle |
| Values containing filesystem paths | Host-specific absolute paths (`/home/`, `/snap/`, `file://`) |

---

## Lessons: Firefox snap profile anatomy

### File layout
```
~/snap/firefox/common/.mozilla/firefox/
  profiles.ini               – profile registry
  <name>.default/            – active profile
    prefs.js                 – runtime preferences (key-value JS statements)
    user.js                  – user overrides applied on every launch
    permissions.sqlite        – site permission exceptions (cookies, geo, etc.)
    cookies.sqlite            – actual stored cookies
    places.sqlite             – bookmarks and navigation history
    formhistory.sqlite        – form autofill history
    favicons.sqlite           – favicon cache
    cert9.db                  – certificate trust database
    key4.db                   – password encryption key (pair with logins.json)
    logins.json               – saved login credentials
    extensions.json           – extension registry
    extensions/               – extension XPI files
    storage/default/moz-extension+++<id>/  – extension IndexedDB (uBlock rules etc.)
    browser-extension-data/   – legacy extension storage
```

### Key distinctions
- **Cookie exceptions** (allow/block/session per site) live in
  `permissions.sqlite`, not in `prefs.js`.
- **prefs.js** is not JSON – it is a flat sequence of `user_pref("key", value);`
  statements overwritten by Firefox on every clean shutdown.
- **user.js** is read and applied to prefs.js on every Firefox launch.
  Removing user.js does not remove the values it previously wrote to
  prefs.js – those values persist until Firefox overwrites them or they
  are manually removed.
- **Extension storage** (custom filter rules, settings) lives in
  the IndexedDB tree under `storage/default/`, keyed by extension UUID.
  It is not inside the XPI file.

### Snap snapshot format
Snap data snapshots (`snap save firefox`) produce a ZIP at
`/var/lib/snapd/snapshots/<set-id>_firefox_<version>_<revision>.zip`.

The ZIP contains:
- `meta.json` and `meta.sha3_384` – metadata and checksum
- `archive.tgz` – system snap data
- `user/<username>.tgz` – per-user snap data

Each `.tgz` stores paths relative to the snap's data root
(`~/snap/firefox/`), so the Firefox profile is at
`common/.mozilla/firefox/<profile>/` inside the tarball.

The tarballs contain symlinks that point to absolute system paths
(e.g. `.local/share/themes → /usr/share/themes`). These cannot be
safely extracted and are skipped during firephlox's staging step.

---

## Lessons: firephlox operations and their footprint

### What firephlox writes
| Operation | Artefact | Location |
|---|---|---|
| `--run` Task 1 | `policies.json` | `/etc/firefox/policies/` and `/var/snap/firefox/common/distribution/` |
| `--run` Task 2 | user.js managed block | `~/snap/firefox/common/.mozilla/firefox/<profile>/user.js` |
| `--run` Task 4 | `apple-music-shuffle@firephlox.xpi` | snap extensions dir and each profile's `extensions/` |
| `--sign` Task 5 | signed XPI cache | `~/.cache/firephlox/` |

### What persists after `--restore`
Running `--restore` removes all the above artefacts. However, values
previously written to `prefs.js` via `user.js` remain in `prefs.js`
until Firefox overwrites them. As of the restore step added in this
investigation, `--restore` now explicitly scrubs those values.

Prefs that firephlox's `user.js` managed block writes to `prefs.js`:
- `datareporting.healthreport.uploadEnabled = false`
- `datareporting.policy.dataSubmissionPolicyAcceptedVersion = 0`
- `datareporting.usage.uploadEnabled = false`
- `layers.acceleration.disabled = false`
- `xpinstall.signatures.required = false`

Prefs that firephlox's `policies.json` locks (and which may remain in
`prefs.js` as stale values after the policy is removed):
- `toolkit.telemetry.cachedClientID = "00000000-0000-0000-0000-000000000000"`
- `browser.newtabpage.activity-stream.impressionId = "{}"`
- `toolkit.telemetry.server = "http://127.0.0.1"`
- `toolkit.telemetry.unified = false`

### sudo and $HOME
Running firephlox with `sudo` sets `$HOME` to `/root`, causing all
user-profile operations (user.js, purge, XPI in profiles) to silently
skip because no profile is found under `/root/snap/firefox/`. Run
firephlox as your own user; internal privilege escalation handles the
system paths.

---

## firephlox improvements produced by this incident

| Component | Change |
|---|---|
| `08_restore.sh` | Added Restore 6 – scrubs firephlox-managed pref values from prefs.js |
| `02_policies.sh` | Added `datareporting.dau.cachedUsageProfileGroupID` and `datareporting.dau.cachedUsageProfileID` to the locked pref set |
| `09_triage.sh` | Added prefs.js syntax validation (detects partial writes); added `--triage=<id>` for staging and triaging a snapshot |
| `10_revive.sh` | Expanded pref exclusion list (`media.gmp-*`, `distribution.*`, `identity.fxaccounts.account.device.*`); added firephlox-locked value filter; added `--prefs-only=` for selective namespace transplant |
| `08_restore.sh` | Added `--restore=<id>` to report firephlox remnants in a snapshot |
| `09_triage.sh` / `10_revive.sh` | Triage–revive cooperation via `~/.cache/firephlox/triage-<id>.findings` |
| `firephlox` | Fixed `realpath` vs `cd` for restricted-shell invocation |
