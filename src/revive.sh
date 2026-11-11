# shellcheck shell=bash
# 10_revive.sh — Task V: transplant settings from a snap data snapshot.
#
#   "My people believe that the bond between patient and physician is sacred.
#    I will not leave you." — Dr. Phlox
#
# Non-destructively extracts a snap saved snapshot ZIP, locates the Firefox
# profile inside it, assesses each data category for viability, then
# transplants everything salvageable into the active profile. The source
# snapshot is never modified or deleted.
#
# What is transplanted (all categories pass a viability assessment first):
#   · SQLite databases: permissions, cookies, places (bookmarks+history),
#     formhistory, favicons, cert9.db
#   · Credential pair: logins.json + key4.db (transplanted together or not at all)
#   · Configuration files: containers.json, search.json.mozlz4,
#     extension-preferences.json, extension-settings.json
#   · Extension registry: extensions.json
#   · Extension files: all XPIs in profile/extensions/, excluding the
#     firephlox Apple Music implant
#   · Synaptic relay storage: all moz-extension+++ IndexedDB directories,
#     excluding the firephlox Apple Music implant (this is where extensions
#     such as uBlock Origin store custom rule sets and configuration)
#   · Neural pathway configuration: selected preferences from prefs.js,
#     written to user.js so they override defaults on next launch. Excluded:
#     firephlox-managed prefs, privacy.resistFingerprinting (CDN auth
#     breakage risk), telemetry prefs, sync credentials, path-specific values.
#
# What is never transplanted:
#   · user.js from the source (may contain a firephlox managed block)
#   · sessionstore files (session-bound, not configuration)
#   · datareporting/, crashes/, saved-telemetry-pings/ (ephemeral logs)
#   · cache2/, OfflineCache/ (regenerated automatically)
#   · apple-music-shuffle@firephlox.xpi (firephlox's own implant)
#
# Usage: ./firephlox --revive=<snapshot-id>
#   Snapshot IDs are listed by: snap saved firefox

firephlox_revive() {
	local snap_id="${FIREPHLOX_REVIVE_SNAPSHOT}"
	[[ -n "${snap_id}" ]] || \
		firephlox_die 'No specimen ID given. Usage: --revive=<id>  (run: snap saved firefox)'

	firephlox_section "Revive · Initiating salvage protocol for specimen ${snap_id}"

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. The patient must be fully sedated before surgery.'
	fi

	# --- Revive 1: Locate and stage the snapshot -------------------------
	firephlox_section 'Revive 1 · Extracting the genome — staging snapshot'

	local stage_dir; stage_dir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf -- '${stage_dir}'" RETURN EXIT

	if firephlox_is_dry_run; then
		local excl_note=''
		[[ -n "${FIREPHLOX_REVIVE_EXCLUDE:-}" ]] && excl_note=" (excluded: ${FIREPHLOX_REVIVE_EXCLUDE})"
		[[ -n "${FIREPHLOX_PREFS_ONLY:-}" ]]     && excl_note="${excl_note} (prefs-only: ${FIREPHLOX_PREFS_ONLY})"
		firephlox_info "(dry-run) would stage specimen ${snap_id}"
		firephlox_info "(dry-run) would transplant all viable tissue into active profile${excl_note}"
		return 0
	fi

	_fp_stage_snapshot "${snap_id}" "${stage_dir}"
	local src_profile="${_FP_STAGED_PROFILE}"

	# Check for findings from a prior --triage=<id> run and apply any
	# recommended exclusions that the user has not already overridden.
	local findings_file="${HOME}/.cache/firephlox/triage-${snap_id}.findings"
	if [[ -f "${findings_file}" ]]; then
		firephlox_info "Findings file found from prior --triage=${snap_id}:"
		while IFS=: read -r directive detail; do
			case "${directive}" in
				warn)
					firephlox_warn "  [triage] ${detail}" ;;
				recommend-exclude)
					if _fp_revive_excluded "${detail}"; then
						firephlox_info "  [triage] recommend-exclude:${detail} – already in --exclude, honoured"
					else
						FIREPHLOX_REVIVE_EXCLUDE="${FIREPHLOX_REVIVE_EXCLUDE:+${FIREPHLOX_REVIVE_EXCLUDE},}${detail}"
						firephlox_warn "  [triage] auto-applied recommend-exclude:${detail} – add --exclude=${detail} explicitly to suppress this message"
					fi ;;
			esac
		done < "${findings_file}"
	fi

	# --- Revive 2: Pre-operative assessment ------------------------------
	firephlox_section 'Revive 2 · Pre-operative tissue assessment'

	local viable_count=0 degraded_count=0

	_fp_revive_assess_sqlite() {
		local path="$1" label="$2"
		if [[ ! -f "${path}" ]]; then
			firephlox_info "${label} — absent in specimen"
			return 0
		fi
		local check; check="$(_fp_triage_sqlite_check "${path}")"
		if [[ "${check}" == 'ok' ]]; then
			firephlox_ok "${label} — viable"
			viable_count=$(( viable_count + 1 ))
		else
			firephlox_warn "${label} — ${check}; will be quarantined during transplant"
			degraded_count=$(( degraded_count + 1 ))
		fi
	}

	_fp_revive_assess_sqlite "${src_profile}/permissions.sqlite"      'Site permissions'
	_fp_revive_assess_sqlite "${src_profile}/cookies.sqlite"          'Immunological memory (cookies)'
	_fp_revive_assess_sqlite "${src_profile}/places.sqlite"           'Patient history (bookmarks and navigation)'
	_fp_revive_assess_sqlite "${src_profile}/formhistory.sqlite"      'Autofill tissue samples'
	_fp_revive_assess_sqlite "${src_profile}/favicons.sqlite"         'Iconographic registry'
	_fp_revive_assess_sqlite "${src_profile}/cert9.db"                'Certificate trust matrix'

	local has_credentials='no'
	if [[ -f "${src_profile}/logins.json" && -f "${src_profile}/key4.db" ]]; then
		local cred_check; cred_check="$(_fp_triage_sqlite_check "${src_profile}/key4.db")"
		if [[ "${cred_check}" == 'ok' ]]; then
			firephlox_ok 'Credential pair (logins.json + key4.db) — viable'
			has_credentials='yes'
			viable_count=$(( viable_count + 1 ))
		else
			firephlox_warn "Credential pair — key4.db ${cred_check}; cannot transplant without risking data corruption"
		fi
	else
		firephlox_info 'Credential pair — absent or incomplete in specimen'
	fi

	# Count transplantable extension storage directories.
	local ext_storage_count=0
	local src_storage="${src_profile}/storage/default"
	if [[ -d "${src_storage}" ]]; then
		for d in "${src_storage}"/moz-extension+++*/; do
			[[ -d "${d}" ]] || continue
			[[ "${d}" == *'apple-music-shuffle'* || "${d}" == *'firephlox'* ]] && continue
			ext_storage_count=$(( ext_storage_count + 1 ))
		done
	fi
	[[ "${ext_storage_count}" -gt 0 ]] && \
		firephlox_ok "${ext_storage_count} synaptic relay storage node(s) viable"

	# Count transplantable extension XPIs.
	local xpi_count=0
	if [[ -d "${src_profile}/extensions" ]]; then
		for xpi in "${src_profile}/extensions/"*.xpi; do
			[[ -f "${xpi}" ]] || continue
			[[ "$(basename "${xpi}")" == 'apple-music-shuffle@firephlox.xpi' ]] && continue
			xpi_count=$(( xpi_count + 1 ))
		done
	fi
	[[ "${xpi_count}" -gt 0 ]] && firephlox_ok "${xpi_count} extension file(s) viable"

	# Check prefs.js.
	local has_prefs='no'
	if [[ -f "${src_profile}/prefs.js" ]]; then
		local pref_count; pref_count="$(grep -c 'user_pref(' "${src_profile}/prefs.js" 2>/dev/null || printf '0')"
		firephlox_ok "Neural pathway map (prefs.js) — ${pref_count} pathways to screen"
		has_prefs='yes'
		# Note any flagged prefs.
		local rp_val; rp_val="$(_fp_triage_pref "${src_profile}/prefs.js" 'privacy.resistFingerprinting')"
		[[ "${rp_val}" == 'true' ]] && \
			firephlox_warn 'privacy.resistFingerprinting = true in specimen — this pathway will be quarantined during transplant.'
	else
		firephlox_info 'prefs.js — absent in specimen'
	fi

	printf '\n'
	firephlox_info "Assessment complete: ${viable_count} viable tissue type(s), ${degraded_count} degraded."

	# --- Revive 3: Recipient selection -----------------------------------
	firephlox_section 'Revive 3 · Recipient selection'

	local -a dst_profiles
	mapfile -t dst_profiles < <(firephlox_discover_profiles)
	[[ ${#dst_profiles[@]} -gt 0 ]] || \
		firephlox_die 'No active Firefox profile found. Launch Firefox once to initialise a profile, then re-run.'
	local dst_profile="${dst_profiles[0]}"

	local recipient_mode
	if [[ "${FIREPHLOX_FRESH:-0}" == '1' ]]; then
		recipient_mode='fresh'
	elif [[ "${FIREPHLOX_ASSUME_YES:-0}" == '1' ]]; then
		recipient_mode='active'
	else
		printf '\n'
		printf '%s[ .. ]%s  [1] Active profile  — graft donor settings into the living host as-is\n' "${FP_BLUE}" "${FP_RESET}"
		printf '%s[ .. ]%s  [2] Fresh clone     — archive the host, cultivate a sterile new profile, then transplant\n' "${FP_BLUE}" "${FP_RESET}"
		printf '%s[ .. ]%s  [q] Abort\n' "${FP_BLUE}" "${FP_RESET}"
		printf '\n'
		local choice=''
		while [[ "${choice}" != '1' && "${choice}" != '2' && "${choice}" != 'q' ]]; do
			read -r -p "  Recipient [1/2/q]: " choice
		done
		case "${choice}" in
			1) recipient_mode='active' ;;
			2) recipient_mode='fresh' ;;
			q) firephlox_warn 'Salvage protocol aborted.'; return 0 ;;
		esac
	fi

	firephlox_info "Host: ${dst_profile}"

	if [[ "${recipient_mode}" == 'fresh' ]]; then
		_fp_revive_prepare_clone "${dst_profile}"
	fi

	# --- Revive 4: Surgical transplant -----------------------------------
	firephlox_section 'Revive 4 · Surgical transplant'

	[[ -n "${FIREPHLOX_REVIVE_EXCLUDE:-}" ]] && \
		firephlox_warn "Excluded from transplant: ${FIREPHLOX_REVIVE_EXCLUDE}"

	# 3A — SQLite databases
	if ! _fp_revive_excluded 'sqlite'; then
		firephlox_info 'Cellular databases…'
		_fp_revive_xplant_sqlite "${src_profile}/permissions.sqlite" "${dst_profile}/permissions.sqlite" \
			'Site permissions'
		_fp_revive_xplant_sqlite "${src_profile}/cookies.sqlite" "${dst_profile}/cookies.sqlite" \
			'Immunological memory (cookies)'
		_fp_revive_xplant_sqlite "${src_profile}/places.sqlite" "${dst_profile}/places.sqlite" \
			'Patient history (bookmarks and navigation)'
		_fp_revive_xplant_sqlite "${src_profile}/formhistory.sqlite" "${dst_profile}/formhistory.sqlite" \
			'Autofill tissue samples'
		_fp_revive_xplant_sqlite "${src_profile}/favicons.sqlite" "${dst_profile}/favicons.sqlite" \
			'Iconographic registry'
		_fp_revive_xplant_sqlite "${src_profile}/cert9.db" "${dst_profile}/cert9.db" \
			'Certificate trust matrix'
	else
		firephlox_info 'Cellular databases — excluded'
	fi

	# 3B — Credential pair (must travel together)
	if ! _fp_revive_excluded 'credentials'; then
		if [[ "${has_credentials}" == 'yes' ]]; then
			firephlox_info 'Credential pair…'
			_fp_revive_xplant_file "${src_profile}/logins.json" "${dst_profile}/logins.json" \
				'Credentials archive (logins.json)'
			_fp_revive_xplant_file "${src_profile}/key4.db" "${dst_profile}/key4.db" \
				'Encryption matrix (key4.db)'
		fi
	else
		firephlox_info 'Credential pair — excluded'
	fi

	# 3C — Configuration files
	if ! _fp_revive_excluded 'config'; then
		firephlox_info 'Configuration files…'
		_fp_revive_xplant_file "${src_profile}/containers.json" \
			"${dst_profile}/containers.json" 'Containment protocols'
		_fp_revive_xplant_file "${src_profile}/search.json.mozlz4" \
			"${dst_profile}/search.json.mozlz4" 'Sensor array (search engines)'
		_fp_revive_xplant_file "${src_profile}/extension-preferences.json" \
			"${dst_profile}/extension-preferences.json" 'Implant preference matrix'
		_fp_revive_xplant_file "${src_profile}/extension-settings.json" \
			"${dst_profile}/extension-settings.json" 'Implant settings database'
		_fp_revive_xplant_file "${src_profile}/extensions.json" \
			"${dst_profile}/extensions.json" 'Implant registry'
	else
		firephlox_info 'Configuration files — excluded'
	fi

	# 3D/E — Extension XPI files, registry and synaptic relay storage
	if ! _fp_revive_excluded 'extensions'; then
		if [[ "${xpi_count}" -gt 0 ]]; then
			firephlox_info 'Extension files…'
			local xpi xpi_name
			for xpi in "${src_profile}/extensions/"*.xpi; do
				[[ -f "${xpi}" ]] || continue
				xpi_name="$(basename "${xpi}")"
				if [[ "${xpi_name}" == 'apple-music-shuffle@firephlox.xpi' ]]; then
					firephlox_info "Quarantined own implant: ${xpi_name}"
					continue
				fi
				_fp_revive_xplant_file "${xpi}" "${dst_profile}/extensions/${xpi_name}" \
					"Extension: ${xpi_name}"
			done
		fi

		if [[ "${ext_storage_count}" -gt 0 ]]; then
			firephlox_info 'Synaptic relay storage (extension data, uBlock rules, etc.)…'
			local dst_storage="${dst_profile}/storage/default"
			mkdir -p "${dst_storage}"
			local d dname
			for d in "${src_storage}"/moz-extension+++*/; do
				[[ -d "${d}" ]] || continue
				dname="$(basename "${d}")"
				if [[ "${dname}" == *'apple-music-shuffle'* || "${dname}" == *'firephlox'* ]]; then
					firephlox_info "Quarantined own synaptic node: ${dname}"
					continue
				fi
				cp -r "${d}" "${dst_storage}/"
				firephlox_ok "Synaptic relay → ${dname}"
			done
			if [[ -d "${src_profile}/browser-extension-data" ]]; then
				cp -r "${src_profile}/browser-extension-data" "${dst_profile}/"
				firephlox_ok 'Legacy relay storage → transplanted'
			fi
		fi
	else
		firephlox_info 'Extension files and synaptic relay storage — excluded'
	fi

	# 3F — Neural pathway configuration (selected prefs → user.js)
	if ! _fp_revive_excluded 'prefs' || [[ -n "${FIREPHLOX_PREFS_ONLY:-}" ]]; then
		if [[ "${has_prefs}" == 'yes' ]]; then
			firephlox_info 'Neural pathway configuration (preferences)…'
			_fp_revive_xplant_prefs "${src_profile}/prefs.js" "${dst_profile}/user.js"
		fi
	else
		firephlox_info 'Neural pathway configuration — excluded'
	fi

	printf '\n'
	firephlox_ok "The graft has taken. Prognosis: excellent."
	firephlox_info 'The source specimen was not disturbed.'
	firephlox_info 'Remove user.js from the profile to revert transplanted preferences if issues arise.'
	firephlox_info 'Restart Firefox to begin recovery.'
}

# _fp_stage_snapshot <snap_id> <stage_dir>
# Locates, copies, and fully unpacks a snap data snapshot into stage_dir.
# Sets _FP_STAGED_PROFILE to the absolute path of the Firefox profile found
# inside the staged data. Called by both firephlox_triage and firephlox_revive.
_fp_stage_snapshot() {
	local snap_id="$1" stage_dir="$2"

	firephlox_info "Locating specimen ${snap_id}…"
	local zip_file; zip_file="$(_fp_revive_find_zip "${snap_id}")"
	[[ -n "${zip_file}" ]] || \
		firephlox_die "Specimen ${snap_id} not found in the snapd vault. Run: snap saved firefox"

	local zip_size
	zip_size="$(firephlox_privileged du -h "${zip_file}" 2>/dev/null | cut -f1 || true)"
	firephlox_ok "Specimen (${zip_size}): ${zip_file}"

	local tmp_zip; tmp_zip="$(mktemp --suffix=.zip)"
	# shellcheck disable=SC2064
	trap "rm -f -- '${tmp_zip}'" RETURN

	firephlox_info 'Staging specimen (this may take a moment)…'
	if firephlox_path_writable "${zip_file}"; then
		cp "${zip_file}" "${tmp_zip}"
	else
		firephlox_privileged cp "${zip_file}" "${tmp_zip}"
		firephlox_privileged chown "$(id -u):$(id -g)" "${tmp_zip}"
	fi

	firephlox_info 'Inspecting specimen structure…'
	python3 - "${tmp_zip}" "${stage_dir}" <<'PYTHON'
import sys, os, zipfile, tarfile, warnings
warnings.filterwarnings('ignore')

tmp_zip, stage_dir = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(tmp_zip, 'r') as z:
    for n in z.namelist()[:12]:
        print(f'  zip: {n}', flush=True)
    z.extractall(stage_dir)

def unpack(tar_path):
    base = tar_path
    for ext in ('.tar.gz', '.tgz', '.tar'):
        if base.endswith(ext):
            base = base[:-len(ext)]
            break
    os.makedirs(base, exist_ok=True)
    skipped = 0
    try:
        with tarfile.open(tar_path, 'r:*') as t:
            for member in t.getmembers():
                if (member.issym() or member.islnk()) and os.path.isabs(member.linkname):
                    skipped += 1
                    continue
                try:
                    t.extract(member, base)
                except Exception:
                    skipped += 1
    except Exception as e:
        print(f'  warn: cannot read {os.path.basename(tar_path)}: {e}', flush=True)
        return
    if skipped:
        print(f'  info: {os.path.basename(tar_path)}: {skipped} unsafe symlink(s) skipped', flush=True)

for root, _dirs, files in os.walk(stage_dir):
    for fname in sorted(files):
        if any(fname.endswith(ext) for ext in ('.tar.gz', '.tgz', '.tar')):
            unpack(os.path.join(root, fname))
PYTHON
	rm -f "${tmp_zip}"
	chmod -R u+rX "${stage_dir}" 2>/dev/null || true
	firephlox_ok 'Specimen staged and unpacked.'

	local src_perms
	src_perms="$(_fp_revive_find_in_stage "${stage_dir}" 'permissions.sqlite')"
	if [[ -z "${src_perms}" ]]; then
		firephlox_warn 'Could not find permissions.sqlite — first 10 paths in staged specimen:'
		find "${stage_dir}" -maxdepth 5 2>/dev/null | head -10 | \
			while IFS= read -r p; do firephlox_info "  ${p#"${stage_dir}"/}"; done || true
		firephlox_die 'Could not locate a Firefox profile inside this specimen.'
	fi
	_FP_STAGED_PROFILE="$(dirname "${src_perms}")"
	firephlox_ok "Firefox profile located in specimen: $(basename "${_FP_STAGED_PROFILE}")"
}

# Returns 0 (true) when the given category is listed in FIREPHLOX_REVIVE_EXCLUDE.
_fp_revive_excluded() {
	local category="$1" c
	local IFS=','
	for c in ${FIREPHLOX_REVIVE_EXCLUDE:-}; do
		[[ "${c}" == "${category}" ]] && return 0
	done
	return 1
}

# Archives the current profile and leaves the directory empty in place.
# Firefox re-initialises all missing files on the next launch; profiles.ini
# is untouched because the directory itself remains.
_fp_revive_prepare_clone() {
	local dst_profile="$1"
	firephlox_section 'Revive 3B · Preparing the clone — sterilising the recipient site'
	local backup="${dst_profile}.pre-revive-$(date +%Y%m%d%H%M%S)"
	mkdir -p "${backup}"
	local entry moved=0
	while IFS= read -r -d '' entry; do
		mv "${entry}" "${backup}/" 2>/dev/null && moved=$(( moved + 1 )) || true
	done < <(find "${dst_profile}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	firephlox_ok "${moved} item(s) archived to: $(basename "${backup}")"
	firephlox_info 'A clean cultivation always improves the prognosis.'
}

# Locates the snapshot ZIP for a given ID in the snapd vault.
# Lists the vault directory rather than glob-expanding inside it — bash
# cannot expand a glob inside a root-owned directory, which would cause
# the literal unexpanded pattern to be passed through even with sudo.
# Uses if/fi (not [[ ]] &&) so the function always exits 0 and set -e
# does not trigger when no match is found.
_fp_revive_find_zip() {
	local snap_id="$1"
	local vault='/var/lib/snapd/snapshots'
	local listing name
	listing="$(ls -1 "${vault}/" 2>/dev/null || firephlox_privileged ls -1 "${vault}/" 2>/dev/null || true)"
	name="$(printf '%s\n' "${listing}" | grep -m1 "^${snap_id}_" || true)"
	if [[ -n "${name}" ]]; then
		printf '%s/%s' "${vault}" "${name}"
	fi
}

# Finds a named file inside the staged snapshot. No path filter needed —
# this tool only handles Firefox snapshots, so any match is the right file.
_fp_revive_find_in_stage() {
	local stage_dir="$1" filename="$2"
	find "${stage_dir}" -name "${filename}" 2>/dev/null | head -1 || true
}

# Copies a SQLite database after an integrity check; skips degraded tissue.
# Also copies WAL journal files if present.
_fp_revive_xplant_sqlite() {
	local src="$1" dst="$2" label="$3"
	if [[ ! -f "${src}" ]]; then
		firephlox_info "${label} — absent in specimen, skipping"
		return 0
	fi
	local check; check="$(_fp_triage_sqlite_check "${src}")"
	if [[ "${check}" != 'ok' ]]; then
		firephlox_warn "${label} — ${check}; quarantined"
		return 0
	fi
	mkdir -p "$(dirname "${dst}")"
	cp "${src}" "${dst}"
	[[ -f "${src}-wal" ]] && cp "${src}-wal" "${dst}-wal"
	[[ -f "${src}-shm" ]] && cp "${src}-shm" "${dst}-shm"
	firephlox_ok "${label} → transplanted"
}

# Copies a single file if it is present in the specimen.
_fp_revive_xplant_file() {
	local src="$1" dst="$2" label="$3"
	if [[ ! -f "${src}" ]]; then
		firephlox_info "${label} — absent in specimen, skipping"
		return 0
	fi
	mkdir -p "$(dirname "${dst}")"
	cp "${src}" "${dst}"
	firephlox_ok "${label} → transplanted"
}

# Transplants selected preferences from prefs.js into the destination user.js.
# Excluded: firephlox-managed prefs, known-problematic prefs, telemetry,
# sync credentials, and any value referencing a filesystem path.
_fp_revive_xplant_prefs() {
	local src_prefs="$1" dst_userjs="$2"
	local count
	count="$(FIREPHLOX_PREFS_ONLY="${FIREPHLOX_PREFS_ONLY:-}" python3 - "${src_prefs}" "${dst_userjs}" <<'PYTHON'
import re, sys, os, time

src, dst = sys.argv[1], sys.argv[2]

# --prefs-only whitelist (overrides the exclusion list when set)
prefs_only_raw = os.environ.get('FIREPHLOX_PREFS_ONLY', '').strip()
prefs_only = tuple(p.strip() for p in prefs_only_raw.split(',') if p.strip()) if prefs_only_raw else ()

EXCLUDED_PREFIXES = (
    'datareporting.',
    'toolkit.telemetry.',
    'browser.sessionstore.',
    'browser.cache.',
    'services.sync.',
    'media.hardware-video-decoding',
    'media.ffmpeg.vaapi',
    'media.gmp-',
    'layers.acceleration.disabled',
    'xpinstall.signatures.required',
    'toolkit.startup.',
    'distribution.',
    'identity.fxaccounts.account.device.',
)
EXCLUDED_EXACT = frozenset({
    'privacy.resistFingerprinting',
})
# Firephlox-locked values – zeroed UUIDs, redirected servers, etc.
# Never transplant these; they would re-lock values in the destination
# and require another restore cycle to undo.
FIREPHLOX_LOCKED = {
    'toolkit.telemetry.cachedClientID':                       '"00000000-0000-0000-0000-000000000000"',
    'browser.newtabpage.activity-stream.impressionId':         '"{}"',
    'toolkit.telemetry.server':                                '"http://127.0.0.1"',
    'toolkit.telemetry.unified':                               'false',
}
# Skip values that contain filesystem paths — they are profile-specific.
PATH_RE = re.compile(r'["\x27](?:/home/|file://|/snap/|/tmp/|/root/)')
PREF_RE = re.compile(r'^user_pref\("([^"]+)",\s*(.*)\);')

lines = []
with open(src) as f:
    for raw in f:
        m = PREF_RE.match(raw.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if prefs_only:
            # Whitelist mode: only transplant prefs matching a given namespace.
            if not any(key.startswith(p) for p in prefs_only):
                continue
        else:
            if any(key.startswith(p) for p in EXCLUDED_PREFIXES):
                continue
            if key in EXCLUDED_EXACT:
                continue
            if key in FIREPHLOX_LOCKED and val == FIREPHLOX_LOCKED[key]:
                continue  # zeroed/redirected by firephlox policy – let Firefox regenerate
        if PATH_RE.search(val):
            continue
        lines.append(f'user_pref("{key}", {val});')

with open(dst, 'w') as f:
    f.write('// Neural pathway configuration transplanted by firephlox --revive.\n')
    f.write('// Remove this file to revert to Firefox defaults.\n')
    f.write('\n'.join(lines) + '\n')

print(len(lines))
PYTHON
)"
	firephlox_ok "Neural pathways → ${count} preferences transplanted to user.js"
}
