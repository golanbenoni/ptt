#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 https://ptt.example.com calls.ptt.example.com turn.ptt.example.com" >&2
  exit 64
fi

control_origin="${1%/}"
calls_domain="$2"
turn_domain="$3"

[[ "$control_origin" == https://* ]] || { echo "Control origin must use HTTPS" >&2; exit 1; }
[[ "$calls_domain" != *:* && "$turn_domain" != *:* ]] || { echo "Pass hostnames without ports" >&2; exit 1; }

for domain in "$calls_domain" "$turn_domain"; do
  if ! dig +short "$domain" A "$domain" AAAA | grep -q .; then
    echo "No public DNS answer for $domain" >&2
    exit 1
  fi
done

curl --fail --silent --show-error --max-time 10 "https://$calls_domain/" >/dev/null
echo | openssl s_client -connect "$turn_domain:5349" -servername "$turn_domain" -verify_return_error 2>/dev/null \
  | openssl x509 -noout -checkend 604800 >/dev/null

capabilities="$(curl --fail --silent --show-error --max-time 10 "$control_origin/v1/capabilities")"
CAPABILITIES="$capabilities" node -e '
const value = JSON.parse(process.env.CAPABILITIES);
if (value?.callProtocol?.major !== 1 || value?.maximumParticipants !== 8 || value?.mediaReady !== true || value?.enabled !== true) {
  throw new Error("Control plane does not advertise a ready call protocol v1 media service");
}
'

if [[ "${PTT_CALLS_REQUIRE_TURN_PROBE:-0}" == 1 ]]; then
  command -v turnutils_uclient >/dev/null || {
    echo "turnutils_uclient is required for the release TURN probe" >&2
    exit 1
  }
  [[ -n "${PTT_TURN_USERNAME:-}" && -n "${PTT_TURN_PASSWORD:-}" ]] || {
    echo "PTT_TURN_USERNAME and PTT_TURN_PASSWORD are required for the release TURN probe" >&2
    exit 1
  }
  turnutils_uclient -t -S -p 5349 -u "$PTT_TURN_USERNAME" -w "$PTT_TURN_PASSWORD" "$turn_domain" >/dev/null
fi

echo "Call signaling, TLS, media readiness, and configured TURN checks passed."
