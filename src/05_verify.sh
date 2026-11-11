# shellcheck shell=bash
# 05_verify.sh — final validation: confirm every configuration path was mapped correctly and report the authoritative locking mechanism.

firephlox_verify() {
	firephlox_section 'Verification · Path mapping & lock status'

	if firephlox_is_dry_run; then
		firephlox_info '(dry-run) Would verify the following mapped paths:'
		firephlox_info "  ${FIREPHLOX_ETC_POLICIES_FILE}"
		firephlox_info "  ${FIREPHLOX_SNAP_POLICIES_FILE}"
		firephlox_info "  ${FIREPHLOX_USER_PROFILES_DIR}/<profile>/user.js"
		return 0
	fi

	local ok=1

	_verify_policies_file() {
		local path="$1" label="$2"
		if [[ -f "${path}" ]]; then
			firephlox_ok "${label} present: ${path}"
			if command -v python3 >/dev/null 2>&1; then
				if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${path}" 2>/dev/null; then
					firephlox_ok "${label} is valid JSON."
				else
					firephlox_error "${label} is NOT valid JSON."; ok=0
				fi
			fi
		else
			firephlox_error "${label} missing: ${path}"; ok=0
		fi
	}

	# --- Task 1 artefacts ------------------------------------------------
	_verify_policies_file "${FIREPHLOX_ETC_POLICIES_FILE}"  'policies.json (/etc)'
	_verify_policies_file "${FIREPHLOX_SNAP_POLICIES_FILE}" 'policies.json (snap)'

	# --- Task 2 artefacts ------------------------------------------------
	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)
	if [[ ${#profiles[@]} -eq 0 ]]; then
		firephlox_warn 'No profiles found to verify user.js.'
	else
		local profile
		for profile in "${profiles[@]}"; do
			if grep -q 'firephlox managed block' "${profile}/user.js" 2>/dev/null; then
				firephlox_ok "user.js managed block present: ${profile}/user.js"
			else
				firephlox_warn "user.js managed block missing in ${profile}"
			fi
		done
	fi

	printf '\n'
	if [[ "${ok}" -eq 1 ]]; then
		firephlox_ok "${FP_BOLD}All critical configuration paths mapped correctly.${FP_RESET}"
	else
		firephlox_die 'One or more configuration artefacts are missing. Review the log above.'
	fi

	firephlox_info 'Primary enforcement: /etc/firefox/policies/policies.json (Mozilla-documented).'
	firephlox_info 'Supplementary:      /var/snap/firefox/common/distribution/policies.json (Ubuntu snap).'

	# --- Extension XPI presence ------------------------------------------
	local ext_id='apple-music-shuffle@firephlox'
	local xpi_a="${HOME}/snap/firefox/common/extensions/${ext_id}.xpi"
	local xpi_b="${FIREPHLOX_DISTRIBUTION_DIR}/extensions/${ext_id}.xpi"
	for xpi in "${xpi_a}" "${xpi_b}"; do
		if [[ -f "${xpi}" ]]; then
			local kb; kb="$(du -k "${xpi}" 2>/dev/null | cut -f1 || echo '?')"
			firephlox_ok "XPI present (${kb}K): ${xpi}"
		else
			firephlox_warn "XPI missing: ${xpi}"
		fi
	done

	# --- Post-restart diagnostic checklist --------------------------------
	firephlox_section 'What to check AFTER a full Firefox restart'
	printf '\n'
	printf '  %s1. about:policies%s\n' "${FP_BOLD}" "${FP_RESET}"
	printf '     %sExpect:%s DisableTelemetry → true, ExtensionSettings → apple-music-shuffle@firephlox\n' "${FP_DIM}" "${FP_RESET}"
	printf '     %sIf empty or missing:%s the policy files are not being loaded at all.\n' "${FP_YELLOW}" "${FP_RESET}"
	printf '     Check about:support → Policies section for errors.\n\n'
	printf '  %s2. about:addons%s\n' "${FP_BOLD}" "${FP_RESET}"
	printf '     %sExpect:%s "Apple Music True Shuffle" listed as Managed (cannot be removed).\n' "${FP_DIM}" "${FP_RESET}"
	printf '     %sIf absent + ExtensionSettings shows "Not fully applied":%s the install_url\n' "${FP_YELLOW}" "${FP_RESET}"
	printf '     could not be fetched. Verify the XPI path above starts with file:///home/\n'
	printf '     (not /var/snap/ — that is root-owned and outside snap file:// scope).\n\n'
	printf '  %s3. Browser console on music.apple.com%s\n' "${FP_BOLD}" "${FP_RESET}"
	printf '     %sExpect:%s [firephlox shuffle] content script loaded on https://music.apple.com/...\n' "${FP_DIM}" "${FP_RESET}"
	printf '     %sIf absent:%s extension is installed but the content script is not running.\n' "${FP_YELLOW}" "${FP_RESET}"
	printf '     Open console, filter by "[firephlox". Strict Enhanced Tracking Protection\n'
	printf '     does NOT block WebExtension content scripts — check about:addons instead.\n\n'
	printf '  %s4. Quick check from terminal:%s\n' "${FP_BOLD}" "${FP_RESET}"
	printf '     %spython3 -c "import json; d=json.load(open('"'"'%s'"'"')); print(list(d['"'"'policies'"'"']['"'"'ExtensionSettings'"'"'].keys()))" %s\n' \
		"${FP_DIM}" "${FIREPHLOX_ETC_POLICIES_FILE}" "${FP_RESET}"
}
