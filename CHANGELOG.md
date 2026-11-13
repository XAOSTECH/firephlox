
## [0.1.0] - 2026-11-13

### Added
- add --culprits=N for multi-pathogen elimination
- complete conclusion command and add --exclude compatibility
- add Ctrl+C countdown and -y auto-advance
- add --smart mode
- add --full mode for single-term elimination rounds
- open Fantastic Planet on archive.org as elimination test subject
- add --eliminate=<id> progressive pref-namespace elimination protocol
- extract shared diagnostic helpers into triage-kit lib
- add --prefs-only for selective pref namespace transplant
- triage-revive cooperation via findings file
- scrub firephlox-managed prefs and add DAU telemetry policy
- add --triage=<id> and --restore=<id> target overrides, extract _fp_stage_snapshot
- add --exclude flag for per-category transplant exclusion
- add fresh clone option alongside active profile transplant
- add flags for profile diagnostics and snapshot transplant

### Fixed
- wait for snap Firefox startup and guard sleep with || true
- move all large staging from /tmp to ~/.cache/firephlox
- improve --cleanup with size report, singular/plural, and Phlox flavour
- default fresh clone to wipe, add --backup opt-in and --cleanup
- only announce findings file when issues are present
- drop syntax_count variable that caused arithmetic error
- add prefs.js syntax validation and improve profile error hint
- skip absolute symlinks during tar extraction
- unpack .tgz archives, not only .tar
- unpack tar-in-zip structure and add diagnostic output on failure
- drop -path filter from find_in_stage
- use privileged du for size and chown after privileged cp
- use if/fi in find_zip to prevent set -e triggering on empty match
- list vault directory before filtering instead of glob-expanding inside it

### Changed
- chore(dc-init): update workflows,actions,docs
- chore: humanise hard-wrapped comments and prose
- docs(FINDINGS): add confirmed root cause - gfx.* namespace
- docs(README): full rewrite covering all new features; add improved icon
- refactor(src): remove numbering from utility modules restore, triage, revive
- docs(FINDINGS): document the 2026-11-11 Firefox snap profile corruption incident
- refactor(10_revive): expand transplant to full profile data and add Phlox flavour
- chore(dc-init): load all templates

