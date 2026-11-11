# shellcheck shell=bash
# 01_prereqs.sh — pre-flight safety checks before any surgery begins.

firephlox_run_prereqs() {
	firephlox_section 'Task 0 · Pre-flight checks'

	# Operating as root would target /root rather than the real user profile.
	if [[ ${EUID} -eq 0 ]]; then
		firephlox_warn 'Running as root: user-profile edits would target /root, which is rarely intended.'
	fi

	# Firefox must be fully closed or prefs.js / the lock file may corrupt.
	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it completely (check the tray) and re-run.'
	fi
	firephlox_ok 'Firefox is not running.'

	# The Snap must have been launched once to create its writable trees.
	if [[ ! -d "${HOME}/snap/firefox" ]]; then
		firephlox_die "No ${HOME}/snap/firefox directory found. Launch the Firefox Snap once, then re-run."
	fi
	firephlox_ok "Snap user tree present: ${HOME}/snap/firefox"

	if [[ ! -d "${FIREPHLOX_USER_PROFILES_DIR}" ]]; then
		firephlox_warn "Profile directory missing: ${FIREPHLOX_USER_PROFILES_DIR}"
		firephlox_warn 'user.js and cache tasks will be skipped until a profile exists.'
	else
		firephlox_ok "Profile directory present: ${FIREPHLOX_USER_PROFILES_DIR}"
	fi

	# Flag early whether either system surface will need sudo.
	if ! firephlox_path_writable "${FIREPHLOX_ETC_POLICIES_DIR}"; then
		firephlox_info "${FIREPHLOX_ETC_POLICIES_DIR} requires elevated privileges; sudo will be requested."
	fi
	if ! firephlox_path_writable "${FIREPHLOX_SNAP_COMMON}"; then
		firephlox_info "${FIREPHLOX_SNAP_COMMON} requires elevated privileges; sudo will be requested."
	fi
}
