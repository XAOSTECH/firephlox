# shellcheck shell=bash
# titles.sh — reusable banner and section headings for firephlox.
# Requires colours.sh to have been sourced beforehand.

[[ -n "${FIREPHLOX_TITLES_SOURCED:-}" ]] && return 0
readonly FIREPHLOX_TITLES_SOURCED=1

# Internal: print a single, perfectly centred row inside the banner box.
firephlox__banner_row() {
	local width="$1" text="$2" pad_left pad_right total
	total=${#text}
	pad_left=$(( (width - total) / 2 ))
	pad_right=$(( width - total - pad_left ))
	printf '  %s%s║%*s%s%*s║%s\n' \
		"${FP_MAGENTA}" "${FP_BOLD}" "${pad_left}" '' "${text}" "${pad_right}" '' "${FP_RESET}"
}

# firephlox_banner — the show-stopping title block for the tool.
firephlox_banner() {
	local width=48 bar
	bar="$(printf '═%.0s' $(seq 1 "${width}"))"
	printf '\n  %s%s╔%s╗%s\n' "${FP_MAGENTA}" "${FP_BOLD}" "${bar}" "${FP_RESET}"
	firephlox__banner_row "${width}" 'F I R E P H L O X'
	firephlox__banner_row "${width}" 'Telemetry surgery for Snap-confined Firefox'
	printf '  %s%s╚%s╝%s\n' "${FP_MAGENTA}" "${FP_BOLD}" "${bar}" "${FP_RESET}"
	printf '  %sDr. Phlox is operating on the fox - hold still.%s\n\n' "${FP_DIM}" "${FP_RESET}"
}

# firephlox_section <title> — a labelled divider between tasks.
firephlox_section() {
	printf '\n%s%s▶ %s%s\n' "${FP_CYAN}" "${FP_BOLD}" "$1" "${FP_RESET}"
}
