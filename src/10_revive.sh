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

	firephlox_info "Locating specimen ${snap_id}…"
	local zip_file
	zip_file="$(_fp_revive_find_zip "${snap_id}")"
	[[ -n "${zip_file}" ]] || \
		firephlox_die "Specimen ${snap_id} not found in the snapd vault. Run: snap saved firefox"

	local zip_size
	zip_size="$(firephlox_privileged du -h "${zip_file}" 2>/dev/null | cut -f1 || true)"
	firephlox_ok "Specimen located (${zip_size}): ${zip_file}"

	local stage_dir tmp_zip
	stage_dir="$(mktemp -d)"
	tmp_zip="$(mktemp --suffix=.zip)"
	# shellcheck disable=SC2064
	trap "rm -f -- '${tmp_zip}'; rm -rf -- '${stage_dir}'" RETURN EXIT

	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) would stage and dissect ${zip_file}"
		firephlox_info "(dry-run) would transplant all viable tissue into active profile"
		return 0
	fi

	firephlox_info 'Staging specimen (this may take a moment)…'
	if firephlox_path_writable "${zip_file}"; then
		cp "${zip_file}" "${tmp_zip}"
	else
		firephlox_privileged cp "${zip_file}" "${tmp_zip}"
		firephlox_privileged chown "$(id -u):$(id -g)" "${tmp_zip}"
	fi

	python3 - "${tmp_zip}" "${stage_dir}" <<'PYTHON'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'r') as z:
    z.extractall(sys.argv[2])
PYTHON
	rm -f "${tmp_zip}"
	firephlox_ok 'Specimen staged.'

	# Locate the Firefox profile inside the extracted snapshot.
	local src_perms
	src_perms="$(_fp_revive_find_in_stage "${stage_dir}" 'permissions.sqlite')"
	[[ -n "${src_perms}" ]] || \
		firephlox_die 'Could not locate a Firefox profile inside this specimen. Is it a Firefox snapshot?'

	local src_profile; src_profile="$(dirname "${src_perms}")"
	firephlox_ok "Firefox profile located in specimen: $(basename "${src_profile}")"

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

	# --- Confirm ---------------------------------------------------------
	if ! firephlox_confirm 'Proceed with surgical transplant into the active profile?'; then
		firephlox_warn 'Salvage protocol aborted.'
		return 0
	fi

	# Locate the active (destination) profile.
	local -a dst_profiles
	mapfile -t dst_profiles < <(firephlox_discover_profiles)
	[[ ${#dst_profiles[@]} -gt 0 ]] || firephlox_die 'No active profile found to receive the transplant.'
	local dst_profile="${dst_profiles[0]}"
	firephlox_info "Recipient: ${dst_profile}"

	# --- Revive 3: Surgical transplant -----------------------------------
	firephlox_section 'Revive 3 · Surgical transplant'

	# 3A — SQLite databases
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

	# 3B — Credential pair (must travel together)
	if [[ "${has_credentials}" == 'yes' ]]; then
		firephlox_info 'Credential pair…'
		_fp_revive_xplant_file "${src_profile}/logins.json" "${dst_profile}/logins.json" \
			'Credentials archive (logins.json)'
		_fp_revive_xplant_file "${src_profile}/key4.db" "${dst_profile}/key4.db" \
			'Encryption matrix (key4.db)'
	fi

	# 3C — Configuration files
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

	# 3D — Extension XPI files (excluding firephlox's own implant)
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

	# 3E — Extension synaptic relay storage (IndexedDB)
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
		# Legacy storage path.
		if [[ -d "${src_profile}/browser-extension-data" ]]; then
			cp -r "${src_profile}/browser-extension-data" "${dst_profile}/"
			firephlox_ok 'Legacy relay storage → transplanted'
		fi
	fi

	# 3F — Neural pathway configuration (selected prefs → user.js)
	if [[ "${has_prefs}" == 'yes' ]]; then
		firephlox_info 'Neural pathway configuration (preferences)…'
		_fp_revive_xplant_prefs "${src_profile}/prefs.js" "${dst_profile}/user.js"
	fi

	printf '\n'
	firephlox_ok "The graft has taken. Prognosis: excellent."
	firephlox_info 'The source specimen was not disturbed.'
	firephlox_info 'Remove user.js from the profile to revert transplanted preferences if issues arise.'
	firephlox_info 'Restart Firefox to begin recovery.'
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

# Finds a named file inside the staged snapshot, constrained to firefox paths.
_fp_revive_find_in_stage() {
	local stage_dir="$1" filename="$2"
	find "${stage_dir}" -name "${filename}" -path '*firefox*' 2>/dev/null | head -1
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
	count="$(python3 - "${src_prefs}" "${dst_userjs}" <<'PYTHON'
import re, sys, time

src, dst = sys.argv[1], sys.argv[2]

EXCLUDED_PREFIXES = (
    'datareporting.',
    'toolkit.telemetry.',
    'browser.sessionstore.',
    'browser.cache.',
    'services.sync.',
    'media.hardware-video-decoding',
    'media.ffmpeg.vaapi',
    'layers.acceleration.disabled',
    'xpinstall.signatures.required',
    'toolkit.startup.',
)
EXCLUDED_EXACT = frozenset({
    'privacy.resistFingerprinting',
})
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
        if any(key.startswith(p) for p in EXCLUDED_PREFIXES):
            continue
        if key in EXCLUDED_EXACT:
            continue
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
