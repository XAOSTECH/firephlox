# shellcheck shell=bash
# 06_shuffle.sh — Task 4: deploy the Apple Music True Shuffle as a native
# WebExtension via enterprise ExtensionSettings policy.
#
# Extensions installed through enterprise policies are not required to be signed by Mozilla, bypassing the need for any userscript manager.
# Source: https://github.com/mozilla/policy-templates

# _firephlox_shuffle_build_xpi <dest_xpi> <js_src> <ext_id>
# Creates the XPI (ZIP) in a temp path then installs it at <dest_xpi>, escalating with sudo when the target directory is not writable.
_firephlox_shuffle_build_xpi() {
	local dest="$1" js_src="$2" ext_id="$3"
	local tmp
	tmp="$(mktemp --suffix=.xpi)"
	# shellcheck disable=SC2064
	trap "rm -f '${tmp}'" RETURN

	python3 - "${tmp}" "${js_src}" "${ext_id}" <<'PYTHON'
import sys, zipfile, json

tmp, js_src, ext_id = sys.argv[1], sys.argv[2], sys.argv[3]

manifest = {
    "manifest_version": 2,
    "name": "Apple Music True Shuffle",
    "version": "1.0.2",
    "description": "True-random queue shuffle for Apple Music — no data collection, deployed by firephlox.",
    "browser_specific_settings": {
        "gecko": {"id": ext_id}
    },
    "content_scripts": [{
        "matches": ["*://music.apple.com/*"],
        "js": ["shuffle.js"],
        "run_at": "document_idle"
    }]
}

with open(js_src, encoding='utf-8') as f:
    js = f.read()

with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('manifest.json', json.dumps(manifest, indent=2))
    z.writestr('shuffle.js', js)
PYTHON

	firephlox_mkdir "$(dirname "${dest}")"
	if firephlox_path_writable "$(dirname "${dest}")"; then
		install -m 0644 "${tmp}" "${dest}"
	else
		firephlox_privileged install -m 0644 "${tmp}" "${dest}"
	fi
}

# _firephlox_shuffle_add_policy <policies_file> <ext_id> <xpi_path>
# Merges an ExtensionSettings force_installed entry into the given policies.json, reading and writing via sudo when the file is root-owned.
_firephlox_shuffle_add_policy() {
	local policies_file="$1" ext_id="$2" xpi_path="$3"
	[[ -f "${policies_file}" ]] || {
		firephlox_warn "policies.json not found, skipping: ${policies_file}"
		return 0
	}

	local tmp
	tmp="$(mktemp)"
	# shellcheck disable=SC2064
	trap "rm -f '${tmp}'" RETURN

	if firephlox_path_writable "${policies_file}"; then
		cp "${policies_file}" "${tmp}"
	else
		firephlox_privileged cp "${policies_file}" "${tmp}"
	fi

	FIREPHLOX_EXT_ID="${ext_id}" \
	FIREPHLOX_INSTALL_URL="file://${xpi_path}" \
	python3 - "${tmp}" <<'PYTHON' | firephlox_write_file "${policies_file}" 0644
import os, sys, json

data = json.load(open(sys.argv[1]))
data.setdefault('policies', {}) \
    .setdefault('ExtensionSettings', {})[os.environ['FIREPHLOX_EXT_ID']] = {
        'installation_mode': 'force_installed',
        'install_url': os.environ['FIREPHLOX_INSTALL_URL'],
    }
print(json.dumps(data, indent=2))
PYTHON
}

firephlox_deploy_shuffle() {
	firephlox_section 'Task 4 · Apple Music True Shuffle'

	if [[ "${FIREPHLOX_SKIP_SHUFFLE:-0}" == '1' ]]; then
		firephlox_info 'Shuffle deployment skipped (--no-shuffle).'
		return 0
	fi

	local ext_id='apple-music-shuffle@firephlox'
	local xpi_path="${HOME}/snap/firefox/common/extensions/${ext_id}.xpi"
	local xpi_dist="${FIREPHLOX_DISTRIBUTION_DIR}/extensions/${ext_id}.xpi"
	local js_src="${FIREPHLOX_ROOT}/assets/shuffle.js"

	[[ -f "${js_src}" ]] || firephlox_die "Missing asset: ${js_src}"

	if firephlox_is_dry_run; then
		firephlox_info "(dry-run) build XPI → ${xpi_path}"
		firephlox_info "(dry-run) build XPI → ${xpi_dist} (distribution)"
		firephlox_info "(dry-run) add ExtensionSettings → ${FIREPHLOX_ETC_POLICIES_FILE}"
		firephlox_info "(dry-run) add ExtensionSettings → ${FIREPHLOX_SNAP_POLICIES_FILE}"
		return 0
	fi

	_firephlox_shuffle_build_xpi "${xpi_path}" "${js_src}" "${ext_id}"
	local size_kb; size_kb="$(du -k "${xpi_path}" 2>/dev/null | cut -f1 || echo '?')"

	# Use the signed XPI for all deployments if available (Task 5 produces it).
	local deploy_xpi="${xpi_path}"
	if [[ -f "${FIREPHLOX_SIGNED_XPI:-}" ]]; then
		deploy_xpi="${FIREPHLOX_SIGNED_XPI}"
		firephlox_ok "Signed XPI (${size_kb}K) → ${xpi_path} (unsigned copy also built)"
		firephlox_ok "Using signed XPI: ${deploy_xpi}"
	else
		firephlox_ok "Extension XPI (${size_kb}K) → ${xpi_path} ${FP_DIM}(unsigned — run --sign to fix)${FP_RESET}"
		firephlox_info "install_url will be: file://${xpi_path}"
	fi

	cp "${deploy_xpi}" "${xpi_path}"
	_firephlox_shuffle_build_xpi "${xpi_dist}" "${js_src}" "${ext_id}"
	[[ -f "${FIREPHLOX_SIGNED_XPI:-}" ]] && cp "${deploy_xpi}" "${xpi_dist}"
	firephlox_ok "Extension XPI (distribution) → ${xpi_dist}"

	_firephlox_shuffle_add_policy "${FIREPHLOX_ETC_POLICIES_FILE}"  "${ext_id}" "${xpi_path}"
	_firephlox_shuffle_add_policy "${FIREPHLOX_SNAP_POLICIES_FILE}" "${ext_id}" "${xpi_path}"
	firephlox_ok "ExtensionSettings (force_installed) added to both policies.json files"

	local -a profiles
	mapfile -t profiles < <(firephlox_discover_profiles)
	for profile in "${profiles[@]}"; do
		firephlox_mkdir "${profile}/extensions"
		install -m 0644 "${deploy_xpi}" "${profile}/extensions/${ext_id}.xpi"
		firephlox_ok "Extension XPI (profile) → ${profile}/extensions/${ext_id}.xpi"
	done

	firephlox_info "Content script JS: ${js_src} ($(wc -c < "${js_src}") bytes)"
}
