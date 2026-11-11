# shellcheck shell=bash
# eliminate.sh — Task E: progressive pref-namespace elimination test.
#
#   "Every answer leads to a new question. That is the nature of science."
#       — Dr. Phlox
#
# Runs a binary-search-style series of revives against a snapshot, adding
# one pref namespace batch per round and launching Firefox after each for
# manual verification. When a round breaks the browser, the offending
# batch is reported.
#
# Usage: ./firephlox --eliminate=<snapshot-id>
#   snapshot-id is the numeric ID shown by: snap saved firefox
#
# Each round:
#   1. Runs a fresh-clone revive with the cumulative pref set so far.
#   2. Launches Firefox (the user tests the scenario).
#   3. Waits for Firefox to close.
#   4. Asks: "Did it work?" [y/N]
#   5. If yes → adds the batch to the working set and continues.
#      If no  → declares the batch as the culprit and stops.
#
# The batches are ordered from safest/most-expected to most-suspected,
# so the failing round is reached quickly without unnecessary iterations.

# Pref namespace batches, ordered safest → most suspected.
# Each entry is a comma-separated --prefs-only argument for one round.
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

	firephlox_section "Elimination · Progressive pref-namespace test for specimen ${snap_id}"
	firephlox_info 'Each round adds one namespace batch, revives, and launches Firefox.'
	firephlox_info 'The round whose batch causes a regression identifies the culprit.'
	printf '\n'

	if firephlox_firefox_running; then
		firephlox_die 'Firefox is currently running. Close it before the elimination protocol.'
	fi

	local included=''   # pref namespaces confirmed safe so far
	local suspect=''    # batch that caused a failure
	local round=0

	local batch
	for batch in "${_FP_ELIM_BATCHES[@]}"; do
		round=$(( round + 1 ))
		firephlox_section "Elimination round ${round} · Adding: ${batch}"

		local test_prefs
		if [[ -z "${included}" ]]; then
			test_prefs="${batch}"
		else
			test_prefs="${included},${batch}"
		fi

		# Fresh-clone revive with the cumulative pref set.
		FIREPHLOX_FRESH=1
		FIREPHLOX_REVIVE_SNAPSHOT="${snap_id}"
		FIREPHLOX_PREFS_ONLY="${test_prefs}"
		FIREPHLOX_REVIVE_EXCLUDE=''
		FIREPHLOX_ASSUME_YES=1   # skip the recipient-selection prompt
		firephlox_revive

		# Launch Firefox for manual verification.
		firephlox_info 'Launching Firefox…'
		firefox &>/dev/null &
		firephlox_info 'Test the scenario (play media, check affected features).'
		firephlox_info 'Close Firefox when done – the protocol will resume automatically.'

		# Wait for Firefox to exit.
		while firephlox_firefox_running; do sleep 2; done
		firephlox_info 'Firefox closed.'

		# Ask user.
		if firephlox_confirm "Round ${round} – did Firefox work correctly?"; then
			firephlox_ok "Round ${round} passed – batch not culpable: ${batch}"
			included="${test_prefs}"
		else
			suspect="${batch}"
			firephlox_error "Round ${round} failed – offending batch identified: ${batch}"
			break
		fi
	done

	printf '\n'
	firephlox_section 'Elimination · Conclusion'

	if [[ -n "${suspect}" ]]; then
		firephlox_error "Culprit namespace batch: ${suspect}"
		firephlox_info  "Safe namespaces confirmed:  ${included:-none}"
		firephlox_info  "To revive without the culprit:"
		if [[ -n "${included}" ]]; then
			firephlox_info  "  ./firephlox --revive=${snap_id} --fresh --prefs-only=${included}"
		else
			firephlox_info  "  ./firephlox --revive=${snap_id} --fresh --exclude=prefs"
		fi
	else
		firephlox_ok 'All batches passed – the full pref transplant appears safe for this specimen.'
	fi
}
