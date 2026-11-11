# shellcheck shell=bash
# 07_sign_amo.sh — Task 5: sign the extension XPI via Mozilla's AMO API.
#
# Firefox Release enforces extension signatures at the binary level.
# xpinstall.signatures.required is ignored in Release builds regardless of user.js or enterprise policy. The only solution is a signed XPI.
#
# Credentials: https://addons.mozilla.org/en-US/developers/addon/api/key/
#   FIREPHLOX_AMO_KEY    — API Key (jwtiss field)
#   FIREPHLOX_AMO_SECRET — API Secret
# Both can be exported as environment variables or entered interactively.

readonly FIREPHLOX_SIGNED_XPI_CACHE="${HOME}/.cache/firephlox"
readonly FIREPHLOX_SIGNED_XPI="${FIREPHLOX_SIGNED_XPI_CACHE}/apple-music-shuffle@firephlox-signed.xpi"

firephlox_sign_amo() {
	firephlox_section 'Task 5 · AMO extension signing'

	if [[ "${FIREPHLOX_SIGN:-0}" != '1' ]]; then
		if [[ -f "${FIREPHLOX_SIGNED_XPI}" ]]; then
			local age_days
			age_days=$(( ( $(date +%s) - $(stat -c %Y "${FIREPHLOX_SIGNED_XPI}") ) / 86400 ))
			firephlox_ok "Using cached signed XPI (${age_days}d old): ${FIREPHLOX_SIGNED_XPI}"
		else
			firephlox_warn 'Extension not signed — run with --sign to sign it via AMO.'
			firephlox_warn 'Until signed, Firefox Release will not load the extension.'
			firephlox_info 'Credentials: https://addons.mozilla.org/en-US/developers/addon/api/key/'
		fi
		return 0
	fi

	local api_key="${FIREPHLOX_AMO_KEY:-}"
	local api_secret="${FIREPHLOX_AMO_SECRET:-}"

	if [[ -z "${api_key}" ]]; then
		firephlox_info 'Get credentials at: https://addons.mozilla.org/en-US/developers/addon/api/key/'
		printf '  AMO API Key: '
		read -r api_key
	fi
	if [[ -z "${api_secret}" ]]; then
		printf '  AMO API Secret: '
		read -rs api_secret
		printf '\n'
	fi

	[[ -z "${api_key}" || -z "${api_secret}" ]] && firephlox_die 'AMO credentials are required.'

	# The unsigned XPI to submit must already exist from Task 4.
	local ext_id='apple-music-shuffle@firephlox'
	local unsigned_xpi="${HOME}/snap/firefox/common/extensions/${ext_id}.xpi"
	[[ -f "${unsigned_xpi}" ]] || firephlox_die "Unsigned XPI not found: ${unsigned_xpi} (run firephlox without --sign first)"

	firephlox_info 'Submitting XPI to AMO for signing…'
	firephlox_mkdir "${FIREPHLOX_SIGNED_XPI_CACHE}"

	python3 - "${unsigned_xpi}" "${api_key}" "${api_secret}" "${ext_id}" "${FIREPHLOX_SIGNED_XPI}" <<'PYTHON'
import sys, json, time, hashlib, hmac, base64, uuid, urllib.request, urllib.error, os

unsigned_xpi, api_key, api_secret, ext_id, out_path = sys.argv[1:6]

# --- 1. Build JWT -----------------------------------------------------------
iat = int(time.time())
exp = iat + 300

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')

hdr = b64url(json.dumps({"typ": "JWT", "alg": "HS256"}).encode())
pld = b64url(json.dumps({"iss": api_key, "jti": str(uuid.uuid4()), "iat": iat, "exp": exp}).encode())
sig = b64url(hmac.new(api_secret.encode(), hdr + b'.' + pld, hashlib.sha256).digest())
jwt = (hdr + b'.' + pld + b'.' + sig).decode()

headers = {'Authorisation': f'JWT {jwt}'}

# --- 2. Upload XPI via AMO API v5 -------------------------------------------
import urllib.parse, zipfile, io

# Read manifest for the version number.
with zipfile.ZipFile(unsigned_xpi) as z:
    manifest = json.loads(z.read('manifest.json'))
version = manifest['version']
guid    = urllib.parse.quote(ext_id, safe='')

url = f'https://addons.mozilla.org/api/v5/addons/{guid}/versions/{version}/'

boundary = uuid.uuid4().hex
with open(unsigned_xpi, 'rb') as f:
    xpi_bytes = f.read()

body = (
    f'--{boundary}\r\nContent-Disposition: form-data; name="upload"; '
    f'filename="extension.xpi"\r\nContent-Type: application/x-xpinstall\r\n\r\n'
).encode() + xpi_bytes + f'\r\n--{boundary}--\r\n'.encode()

req = urllib.request.Request(
    url, data=body,
    headers={**headers, 'Content-Type': f'multipart/form-data; boundary={boundary}'},
    method='PUT'
)

try:
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f'AMO API error {e.code}: {body}', file=sys.stderr)
    sys.exit(1)

print(f'  Submitted version {version}. Polling for signing…')

# --- 3. Poll until signed ---------------------------------------------------
poll_url = url
for attempt in range(60):
    time.sleep(5)
    req = urllib.request.Request(poll_url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    if data.get('processed'):
        break
    if attempt % 6 == 0:
        print(f'  Waiting… (attempt {attempt + 1})')

files = data.get('files', [])
if not files or not files[0].get('download_url'):
    print(f'Signing failed or timed out. AMO response:\n{json.dumps(data, indent=2)}', file=sys.stderr)
    sys.exit(1)

# --- 4. Download signed XPI -------------------------------------------------
signed_url = files[0]['download_url']
req = urllib.request.Request(signed_url, headers=headers)
with urllib.request.urlopen(req) as resp:
    with open(out_path, 'wb') as f:
        f.write(resp.read())

print(f'  Signed XPI saved to {out_path}')
PYTHON

	firephlox_ok "Extension signed → ${FIREPHLOX_SIGNED_XPI}"
	firephlox_info 'Re-run firephlox (without --sign) to deploy the signed XPI.'
}
