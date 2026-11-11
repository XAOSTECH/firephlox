# shellcheck shell=bash
# 09_triage.sh — Task T: non-destructive profile diagnostics.
#
# Inspects the active Firefox profile for signs of corruption, known-bad
# preferences and configuration drift. Never writes, deletes or modifies
# anything. Snapshots are never touched.
#
# Shared helpers (_fp_triage_sqlite_check, _fp_triage_pref) are also called
# by 10_revive.sh, which is sourced after this module.

firephlox_triage() {
	firephlox_section 'Triage · Profile diagnostics'

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it and re-run.'
	fi

	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)
	[[ ${#profiles[@]} -gt 0 ]] || firephlox_die 'No Firefox profiles found. Has Firefox been launched at least once?'

	# Most recently modified profile wins when several exist.
	local profile
	profile="$(
		for p in "${profiles[@]}"; do
			printf '%s %s\n' "$(stat -c '%Y' "${p}" 2>/dev/null || printf '0')" "${p}"
		done | sort -rn | head -1 | cut -d' ' -f2-
	)"
	firephlox_info "Profile: ${profile}"
	printf '\n'

	# --- Check 1: Firefox version compatibility -------------------------
	firephlox_section 'Triage 1 · Version compatibility'
	local compat_ini="${profile}/compatibility.ini"
	if [[ -f "${compat_ini}" ]]; then
		local last_ver
		last_ver="$(awk -F= '/^LastVersion=/{print $2}' "${compat_ini}")"
		local snap_ver
		snap_ver="$(snap list firefox 2>/dev/null | awk 'NR==2{print $2}')"
		firephlox_ok  "Profile last used by: Firefox ${last_ver}"
		[[ -n "${snap_ver}" ]] && firephlox_info "Installed snap:        Firefox ${snap_ver}"
		# Flag a version mismatch — a common trigger for first-launch migration failures.
		if [[ -n "${snap_ver}" && "${last_ver%%.*}" != "${snap_ver%%.*}" ]]; then
			firephlox_warn "Major version mismatch — profile was last written by ${last_ver}, snap is ${snap_ver}. A failed first-launch migration may have caused corruption."
		fi
	else
		firephlox_warn 'compatibility.ini absent — profile has never been used or was deleted.'
	fi

	# --- Check 2: Core database integrity --------------------------------
	firephlox_section 'Triage 2 · Core database integrity'
	local -a dbs=(permissions.sqlite cookies.sqlite places.sqlite
	               formhistory.sqlite storage.sqlite favicons.sqlite)
	local db result
	for db in "${dbs[@]}"; do
		local path="${profile}/${db}"
		if [[ ! -f "${path}" ]]; then
			firephlox_info "${db} — absent (normal on a fresh profile)"
			continue
		fi
		result="$(_fp_triage_sqlite_check "${path}")"
		if [[ "${result}" == 'ok' ]]; then
			firephlox_ok   "${db} — intact"
		else
			firephlox_error "${db} — ${result}"
		fi
	done

	# --- Check 3: Preference analysis ------------------------------------
	firephlox_section 'Triage 3 · Preference analysis'
	local prefs="${profile}/prefs.js"
	if [[ ! -f "${prefs}" ]]; then
		firephlox_warn 'prefs.js absent — profile is uninitialised or was stripped.'
	else
		local entry_count dup_count
		entry_count="$(grep -c 'user_pref(' "${prefs}" 2>/dev/null || printf '0')"
		dup_count="$(awk -F'"' '/^user_pref\(/{print $2}' "${prefs}" | sort | uniq -d | wc -l)"
		firephlox_ok "prefs.js — ${entry_count} entries"
		[[ "${dup_count}" -gt 0 ]] && \
			firephlox_warn "Duplicate pref keys: ${dup_count} — may cause unpredictable behaviour."

		local val
		val="$(_fp_triage_pref "${prefs}" 'privacy.resistFingerprinting')"
		[[ "${val}" == 'true' ]] && \
			firephlox_warn 'privacy.resistFingerprinting = true — strips referrer headers on cross-site requests; known to break YouTube CDN auth (HTTP 403 on video playback).'

		val="$(_fp_triage_pref "${prefs}" 'datareporting.policy.dataSubmissionPolicyAcceptedVersion')"
		[[ "${val}" == '0' ]] && \
			firephlox_warn 'dataSubmissionPolicyAcceptedVersion = 0 — Firefox will show the data-policy nag on every launch.'

		val="$(_fp_triage_pref "${prefs}" 'xpinstall.signatures.required')"
		[[ "${val}" == 'false' ]] && \
			firephlox_warn 'xpinstall.signatures.required = false — unsigned extensions load without prompt.'

		val="$(_fp_triage_pref "${prefs}" 'media.hardware-video-decoding.enabled')"
		[[ "${val}" == 'false' ]] && \
			firephlox_info 'media.hardware-video-decoding.enabled = false — hardware video decode deliberately disabled.'

		val="$(_fp_triage_pref "${prefs}" 'browser.contentblocking.category')"
		[[ "${val}" == '"strict"' ]] && \
			firephlox_info 'ETP mode: strict — fingerprinting protection and referrer stripping active; may affect CDN-authenticated video on sites like YouTube.'
	fi

	# --- Check 4: Session state ------------------------------------------
	firephlox_section 'Triage 4 · Session state'
	local ss="${profile}/sessionstore.jsonlz4"
	local ss_bak="${profile}/sessionstore-backups/previous.jsonlz4"
	if [[ -f "${ss}" ]]; then
		local kb; kb="$(du -k "${ss}" | cut -f1)"
		firephlox_ok "sessionstore.jsonlz4 present (${kb}K)"
	elif [[ -f "${ss_bak}" ]]; then
		firephlox_warn 'sessionstore.jsonlz4 absent; backup copy found — Firefox likely crashed on last exit.'
	else
		firephlox_info 'sessionstore.jsonlz4 absent — either purged or Firefox exited cleanly with no tabs to restore.'
	fi

	# --- Check 5: Crash reports ------------------------------------------
	firephlox_section 'Triage 5 · Crash reports'
	local crashes_dir="${profile}/crashes"
	if [[ -d "${crashes_dir}" ]]; then
		local submitted pending
		submitted="$(find "${crashes_dir}/submitted" -name '*.txt' 2>/dev/null | wc -l)"
		pending="$(find  "${crashes_dir}/pending"   -name '*.dmp' 2>/dev/null | wc -l)"
		[[ "${submitted}" -gt 0 ]] && firephlox_warn "${submitted} submitted crash report(s) on record."
		[[ "${pending}"   -gt 0 ]] && firephlox_warn "${pending} pending crash dump(s) — Firefox crashed before it could submit."
		[[ "${submitted}" -eq 0 && "${pending}" -eq 0 ]] && firephlox_ok 'No crash reports.'
	else
		firephlox_ok 'No crash directory — no recorded crashes.'
	fi

	# --- Check 6: Extension inventory ------------------------------------
	firephlox_section 'Triage 6 · Extensions'
	local ext_json="${profile}/extensions.json"
	if [[ -f "${ext_json}" ]]; then
		local ext_count
		ext_count="$(python3 -c "
import json
d = json.load(open('${ext_json}'))
print(len(d.get('addons', [])))
" 2>/dev/null || printf '?')"
		firephlox_ok "${ext_count} extension(s) registered in extensions.json"
	else
		firephlox_info 'extensions.json absent.'
	fi
	local orphan="${profile}/extensions/apple-music-shuffle@firephlox.xpi"
	[[ -f "${orphan}" ]] && \
		firephlox_warn "Orphaned firephlox XPI present: ${orphan} — no enterprise policy backing it."

	# --- Check 7: Snap interface connections -----------------------------
	firephlox_section 'Triage 7 · Snap interfaces'
	if command -v snap >/dev/null 2>&1; then
		local conns
		conns="$(snap connections firefox 2>/dev/null)"
		local hw; hw="$(printf '%s\n' "${conns}" | awk '/hardware-observe/{print $4}')"
		local gl; gl="$(printf '%s\n' "${conns}" | awk '/opengl/{print $4}')"
		if [[ -z "${hw}" || "${hw}" == '-' ]]; then
			firephlox_info 'hardware-observe: disconnected'
		else
			firephlox_ok "hardware-observe: connected (${hw})"
		fi
		if [[ -z "${gl}" || "${gl}" == '-' ]]; then
			firephlox_info 'opengl: disconnected (may limit hardware decode fallback paths)'
		else
			firephlox_ok 'opengl: connected'
		fi
	else
		firephlox_warn 'snap command not found; cannot check interface connections.'
	fi

	printf '\n'
	firephlox_ok 'Triage complete. Review any warnings above.'
	firephlox_info 'To transplant settings from a snapshot: ./firephlox --revive=<snapshot-id>'
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

# Prints the raw value of a pref from prefs.js, or empty string if absent.
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
