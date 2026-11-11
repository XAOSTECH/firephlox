# shellcheck shell=bash
# 03_userjs.sh — Task 2: harden every active profile via a managed user.js block. The block is delimited by markers so re-runs stay idempotent and never disturb the user's own preferences.

firephlox_apply_userjs() {
	firephlox_section 'Task 2 · Active profile hardening (user.js)'

	local begin='// >>> firephlox managed block >>>'
	local end='// <<< firephlox managed block <<<'

	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)
	if [[ ${#profiles[@]} -eq 0 ]]; then
		firephlox_warn 'No Firefox profiles discovered; skipping user.js injection.'
		return 0
	fi

	local profile userjs tmp
	for profile in "${profiles[@]}"; do
		userjs="${profile}/user.js"

		if firephlox_is_dry_run; then
			firephlox_info "(dry-run) refresh managed block in ${userjs}"
			continue
		fi

		tmp="$(mktemp)"
		# Carry across any content that lives outside our managed block.
		if [[ -f "${userjs}" ]]; then
			awk -v b="${begin}" -v e="${end}" '
				$0==b {skip=1}
				skip && $0==e {skip=0; next}
				!skip {print}
			' "${userjs}" >"${tmp}"
		fi

		{
			printf '%s\n' "${begin}"
			printf '// Managed by firephlox — edits between these markers are overwritten.\n'
			printf 'user_pref("datareporting.healthreport.uploadEnabled", false);\n'
			printf 'user_pref("datareporting.policy.dataSubmissionPolicyAcceptedVersion", 0);\n'
			printf 'user_pref("datareporting.usage.uploadEnabled", false);\n'
			printf 'user_pref("layers.acceleration.disabled", false);\n'
			# Allows unsigned extensions in profile/extensions/ — bypasses snap signature enforcement.
			printf 'user_pref("xpinstall.signatures.required", false);\n'
			printf '%s\n' "${end}"
		} >>"${tmp}"

		install -m 0644 "${tmp}" "${userjs}"
		rm -f "${tmp}"
		firephlox_ok "user.js hardened → ${userjs}"
	done
}
