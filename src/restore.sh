# shellcheck shell=bash
# 08_restore.sh — Task R: undo all firephlox changes.
#
# Removes every artefact written by Tasks 1, 2 and 4:
#   · /etc/firefox/policies/policies.json (and the directory if now empty)
#   · /var/snap/firefox/common/distribution/policies.json
#   · firephlox managed block from every profile's user.js
#     (file removed when nothing else remains inside it)
#   · apple-music-shuffle@firephlox.xpi from ~/snap/firefox/common/extensions/
#   · apple-music-shuffle@firephlox.xpi from /var/snap/firefox/common/distribution/extensions/
#   · apple-music-shuffle@firephlox.xpi from every profile's extensions/ directory
#   · ~/.cache/firephlox/ (signed XPI cache from Task 5) if present
#
# Task 3 (cache purge) removes directories that Firefox recreates on the next
# launch — there is nothing meaningful to restore there.

firephlox_restore() {
	firephlox_section 'Restore · Undo all firephlox changes'

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it completely and re-run.'
	fi
	firephlox_ok 'Firefox is not running.'

	if ! firephlox_confirm 'Remove all firephlox changes from this system?'; then
		firephlox_warn 'Restore cancelled.'
		return 0
	fi

	local ext_id='apple-music-shuffle@firephlox'

	# Discover profiles once; reused by Tasks 2 and 4 reversal.
	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)

	# --- Reverse Task 1: policy files ------------------------------------
	firephlox_section 'Restore 1 · Enterprise policy files'

	_fp_restore_rm "${FIREPHLOX_ETC_POLICIES_FILE}"
	_fp_restore_rmdir_if_empty "${FIREPHLOX_ETC_POLICIES_DIR}"
	_fp_restore_rm "${FIREPHLOX_SNAP_POLICIES_FILE}"

	# --- Reverse Task 2: user.js managed block ---------------------------
	firephlox_section 'Restore 2 · Profile user.js'

	if [[ ${#profiles[@]} -eq 0 ]]; then
		firephlox_warn 'No Firefox profiles found; user.js step skipped.'
	else
		local begin='// >>> firephlox managed block >>>'
		local end='// <<< firephlox managed block <<<'
		local profile userjs tmp

		for profile in "${profiles[@]}"; do
			userjs="${profile}/user.js"
			if [[ ! -f "${userjs}" ]]; then
				firephlox_info "No user.js in ${profile}; skipping."
				continue
			fi
			if ! grep -q 'firephlox managed block' "${userjs}" 2>/dev/null; then
				firephlox_info "No managed block in ${userjs}; skipping."
				continue
			fi
			if firephlox_is_dry_run; then
				firephlox_info "(dry-run) strip managed block from ${userjs}"
				continue
			fi
			tmp="$(mktemp)"
			awk -v b="${begin}" -v e="${end}" '
				$0==b {skip=1}
				skip && $0==e {skip=0; next}
				!skip {print}
			' "${userjs}" > "${tmp}"
			if ! grep -q '[^[:space:]]' "${tmp}"; then
				rm -f "${tmp}" "${userjs}"
				firephlox_ok "user.js removed (empty after block removal): ${userjs}"
			else
				install -m 0644 "${tmp}" "${userjs}"
				rm -f "${tmp}"
				firephlox_ok "Managed block stripped: ${userjs}"
			fi
		done
	fi

	# --- Reverse Task 4: extension XPI files -----------------------------
	firephlox_section 'Restore 4 · Extension XPI files'

	_fp_restore_rm "${HOME}/snap/firefox/common/extensions/${ext_id}.xpi"

	local dist_ext="${FIREPHLOX_DISTRIBUTION_DIR}/extensions"
	_fp_restore_rm "${dist_ext}/${ext_id}.xpi"
	_fp_restore_rmdir_if_empty "${dist_ext}"

	local profile
	for profile in "${profiles[@]}"; do
		_fp_restore_rm "${profile}/extensions/${ext_id}.xpi"
		_fp_restore_rmdir_if_empty "${profile}/extensions"
	done

	# --- Signed XPI cache (Task 5) ---------------------------------------
	local cache_dir="${FIREPHLOX_SIGNED_XPI_CACHE:-${HOME}/.cache/firephlox}"
	if [[ -d "${cache_dir}" ]]; then
		firephlox_section 'Restore 5 · Signed XPI cache'
		if firephlox_is_dry_run; then
			firephlox_info "(dry-run) rm -rf ${cache_dir}"
		else
			rm -rf -- "${cache_dir}"
			firephlox_ok "Signed XPI cache removed: ${cache_dir}"
		fi
	fi

	# --- Restore 6: Scrub firephlox-managed pref values from prefs.js ---
	firephlox_section 'Restore 6 · Scrubbing firephlox-managed pref values'

	local profile
	for profile in "${profiles[@]}"; do
		local prefs="${profile}/prefs.js"
		[[ -f "${prefs}" ]] || { firephlox_info "No prefs.js in ${profile}"; continue; }
		if firephlox_is_dry_run; then
			firephlox_info "(dry-run) would scrub managed pref values from ${prefs}"
			continue
		fi
		local scrubbed
		scrubbed="$(python3 - "${prefs}" <<'PYTHON'
import re, sys, os, shutil

MANAGED = {
    'toolkit.telemetry.cachedClientID':                      '"00000000-0000-0000-0000-000000000000"',
    'browser.newtabpage.activity-stream.impressionId':        '"{}"',
    'toolkit.telemetry.server':                               '"http://127.0.0.1"',
    'toolkit.telemetry.unified':                              'false',
    'datareporting.policy.dataSubmissionPolicyAcceptedVersion': '0',
    'datareporting.healthreport.uploadEnabled':               'false',
    'datareporting.usage.uploadEnabled':                      'false',
    'xpinstall.signatures.required':                          'false',
    'layers.acceleration.disabled':                           'false',
}
pref_re = re.compile(r'^user_pref\("([^"]+)",\s*(.*)\);')
kept, removed = [], []
with open(sys.argv[1]) as f:
    for line in f:
        m = pref_re.match(line.strip())
        if m and m.group(1) in MANAGED and m.group(2) == MANAGED[m.group(1)]:
            removed.append(m.group(1))
        else:
            kept.append(line)

tmp = sys.argv[1] + '.tmp'
with open(tmp, 'w') as f:
    f.writelines(kept)
os.replace(tmp, sys.argv[1])
for k in removed:
    print(k)
PYTHON
)"
		if [[ -n "${scrubbed}" ]]; then
			printf '%s\n' "${scrubbed}" | while IFS= read -r key; do
				firephlox_ok "Scrubbed managed remnant: ${key}"
			done
		else
			firephlox_info "No managed remnants in ${prefs}"
		fi
	done

	printf '\n'
	firephlox_ok 'Restore complete. Firefox has been returned to its default state.'
	firephlox_info 'Note: purged telemetry caches (Task 3) are recreated by Firefox on the next launch.'
	firephlox_info 'Restart Firefox to apply the restored state.'
}

# firephlox_restore_specimen – run restore cleanup on a staged snapshot.
# Used by --restore=<id>: stages specimen <id> and reports which
# firephlox-managed pref values are present in its prefs.js.
firephlox_restore_specimen() {
	local snap_id="${FIREPHLOX_RESTORE_SNAPSHOT}"
	firephlox_section "Restore · Inspecting specimen ${snap_id} for firephlox remnants"

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it before inspecting a snapshot.'
	fi

	local stage_dir; stage_dir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf -- '${stage_dir}'" RETURN EXIT
	_fp_stage_snapshot "${snap_id}" "${stage_dir}"

	local staged_prefs="${_FP_STAGED_PROFILE}/prefs.js"
	if [[ ! -f "${staged_prefs}" ]]; then
		firephlox_warn 'No prefs.js found in this specimen.'
		return 0
	fi

	firephlox_section 'Restore · Firephlox-managed pref values present in specimen'
	_fp_restore_report_managed_prefs "${staged_prefs}"
	firephlox_info 'Run --revive=<id> to transplant from this specimen; managed values are scrubbed automatically during pref transplant.'
}

# Reports which firephlox-managed pref values are present in a prefs.js.
# Used both by firephlox_restore_specimen and firephlox_restore (active profile).
_fp_restore_report_managed_prefs() {
	local prefs_file="$1"
	python3 - "${prefs_file}" <<'PYTHON'
import re, sys
MANAGED = {
    'toolkit.telemetry.cachedClientID':                      '"00000000-0000-0000-0000-000000000000"',
    'browser.newtabpage.activity-stream.impressionId':        '"{}"',
    'toolkit.telemetry.server':                               '"http://127.0.0.1"',
    'toolkit.telemetry.unified':                              'false',
    'datareporting.policy.dataSubmissionPolicyAcceptedVersion': '0',
    'datareporting.healthreport.uploadEnabled':               'false',
    'datareporting.usage.uploadEnabled':                      'false',
    'xpinstall.signatures.required':                          'false',
    'layers.acceleration.disabled':                           'false',
}
pref_re = re.compile(r'^user_pref\("([^"]+)",\s*(.*)\);')
found = []
with open(sys.argv[1]) as f:
    for line in f:
        m = pref_re.match(line.strip())
        if m and m.group(1) in MANAGED and m.group(2) == MANAGED[m.group(1)]:
            found.append(m.group(1))
if found:
    for k in found:
        print(f'  remnant: {k}')
    sys.exit(1)
sys.exit(0)
PYTHON
	local rc=$?
	if [[ "${rc}" -eq 0 ]]; then
		firephlox_ok 'No firephlox-managed remnant values detected in prefs.js.'
	fi
}

_fp_restore_rm() {
	local path="$1"
	if [[ ! -e "${path}" ]]; then
		firephlox_info "Already absent: ${path}"
		return 0
	fi
	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) rm ${path}"
		return 0
	fi
	if firephlox_path_writable "${path}"; then
		rm -f -- "${path}"
	else
		firephlox_privileged rm -f -- "${path}"
	fi
	firephlox_ok "Removed: ${path}"
}

_fp_restore_rmdir_if_empty() {
	local dir="$1"
	[[ -d "${dir}" ]] || return 0
	if [[ -z "$(ls -A "${dir}" 2>/dev/null)" ]]; then
		if firephlox_is_dry_run; then
			firephlox_info "(dry-run) rmdir ${dir} (empty)"
			return 0
		fi
		if firephlox_path_writable "${dir}"; then
			rmdir -- "${dir}"
		else
			firephlox_privileged rmdir -- "${dir}"
		fi
		firephlox_ok "Removed empty directory: ${dir}"
	else
		firephlox_info "Directory not empty, left in place: ${dir}"
	fi
}
