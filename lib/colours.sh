# shellcheck shell=bash
# colours.sh — shared ANSI colour palette for firephlox.
# Sourced by every component so the colour codes live in exactly one place.

# Guard against being sourced more than once (readonly would otherwise error).
[[ -n "${FIREPHLOX_COLOURS_SOURCED:-}" ]] && return 0
readonly FIREPHLOX_COLOURS_SOURCED=1

# Honour a real terminal, respect NO_COLOR, and fall back to plain text when the output is redirected or the terminal is "dumb".
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	FP_RESET=$'\033[0m'
	FP_BOLD=$'\033[1m'
	FP_DIM=$'\033[2m'
	FP_RED=$'\033[0;31m'
	FP_GREEN=$'\033[0;32m'
	FP_YELLOW=$'\033[0;33m'
	FP_BLUE=$'\033[0;34m'
	FP_MAGENTA=$'\033[0;35m'
	FP_CYAN=$'\033[0;36m'
else
	FP_RESET=''
	FP_BOLD=''
	FP_DIM=''
	FP_RED=''
	FP_GREEN=''
	FP_YELLOW=''
	FP_BLUE=''
	FP_MAGENTA=''
	FP_CYAN=''
fi

readonly FP_RESET FP_BOLD FP_DIM FP_RED FP_GREEN FP_YELLOW FP_BLUE FP_MAGENTA FP_CYAN
