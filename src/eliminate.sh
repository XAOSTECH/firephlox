# shellcheck shell=bash
# eliminate.sh — Task E: progressive pref-namespace elimination test.
#
#   "Every answer leads to a new question. That is the nature of science."
#       — Dr. Phlox
#
# Usage:
#   ./firephlox --eliminate=<id>           standard  – grouped batches
#   ./firephlox --eliminate=<id> --full    full      – one term per round
#   ./firephlox --eliminate=<id> --smart   smart     – grouped pass, then
#                                                      auto-splits the culprit

readonly _FP_ELIM_TEST_URL='https://archive.org/details/fantastic-planet__1973'

# Standard batches, ordered safest → most suspected.
readonly _FP_ELIM_BATCHES=(
    'browser,network,dom,security,gfx,layout'
    'extensions,privacy,signon,services'
    'app,widget,doh-rollout,distribution'
    'media.videocontrols,media.block,media.autoplay,media.suspend-bkgnd-video,media.peerconnection'
    'media.gmp'
    'media.eme,media.gmp-widevinecdm'
    'toolkit,datareporting'
)

firephlox_eliminate() {
	local snap_id="${FIREPHLOX_ELIMINATE_SNAPSHOT}"
	[[ -n "${snap_id}" ]] || \
		firephlox_die 'No specimen ID given. Usage: --eliminate=<id>  (run: snap saved firefox)'

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it before the elimination protocol.'
	fi

	local -a batches=()
	if [[ "${FIREPHLOX_ELIMINATE_FULL:-0}" == '1' ]]; then
		_fp_elim_expand batches "${_FP_ELIM_BATCHES[@]}"
		firephlox_section "Elimination · Full protocol – specimen ${snap_id} (${#batches[@]} rounds)"
	else
		batches=("${_FP_ELIM_BATCHES[@]}")
		local smart_note=''
		[[ "${FIREPHLOX_ELIMINATE_SMART:-0}" == '1' ]] && smart_note=' + smart sub-pass on culprit'
		firephlox_section "Elimination · Standard protocol – specimen ${snap_id} (${#batches[@]} rounds${smart_note})"
	fi

	# --exclude skips pre-known culprit terms from the batch list so the
	# protocol can find a second (or later) pathogen without re-testing known bad ones.
	if [[ -n "${FIREPHLOX_REVIVE_EXCLUDE:-}" ]]; then
		firephlox_warn "Pre-known culprits excluded: ${FIREPHLOX_REVIVE_EXCLUDE}"
		local -a filtered=()
		local b term skip_term in_skip keep
		for b in "${batches[@]}"; do
			keep=''
			local IFS=','
			for term in ${b}; do
				in_skip=0
				for skip_term in ${FIREPHLOX_REVIVE_EXCLUDE}; do
					[[ "${term}" == "${skip_term}" ]] && in_skip=1 && break
				done
				[[ "${in_skip}" -eq 0 ]] && keep="${keep:+${keep},}${term}"
			done
			[[ -n "${keep}" ]] && filtered+=("${keep}")
		done
		batches=("${filtered[@]}")
	fi
	firephlox_info 'Each round adds one batch, revives, and launches Firefox.'
	[[ "${FIREPHLOX_ASSUME_YES:-0}" == '1' ]] \
		&& firephlox_info '-y active: rounds auto-advance after Firefox closes.' \
		|| firephlox_info 'Close Firefox when done. Ctrl+C within 5 s to flag the batch as culprit.'
	printf '\n'

	_fp_elim_run_pass '' "${snap_id}" "${batches[@]}"
	local suspect="${_FP_ELIM_SUSPECT}"
	local safe="${_FP_ELIM_SAFE}"

	# Smart: if the culprit batch contains multiple terms, run a sub-pass.
	if [[ "${FIREPHLOX_ELIMINATE_SMART:-0}" == '1' && -n "${suspect}" && "${suspect}" == *,* ]]; then
		firephlox_section "Elimination · Smart sub-pass – splitting culprit: ${suspect}"
		local -a sub_batches=()
		_fp_elim_expand sub_batches "${suspect}"
		_fp_elim_run_pass "${safe}" "${snap_id}" "${sub_batches[@]}"
		suspect="${_FP_ELIM_SUSPECT}"
		safe="${_FP_ELIM_SAFE}"
	fi

	printf '\n'
	firephlox_section 'Elimination · Conclusion'
	if [[ -n "${suspect}" ]]; then
		firephlox_error "Culprit namespace: ${suspect}"
		firephlox_info  "Confirmed safe (this run): ${safe:-none}"

		# Build the full "everything minus culprit" recommendation by expanding
		# all standard batches and removing every term that is in the suspect.
		local -a all_terms=()
		_fp_elim_expand all_terms "${_FP_ELIM_BATCHES[@]}"
		local -a suspect_terms=()
		_fp_elim_expand suspect_terms "${suspect}"
		local -a safe_all=()
		local t s is_s
		for t in "${all_terms[@]}"; do
			is_s=0
			for s in "${suspect_terms[@]}"; do
				[[ "${t}" == "${s}" ]] && is_s=1 && break
			done
			[[ "${is_s}" -eq 0 ]] && safe_all+=("${t}")
		done
		local all_safe_csv; all_safe_csv="$(IFS=','; printf '%s' "${safe_all[*]}")"

		firephlox_ok  "To revive with everything except the culprit:"
		firephlox_info "  ./firephlox --revive=${snap_id} --fresh --prefs-only=${all_safe_csv}"
		firephlox_info "To search for a second pathogen, re-run with the culprit excluded:"
		firephlox_info "  ./firephlox --eliminate=${snap_id} --smart --exclude=${suspect}"
	else
		firephlox_ok 'All batches passed – the full pref transplant appears safe for this specimen.'
	fi
}

# Runs one elimination pass. Sets _FP_ELIM_SUSPECT and _FP_ELIM_SAFE.
# Args: <initial_safe> <snap_id> <batch> [<batch> ...]
_fp_elim_run_pass() {
	local initial_safe="$1" snap_id="$2"; shift 2
	local -a batches=("$@")
	_FP_ELIM_SUSPECT=''
	_FP_ELIM_SAFE="${initial_safe}"
	local included="${initial_safe}"
	local round=0 batch

	for batch in "${batches[@]}"; do
		round=$(( round + 1 ))
		firephlox_section "Elimination round ${round} · Adding: ${batch}"

		local test_prefs
		[[ -z "${included}" ]] && test_prefs="${batch}" || test_prefs="${included},${batch}"

		# FIREPHLOX_FRESH bypasses the recipient menu without touching ASSUME_YES.
		FIREPHLOX_FRESH=1
		FIREPHLOX_REVIVE_SNAPSHOT="${snap_id}"
		FIREPHLOX_PREFS_ONLY="${test_prefs}"
		FIREPHLOX_REVIVE_EXCLUDE=''
		firephlox_revive

		firephlox_info 'Launching Firefox…'
		firephlox_info "${FP_DIM}Dr. Phlox recommends observing the inhabitants of Ygam as relaxing edutainment while awaiting your diagnostic results.${FP_RESET}"
		firefox "${_FP_ELIM_TEST_URL}" &>/dev/null &

		# The snap Firefox takes several seconds to initialise. Wait for the process to appear before entering the close-wait loop.
		local startup=0
		until firephlox_firefox_running || [[ "${startup}" -ge 15 ]]; do
			sleep 1 || true
			startup=$(( startup + 1 ))
		done
		if [[ "${startup}" -ge 15 ]]; then
			firephlox_warn 'Firefox did not start within 15 seconds – check snap status.'
		fi

		firephlox_info 'Test the scenario (play media, check affected features).'
		firephlox_info 'Close Firefox when done.'

		# Wait for Firefox to close. Ctrl+C here also counts as a failure.
		# sleep is guarded with || true because set -e would otherwise exit the script when sleep is interrupted by SIGINT (exits with status 130).
		local ff_interrupted=0
		trap 'ff_interrupted=1' INT
		while firephlox_firefox_running && [[ "${ff_interrupted}" -eq 0 ]]; do sleep 2 || true; done
		trap - INT

		if [[ "${ff_interrupted}" -eq 1 ]]; then
			printf '\n'
			firephlox_warn 'Ctrl+C – flagging batch as culprit.'
			_FP_ELIM_SUSPECT="${batch}"
			return 0
		fi
		firephlox_info 'Firefox closed.'

		# Determine pass/fail: countdown with Ctrl+C, or auto-advance with -y.
		local passed=0
		if [[ "${FIREPHLOX_ASSUME_YES:-0}" == '1' ]]; then
			passed=1
		else
			local interrupted=0
			trap 'interrupted=1' INT
			local i
			for i in 5 4 3 2 1; do
				printf '\r%s[ .. ]%s  Advancing in %d s – Ctrl+C to flag culprit  ' \
					"${FP_BLUE}" "${FP_RESET}" "${i}"
				sleep 1 || true   # || true: set -e must not exit on SIGINT-interrupted sleep
				[[ "${interrupted}" -eq 1 ]] && break
			done
			printf '\n'
			trap - INT
			[[ "${interrupted}" -eq 0 ]] && passed=1
		fi

		if [[ "${passed}" -eq 1 ]]; then
			firephlox_ok "Round ${round} passed – batch not culpable: ${batch}"
			included="${test_prefs}"
			_FP_ELIM_SAFE="${included}"
		else
			firephlox_error "Round ${round} failed – culprit: ${batch}"
			_FP_ELIM_SUSPECT="${batch}"
			return 0
		fi
	done
}

# Splits each comma-separated batch into individual terms.
# Usage: _fp_elim_expand <array_name> <batch> [<batch> ...]
_fp_elim_expand() {
	local -n _elim_ref="$1"; shift
	local b term
	for b in "$@"; do
		local IFS=','
		for term in ${b}; do
			[[ -n "${term}" ]] && _elim_ref+=("${term}")
		done
	done
}
