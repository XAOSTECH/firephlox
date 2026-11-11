# shellcheck shell=bash
# 04_purge.sh — Task 3: safely wipe telemetry logs, pending pings and crash caches that can trigger thread lock-ups. Every deletion is fenced behind a strict path guard so an unset variable can never escalate to rm -rf /.

firephlox_purge_caches() {
	firephlox_section 'Task 3 · Safe cache & telemetry purge'

	if [[ "${FIREPHLOX_SKIP_PURGE:-0}" == "1" ]]; then
		firephlox_info 'Purge skipped (--no-purge).'
		return 0
	fi

	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)
	if [[ ${#profiles[@]} -eq 0 ]]; then
		firephlox_warn 'No Firefox profiles discovered; nothing to purge.'
		return 0
	fi

	if ! firephlox_confirm "Delete telemetry, pending pings and crash caches from ${#profiles[@]} profile(s)?"; then
		firephlox_warn 'Purge declined by user.'
		return 0
	fi

	local -a targets=(datareporting saved-telemetry-pings crashes)
	local profile target path
	for profile in "${profiles[@]}"; do
		# Hard guard: only ever operate inside the configured profile tree.
		[[ -n "${profile}" && "${profile}" == "${FIREPHLOX_USER_PROFILES_DIR}/"* ]] || {
			firephlox_warn "Refusing to purge outside the profile tree: ${profile}"
			continue
		}
		for target in "${targets[@]}"; do
			path="${profile}/${target}"
			[[ -e "${path}" ]] || continue
			if firephlox_is_dry_run; then
				firephlox_info "(dry-run) rm -rf ${path}"
				continue
			fi
			rm -rf -- "${path}"
			firephlox_ok "Purged ${path}"
		done
	done
}
