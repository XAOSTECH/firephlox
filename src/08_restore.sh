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

	printf '\n'
	firephlox_ok 'Restore complete. Firefox has been returned to its default state.'
	firephlox_info 'Note: purged telemetry caches (Task 3) are recreated by Firefox on the next launch.'
	firephlox_info 'Restart Firefox to apply the restored state.'
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
