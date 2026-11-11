# shellcheck shell=bash
# 02_policies.sh — Task 1: enterprise policy injection.
#
# Two targets are written, both containing identical content:
#
#   /etc/firefox/policies/policies.json
#       The path documented by Mozilla for all Linux distributions.
#       The Firefox Snap reads /etc through its AppArmor profile.
#       Source: https://firefox-admin-docs.mozilla.org/guides/policies-configuration/
#
#   /var/snap/firefox/common/distribution/policies.json
#       A supplementary path used by Canonical's Ubuntu snap packaging.
#       Not in Mozilla's documentation; present because the snap recipe
#       configures Firefox to also search this location.
#
# mozilla.cfg / autoconfig.js are intentionally NOT written.
# Those files require a pointer in defaults/pref/ of the installation directory, which lives under read-only /snap/firefox/current/ in the snap. Writing to /var/snap/firefox/common/defaults/pref/ has no effect.

_firephlox_policies_json() {
	# Emit the policies JSON body on stdout so callers can pipe it to a file.
	cat <<'JSON'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "Preferences": {
      "extensions.enabled": {
        "Value": true,
        "Status": "locked"
      },
      "xpinstall.enabled": {
        "Value": true,
        "Status": "locked"
      },
      "toolkit.telemetry.cachedClientID": {
        "Value": "00000000-0000-0000-0000-000000000000",
        "Status": "locked"
      },
      "browser.newtabpage.activity-stream.impressionId": {
        "Value": "{}",
        "Status": "locked"
      },
      "toolkit.telemetry.unified": {
        "Value": false,
        "Status": "locked"
      },
      "toolkit.telemetry.server": {
        "Value": "http://127.0.0.1",
        "Status": "locked"
      }
    }
  }
}
JSON
}

firephlox_apply_policies() {
	firephlox_section 'Task 1 · Enterprise policy injection'

	# Primary: the Mozilla-documented system-wide path for Linux.
	_firephlox_policies_json | firephlox_write_file "${FIREPHLOX_ETC_POLICIES_FILE}" 0644
	firephlox_ok "policies.json → ${FIREPHLOX_ETC_POLICIES_FILE}"

	# Supplementary: the Ubuntu snap distribution directory.
	_firephlox_policies_json | firephlox_write_file "${FIREPHLOX_SNAP_POLICIES_FILE}" 0644
	firephlox_ok "policies.json → ${FIREPHLOX_SNAP_POLICIES_FILE}"
}
