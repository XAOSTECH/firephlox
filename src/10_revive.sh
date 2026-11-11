# shellcheck shell=bash
# 10_revive.sh — Task V: transplant settings from a snap data snapshot.
#
# Non-destructively extracts a snap saved snapshot ZIP, locates the Firefox
# profile inside it, runs a triage-lite check on the source data, then
# transplants targeted settings — currently cookie permissions — into the
# active profile. The source snapshot is never modified or deleted.
#
# Usage: ./firephlox --revive=<snapshot-id>
#   snapshot-id is the numeric ID shown by: snap saved firefox
#
# The active profile is left untouched if the extraction or integrity check
# of the source snapshot fails. All changes are confined to the active
# profile's permissions.sqlite.

firephlox_revive() {
	local snap_id="${FIREPHLOX_REVIVE_SNAPSHOT}"
	[[ -n "${snap_id}" ]] || \
		firephlox_die 'No snapshot ID given. Usage: --revive=<id>  (run: snap saved firefox)'

	firephlox_section "Revive · Transplant settings from snapshot ${snap_id}"

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it and re-run.'
	fi

	# --- Locate the snapshot ZIP -----------------------------------------
	firephlox_info "Locating snapshot ${snap_id}…"
	local zip_file
	zip_file="$(_fp_revive_find_zip "${snap_id}")"
	[[ -n "${zip_file}" ]] || \
		firephlox_die "Snapshot ${snap_id} not found. Run 'snap saved firefox' to list available snapshots."

	local zip_size; zip_size="$(du -h "${zip_file}" 2>/dev/null | cut -f1)"
	firephlox_ok "Snapshot ZIP (${zip_size}): ${zip_file}"

	# --- Stage the ZIP contents ------------------------------------------
	firephlox_section 'Revive 1 · Extract snapshot'

	local stage_dir
	stage_dir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf -- '${stage_dir}'" RETURN EXIT

	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) would extract ${zip_file} to staging area"
		firephlox_info "(dry-run) would search for permissions.sqlite and prefs.js"
		return 0
	fi

	# Copy the ZIP to a temp file we own (the snapshots dir is root-readable
	# only), then extract using Python's built-in zipfile module.
	local tmp_zip
	tmp_zip="$(mktemp --suffix=.zip)"
	# shellcheck disable=SC2064
	trap "rm -f -- '${tmp_zip}'; rm -rf -- '${stage_dir}'" RETURN EXIT

	firephlox_info "Staging snapshot (this may take a moment)…"
	if firephlox_path_writable "${zip_file}"; then
		cp "${zip_file}" "${tmp_zip}"
	else
		firephlox_privileged cp "${zip_file}" "${tmp_zip}"
		# Fix ownership so we can read it.
		chmod 600 "${tmp_zip}" 2>/dev/null || firephlox_privileged chmod 600 "${tmp_zip}"
	fi

	python3 - "${tmp_zip}" "${stage_dir}" <<'PYTHON'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'r') as z:
    z.extractall(sys.argv[2])
PYTHON
	rm -f "${tmp_zip}"
	firephlox_ok "Snapshot staged."

	# --- Locate the Firefox profile inside the staged data ---------------
	local src_perms src_prefs
	src_perms="$(_fp_revive_find_in_stage "${stage_dir}" 'permissions.sqlite')"
	src_prefs="$(_fp_revive_find_in_stage "${stage_dir}" 'prefs.js')"

	[[ -n "${src_perms}" ]] || \
		firephlox_die 'Could not find permissions.sqlite inside the snapshot. Is this a Firefox snapshot?'
	firephlox_ok "permissions.sqlite found in snapshot"
	[[ -n "${src_prefs}" ]] && firephlox_ok "prefs.js found in snapshot" || \
		firephlox_warn "prefs.js not found in snapshot."

	# --- Triage the source data ------------------------------------------
	firephlox_section 'Revive 2 · Assess snapshot data'

	local perms_check
	perms_check="$(_fp_triage_sqlite_check "${src_perms}")"
	if [[ "${perms_check}" != 'ok' ]]; then
		firephlox_die "permissions.sqlite in snapshot is ${perms_check}. Cannot safely extract cookie exceptions."
	fi
	firephlox_ok "permissions.sqlite integrity: ok"

	# Check for any notable prefs in the source (informational only).
	if [[ -n "${src_prefs}" ]]; then
		local val
		val="$(_fp_triage_pref "${src_prefs}" 'privacy.resistFingerprinting')"
		[[ "${val}" == 'true' ]] && \
			firephlox_warn 'Source snapshot has privacy.resistFingerprinting = true — this pref will NOT be transplanted (it is a known source of issues).'
		val="$(_fp_triage_pref "${src_prefs}" 'browser.contentblocking.category')"
		[[ -n "${val}" ]] && firephlox_info "Source ETP mode: ${val}"
	fi

	# --- Extract and report cookie permissions ---------------------------
	local perms_json
	perms_json="$(_fp_revive_extract_cookie_perms "${src_perms}")"

	local allow_count block_count other_count total
	allow_count="$(printf '%s\n' "${perms_json}" | \
		python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d if r[2]==1))" 2>/dev/null || printf '0')"
	block_count="$(printf '%s\n' "${perms_json}" | \
		python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d if r[2]==2))" 2>/dev/null || printf '0')"
	other_count="$(printf '%s\n' "${perms_json}" | \
		python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d if r[2] not in (1,2)))" 2>/dev/null || printf '0')"
	total=$(( allow_count + block_count + other_count ))

	if [[ "${total}" -eq 0 ]]; then
		firephlox_warn 'No cookie exceptions found in this snapshot. Nothing to transplant.'
		return 0
	fi

	firephlox_ok "Cookie exceptions ready for transplant:"
	firephlox_info "  Allow (persist across exit):  ${allow_count}"
	firephlox_info "  Block:                         ${block_count}"
	firephlox_info "  Session / other:               ${other_count}"
	firephlox_info "  Total:                         ${total}"

	# --- Confirm and inject ----------------------------------------------
	firephlox_section 'Revive 3 · Transplant'

	if ! firephlox_confirm "Transplant ${total} cookie exceptions into the active profile?"; then
		firephlox_warn 'Revive cancelled.'
		return 0
	fi

	local -a dst_profiles
	mapfile -t dst_profiles < <(firephlox_discover_profiles)
	[[ ${#dst_profiles[@]} -gt 0 ]] || firephlox_die 'No active Firefox profile found to transplant into.'

	local dst_profile="${dst_profiles[0]}"
	local dst_perms="${dst_profile}/permissions.sqlite"

	_fp_revive_inject_cookie_perms "${perms_json}" "${dst_perms}"
	firephlox_ok "Transplanted ${total} cookie exceptions → ${dst_perms}"

	printf '\n'
	firephlox_ok "Revive complete. The patient's memory has been restored."
	firephlox_info 'Snapshot was not modified.'
	firephlox_info 'Restart Firefox to apply.'
}

# Finds the snapshot ZIP for a given snapshot ID in the snapd store.
_fp_revive_find_zip() {
	local snap_id="$1"
	local snapshots_dir='/var/lib/snapd/snapshots'
	local match=''
	# Try without elevation first; fall back to privileged ls.
	match="$(ls "${snapshots_dir}/${snap_id}_"*.zip 2>/dev/null | head -1 || true)"
	if [[ -z "${match}" ]]; then
		match="$(firephlox_privileged ls "${snapshots_dir}/${snap_id}_"*.zip 2>/dev/null | head -1 || true)"
	fi
	printf '%s' "${match}"
}

# Finds a named file inside the staged snapshot, constrained to firefox paths.
_fp_revive_find_in_stage() {
	local stage_dir="$1" filename="$2"
	find "${stage_dir}" -name "${filename}" -path '*firefox*' 2>/dev/null | head -1
}

# Extracts all cookie-type rows from permissions.sqlite as a JSON array.
_fp_revive_extract_cookie_perms() {
	python3 - "$1" <<'PYTHON'
import sqlite3, json, sys
try:
    conn = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    rows = conn.execute(
        "SELECT origin, type, permission, expireType, expireTime "
        "FROM moz_perms WHERE type='cookie'"
    ).fetchall()
    conn.close()
    print(json.dumps(rows))
except Exception as e:
    print('[]')
    sys.exit(1)
PYTHON
}

# Writes cookie permission rows (JSON array) into the target permissions.sqlite.
# Replaces any existing cookie rows so the result is a clean transplant.
_fp_revive_inject_cookie_perms() {
	local perms_json="$1" dst_db="$2"
	local json_tmp
	json_tmp="$(mktemp)"
	# shellcheck disable=SC2064
	trap "rm -f -- '${json_tmp}'" RETURN EXIT
	printf '%s\n' "${perms_json}" > "${json_tmp}"

	python3 - "${dst_db}" "${json_tmp}" <<'PYTHON'
import sqlite3, json, sys, time

dst_db, json_path = sys.argv[1], sys.argv[2]
with open(json_path) as f:
    perms = json.load(f)

conn = sqlite3.connect(dst_db)
conn.execute("""
    CREATE TABLE IF NOT EXISTS moz_perms (
        id               INTEGER PRIMARY KEY,
        origin           TEXT,
        type             TEXT,
        permission       INTEGER,
        expireType       INTEGER,
        expireTime       INTEGER,
        modificationTime INTEGER
    )
""")
conn.execute("DELETE FROM moz_perms WHERE type='cookie'")
now_ms = int(time.time() * 1000)
for row in perms:
    origin, ptype, permission, expire_type, expire_time = row
    conn.execute(
        "INSERT INTO moz_perms "
        "(origin, type, permission, expireType, expireTime, modificationTime) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (origin, ptype, permission, expire_type, expire_time, now_ms)
    )
conn.commit()
conn.close()
PYTHON
}
