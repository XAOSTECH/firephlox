# shellcheck shell=bash
# common.sh — shared helpers: logging, dry-run, privilege handling and
# Firefox profile discovery. Keeps every module free of repeated plumbing.
# Requires colours.sh to have been sourced beforehand.

[[ -n "${FIREPHLOX_COMMON_SOURCED:-}" ]] && return 0
readonly FIREPHLOX_COMMON_SOURCED=1

# --- Logging -------------------------------------------------------------
firephlox_info()  { printf '%s[ .. ]%s %s\n' "${FP_BLUE}"   "${FP_RESET}" "$*"; }
firephlox_ok()    { printf '%s[ ok ]%s %s\n' "${FP_GREEN}"  "${FP_RESET}" "$*"; }
firephlox_warn()  { printf '%s[warn]%s %s\n' "${FP_YELLOW}" "${FP_RESET}" "$*" >&2; }
firephlox_error() { printf '%s[fail]%s %s\n' "${FP_RED}"    "${FP_RESET}" "$*" >&2; }
firephlox_die()   { firephlox_error "$*"; exit 1; }

# --- Dry-run -------------------------------------------------------------
firephlox_is_dry_run() { [[ "${FIREPHLOX_DRY_RUN:-0}" == "1" ]]; }

# --- Privilege handling --------------------------------------------------
# Escalate with sudo only when a target is genuinely not writable, and only ever for the system-wide /var/snap surface — never for user files.
firephlox_privileged() {
	if [[ ${EUID} -eq 0 ]]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		firephlox_die "Root privileges required for: $* (sudo not found)"
	fi
}

# Succeeds when the nearest existing ancestor of $1 is writable by us.
firephlox_path_writable() {
	local path="$1"
	while [[ ! -e "${path}" && "${path}" != "/" ]]; do
		path="$(dirname "${path}")"
	done
	[[ -w "${path}" ]]
}

# Create a directory, escalating with sudo only if required.
firephlox_mkdir() {
	local dir="$1"
	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) mkdir -p ${dir}"
		return 0
	fi
	if firephlox_path_writable "${dir}"; then
		mkdir -p "${dir}"
	else
		firephlox_privileged mkdir -p "${dir}"
	fi
}

# firephlox_write_file <path> [mode]; the file body arrives on stdin.
firephlox_write_file() {
	local path="$1" mode="${2:-0644}" dir
	dir="$(dirname "${path}")"
	firephlox_mkdir "${dir}"
	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) write ${path} (mode ${mode})"
		cat >/dev/null   # drain stdin so the caller's heredoc does not error
		return 0
	fi
	if firephlox_path_writable "${path}"; then
		cat >"${path}"
		chmod "${mode}" "${path}"
	else
		firephlox_privileged tee "${path}" >/dev/null
		firephlox_privileged chmod "${mode}" "${path}"
	fi
}

# --- Firefox state -------------------------------------------------------
firephlox_firefox_running() {
	pgrep -x firefox          >/dev/null 2>&1 && return 0
	pgrep -f '/snap/firefox/' >/dev/null 2>&1 && return 0
	return 1
}

# --- Confirmation --------------------------------------------------------
firephlox_confirm() {
	[[ "${FIREPHLOX_ASSUME_YES:-0}" == "1" ]] && return 0
	local reply
	read -r -p "$1 [y/N] " reply
	[[ "${reply}" =~ ^[Yy]$ ]]
}

# --- Profile discovery ---------------------------------------------------
# Echoes the absolute path of every existing profile (one per line), taking the union of profiles.ini entries and the usual *.default-release globs.
firephlox_discover_profiles() {
	local base="${FIREPHLOX_USER_PROFILES_DIR}"
	[[ -d "${base}" ]] || return 0
	{
		local ini="${base}/profiles.ini" path
		if [[ -f "${ini}" ]]; then
			while IFS= read -r path; do
				[[ -n "${path}" ]] || continue
				[[ "${path}" = /* ]] || path="${base}/${path}"
				printf '%s\n' "${path}"
			done < <(awk -F= '/^[[:space:]]*Path[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "${ini}")
		fi
		shopt -s nullglob
		for path in "${base}"/*.default-release "${base}"/*.default "${base}"/*.dev-edition-default; do
			printf '%s\n' "${path}"
		done
		shopt -u nullglob
	} | while IFS= read -r path; do
			[[ -d "${path}" ]] && printf '%s\n' "${path}"
		done | awk '!seen[$0]++'
}
