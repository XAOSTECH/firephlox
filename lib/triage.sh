# shellcheck shell=bash
# triage.sh — reusable diagnostic primitives for the firephlox triage-kit.
#
# Functions defined here are sourced by the main orchestrator alongside
# colours.sh, common.sh, and titles.sh, making them available to all
# src/ modules: triage.sh, revive.sh, and eliminate.sh.
#
#   _fp_triage_sqlite_check <path>
#       Returns "ok" or an error description for a SQLite database.
#       Always exits 0 so set -e does not abort the caller on a corrupt file.
#
#   _fp_triage_pref <prefs.js> <key>
#       Prints the raw value of a named pref, or empty string if absent.
#       Always exits 0.

[[ -n "${FIREPHLOX_TRIAGE_LIB_SOURCED:-}" ]] && return 0
readonly FIREPHLOX_TRIAGE_LIB_SOURCED=1

_fp_triage_sqlite_check() {
	python3 - "$1" <<'PYTHON' || printf 'unreadable: python3 error\n'
import sqlite3, sys
try:
    conn = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    r = conn.execute('PRAGMA integrity_check').fetchone()
    conn.close()
    print('ok' if r[0] == 'ok' else f'corrupt: {r[0]}')
except Exception as e:
    print(f'unreadable: {e}')
PYTHON
}

_fp_triage_pref() {
	python3 - "$1" "$2" <<'PYTHON' 2>/dev/null || true
import sys, re
pattern = re.compile(r'^user_pref\("' + re.escape(sys.argv[2]) + r'",\s*(.*)\);')
for line in open(sys.argv[1]):
    m = pattern.match(line.strip())
    if m:
        print(m.group(1))
        sys.exit(0)
PYTHON
}
