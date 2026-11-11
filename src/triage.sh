# shellcheck shell=bash
# 09_triage.sh — Task T: non-destructive profile diagnostics.
#
#   "Before I can treat the patient, I need to know what I'm dealing with."
#       — Dr. Phlox
#
# Without a snapshot ID: inspects the active Firefox profile.
# With --triage=<id>:    stages the named snap data snapshot and triages it.
#
# Shared helpers (_fp_triage_sqlite_check, _fp_triage_pref) are also called
# by 10_revive.sh, which is sourced after this module.

firephlox_triage() {
	local snap_id="${FIREPHLOX_TRIAGE_SNAPSHOT:-}"
	local profile

	if [[ -n "${snap_id}" ]]; then
		# Snapshot triage – stage the specimen first.
		firephlox_section "Triage · Staging specimen ${snap_id} for examination"
		if firephlox_firefox_running; then
			firephlox_die 'Firefox is currently running. Close it before triaging a snapshot.'
		fi
		local stage_dir; stage_dir="$(mktemp -d)"
		# shellcheck disable=SC2064
		trap "rm -rf -- '${stage_dir}'" RETURN EXIT
		_fp_stage_snapshot "${snap_id}" "${stage_dir}"
		profile="${_FP_STAGED_PROFILE}"
	else
		# Active-profile triage.
		firephlox_section 'Triage · Initiating diagnostic cycle'
		if firephlox_firefox_running; then
			firephlox_die 'Firefox is currently running. The patient must be sedated (closed) before examination.'
		fi
		local -a profiles
		mapfile -t profiles < <(firephlox_discover_profiles)
		[[ ${#profiles[@]} -gt 0 ]] || \
			firephlox_die 'No profiles found. Has the patient passed consultation (Firefox launched) at least once?'
		profile="$(
			for p in "${profiles[@]}"; do
				printf '%s %s\n' "$(stat -c '%Y' "${p}" 2>/dev/null || printf '0')" "${p}"
			done | sort -rn | head -1 | cut -d' ' -f2-
		)"
	fi

	firephlox_info "Patient: ${profile}"
	printf '\n'

	# --- Check 1: Vital signs — version compatibility -------------------
	firephlox_section 'Triage 1 · Vital signs — version compatibility'
	local compat_ini="${profile}/compatibility.ini"
	if [[ -f "${compat_ini}" ]]; then
		local last_ver snap_ver
		last_ver="$(awk -F= '/^LastVersion=/{print $2}' "${compat_ini}")"
		snap_ver="$(snap list firefox 2>/dev/null | awk 'NR==2{print $2}')"
		firephlox_ok  "Profile last seen by: Firefox ${last_ver}"
		[[ -n "${snap_ver}" ]] && firephlox_info "Current snap version:  Firefox ${snap_ver}"
		# Compare only the major version number (strip build suffix).
		local lv_major sv_major
		lv_major="${last_ver%%[._]*}"
		sv_major="${snap_ver%%[._-]*}"
		if [[ -n "${sv_major}" && "${lv_major}" != "${sv_major}" ]]; then
			firephlox_warn "Major version mismatch – profile last written by ${last_ver}, snap is ${snap_ver}. A failed first-launch migration may have caused the presenting symptoms."
		fi
	else
		firephlox_warn 'compatibility.ini absent — profile has never been activated or was excised.'
	fi

	# --- Check 2: Cellular integrity — core database scan ---------------
	firephlox_section 'Triage 2 · Cellular integrity — core database scan'
	local -a dbs=(permissions.sqlite cookies.sqlite places.sqlite
	               formhistory.sqlite storage.sqlite favicons.sqlite)
	local db result
	for db in "${dbs[@]}"; do
		local path="${profile}/${db}"
		if [[ ! -f "${path}" ]]; then
			firephlox_info "${db} — not yet grown (normal on a fresh profile)"
			continue
		fi
		result="$(_fp_triage_sqlite_check "${path}")"
		if [[ "${result}" == 'ok' ]]; then
			firephlox_ok   "${db} — cellular structure intact"
		else
			firephlox_error "${db} — ${result}"
		fi
	done

	# --- Check 3: Neural pathway analysis — preferences -----------------
	firephlox_section 'Triage 3 · Neural pathway analysis — preferences'
	local prefs="${profile}/prefs.js"
	if [[ ! -f "${prefs}" ]]; then
		firephlox_warn 'prefs.js absent — the neural pathways have not been mapped.'
	else
		local entry_count dup_count
		entry_count="$(grep -c 'user_pref(' "${prefs}" 2>/dev/null || printf '0')"
		dup_count="$(awk -F'"' '/^user_pref\(/{print $2}' "${prefs}" | sort | uniq -d | wc -l)"
		firephlox_ok "prefs.js — ${entry_count} neural pathways mapped"
		[[ "${dup_count}" -gt 0 ]] && \
			firephlox_warn "Conflicting neural pathways: ${dup_count} duplicate pref keys detected."

		# Syntax validation — a partial write (e.g. from a crash mid-stream)
		# leaves truncated or malformed lines that cause non-obvious runtime failures.
		local syntax_errors
		syntax_errors="$(python3 - "${prefs}" <<'PYTHON' 2>/dev/null || true
import re, sys
pref_re = re.compile(r'^user_pref\("[^"]+",\s*.+\);$')
errors = []
with open(sys.argv[1]) as f:
    for i, raw in enumerate(f, 1):
        line = raw.rstrip('\n')
        if not line or line.startswith('//') or line.startswith('/*') or line.startswith(' *'):
            continue
        if not pref_re.match(line):
            errors.append(f'line {i}: {line[:80]}')
for e in errors[:5]:
    print(e)
if len(errors) > 5:
    print(f'... and {len(errors) - 5} more')
sys.exit(1 if errors else 0)
PYTHON
)"
		if [[ -n "${syntax_errors}" ]]; then
			firephlox_error 'prefs.js syntax damage detected:'
			printf '%s\n' "${syntax_errors}" | while IFS= read -r line; do
				firephlox_warn "  ${line}"
			done
			firephlox_warn 'A partial write (e.g. from a crash during media load) can break prefs.js silently.'
			firephlox_warn 'Use --revive=<id> --fresh --exclude=prefs to restore without transplanting prefs.'
		else
			firephlox_ok 'prefs.js — syntax intact'
		fi

		local val
		val="$(_fp_triage_pref "${prefs}" 'privacy.resistFingerprinting')"
		[[ "${val}" == 'true' ]] && \
			firephlox_warn 'privacy.resistFingerprinting = true — this pathway strips outgoing referrer headers on cross-site requests; documented cause of HTTP 403 on CDN-authenticated video (YouTube).'

		val="$(_fp_triage_pref "${prefs}" 'datareporting.policy.dataSubmissionPolicyAcceptedVersion')"
		[[ "${val}" == '0' ]] && \
			firephlox_warn 'dataSubmissionPolicyAcceptedVersion = 0 — Firefox will present the data-policy consent screen on every admission.'

		val="$(_fp_triage_pref "${prefs}" 'xpinstall.signatures.required')"
		[[ "${val}" == 'false' ]] && \
			firephlox_warn 'xpinstall.signatures.required = false — unsigned implants will load without challenge.'

		val="$(_fp_triage_pref "${prefs}" 'media.hardware-video-decoding.enabled')"
		[[ "${val}" == 'false' ]] && \
			firephlox_info 'media.hardware-video-decoding.enabled = false — hardware decode pathway deliberately bypassed.'

		val="$(_fp_triage_pref "${prefs}" 'browser.contentblocking.category')"
		[[ "${val}" == '"strict"' ]] && \
			firephlox_info 'ETP mode: strict — fingerprinting countermeasures active; referrer headers stripped on cross-site requests.'
	fi

	# --- Check 4: Synaptic continuity — session state -------------------
	firephlox_section 'Triage 4 · Synaptic continuity — session state'
	local ss="${profile}/sessionstore.jsonlz4"
	local ss_bak="${profile}/sessionstore-backups/previous.jsonlz4"
	if [[ -f "${ss}" ]]; then
		local kb; kb="$(du -k "${ss}" | cut -f1)"
		firephlox_ok "sessionstore.jsonlz4 intact (${kb}K)"
	elif [[ -f "${ss_bak}" ]]; then
		firephlox_warn 'sessionstore.jsonlz4 absent; emergency backup found — the patient experienced an uncontrolled shutdown.'
	else
		firephlox_info 'sessionstore.jsonlz4 absent — either purged or the patient discharged cleanly with no open tabs.'
	fi

	# --- Check 5: Trauma record — crash reports -------------------------
	firephlox_section 'Triage 5 · Trauma record — crash reports'
	local crashes_dir="${profile}/crashes"
	if [[ -d "${crashes_dir}" ]]; then
		local submitted pending
		submitted="$(find "${crashes_dir}/submitted" -name '*.txt' 2>/dev/null | wc -l)"
		pending="$(find  "${crashes_dir}/pending"   -name '*.dmp' 2>/dev/null | wc -l)"
		[[ "${submitted}" -gt 0 ]] && firephlox_warn "${submitted} filed trauma report(s) on record."
		[[ "${pending}"   -gt 0 ]] && firephlox_warn "${pending} unsubmitted crash dump(s) — the patient collapsed before the report could be filed."
		[[ "${submitted}" -eq 0 && "${pending}" -eq 0 ]] && firephlox_ok 'No trauma on record.'
	else
		firephlox_ok 'Trauma directory absent — the patient has led a remarkably incident-free life.'
	fi

	# --- Check 6: Implant inventory — extensions ------------------------
	firephlox_section 'Triage 6 · Implant inventory — extensions'
	local ext_json="${profile}/extensions.json"
	if [[ -f "${ext_json}" ]]; then
		local ext_count
		ext_count="$(python3 -c "
import json
print(len(json.load(open('${ext_json}')).get('addons', [])))
" 2>/dev/null || printf '?')"
		firephlox_ok "${ext_count} implant(s) registered in extensions.json"
	else
		firephlox_info 'extensions.json absent.'
	fi
	local orphan="${profile}/extensions/apple-music-shuffle@firephlox.xpi"
	[[ -f "${orphan}" ]] && \
		firephlox_warn "Unrecognised foreign implant: ${orphan} — present without a valid enterprise policy to authorise it."

	# --- Check 7: Life support — snap interface connections -------------
	firephlox_section 'Triage 7 · Life support — snap interface connections'
	if command -v snap >/dev/null 2>&1; then
		local conns
		conns="$(snap connections firefox 2>/dev/null)"
		local hw; hw="$(printf '%s\n' "${conns}" | awk '/hardware-observe/{print $4}')"
		local gl; gl="$(printf '%s\n' "${conns}" | awk '/opengl/{print $4}')"
		if [[ -z "${hw}" || "${hw}" == '-' ]]; then
			firephlox_info 'hardware-observe: disconnected'
		else
			firephlox_ok "hardware-observe: online (${hw})"
		fi
		if [[ -z "${gl}" || "${gl}" == '-' ]]; then
			firephlox_info 'opengl: disconnected (may limit hardware decode recovery pathways)'
		else
			firephlox_ok 'opengl: online'
		fi
	else
		firephlox_warn 'snap unavailable; cannot check life support interfaces.'
	fi

	printf '\n'
	firephlox_ok 'Diagnostic cycle complete. The patient has my full attention.'
	firephlox_info 'To salvage settings from a snapshot: ./firephlox --revive=<snapshot-id>'
	firephlox_info 'Run: snap saved firefox  to list available specimens.'

	# When triaging a snapshot, write a findings file so revive can
	# automatically apply any exclusion recommendations.
	if [[ -n "${snap_id}" ]]; then
		_fp_triage_write_findings "${snap_id}" "${profile}"
	fi
}

# Writes a findings file to ~/.cache/firephlox/triage-<id>.findings.
# Format: one directive per line – warn:message or recommend-exclude:category.
# Used by firephlox_revive to surface warnings and suggested exclusions.
_fp_triage_write_findings() {
	local snap_id="$1" profile="$2"
	local findings_dir="${HOME}/.cache/firephlox"
	local findings_file="${findings_dir}/triage-${snap_id}.findings"
	mkdir -p "${findings_dir}"
	# Start empty; only populated when issues are found.
	: > "${findings_file}"

	# prefs.js syntax damage
	local prefs="${profile}/prefs.js"
	if [[ -f "${prefs}" ]]; then
		local syntax_ok
		syntax_ok="$(python3 - "${prefs}" <<'PYTHON' 2>/dev/null || printf 'damaged'
import re, sys
pref_re = re.compile(r'^user_pref\("[^"]+",\s*.+\);$')
for raw in open(sys.argv[1]):
    line = raw.rstrip('\n')
    if line and not line.startswith('//') and not line.startswith('/*') and not line.startswith(' *'):
        if not pref_re.match(line):
            sys.exit(1)
print('ok')
PYTHON
)"
		if [[ "${syntax_ok}" != 'ok' ]]; then
			printf 'warn:prefs.js contains malformed lines (partial write suspected)\n' \
				>> "${findings_file}"
			printf 'recommend-exclude:prefs\n' >> "${findings_file}"
		fi
	fi

	# Only announce if there is something to announce.
	if [[ -s "${findings_file}" ]]; then
		firephlox_warn "Findings written: ${findings_file}"
		firephlox_info "Run --revive=${snap_id} — recommendations will be applied automatically."
	else
		firephlox_ok "No adverse findings. Specimen appears fit for transplant."
		rm -f "${findings_file}"  # remove empty file
	fi
}

# Returns "ok" or an error/corruption description for a SQLite database.
# Always exits 0 so set -e does not abort the caller on a corrupt file.
_fp_triage_sqlite_check() {
	python3 - "$1" <<'PYTHON' || printf 'unreadable: python3 error\n'
import sqlite3, sys
try:
    conn = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    r = conn.execute('PRAGMA integrity_check').fetchone()
    conn.close()
    print('ok' if r[0] == 'ok' else f'corrupt: {r[0]}')
except Exception as e:
    print(f'unreadable: {e}')
PYTHON
}

# Prints the raw value of a named pref from prefs.js, or empty string if absent.
# Always exits 0.
_fp_triage_pref() {
	python3 - "$1" "$2" <<'PYTHON' 2>/dev/null || true
import sys, re
pattern = re.compile(r'^user_pref\("' + re.escape(sys.argv[2]) + r'",\s*(.*)\);')
for line in open(sys.argv[1]):
    m = pattern.match(line.strip())
    if m:
        print(m.group(1))
        sys.exit(0)
PYTHON
}
