#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 https://ptt.example.com calls.ptt.example.com turn.ptt.example.com" >&2
  exit 64
fi

control_origin="${1%/}"
calls_domain="$2"
turn_domain="$3"
dns_resolver="${PTT_CALLS_DNS_RESOLVER:-}"

[[ "$control_origin" == https://* ]] || { echo "Control origin must use HTTPS" >&2; exit 1; }
[[ "$calls_domain" != *:* && "$turn_domain" != *:* ]] || { echo "Pass hostnames without ports" >&2; exit 1; }
if [[ -n "$dns_resolver" && ! "$dns_resolver" =~ ^[0-9.]+$ ]]; then
  echo "PTT_CALLS_DNS_RESOLVER must be an IPv4 resolver address" >&2
  exit 1
fi

resolve_public_ipv4() {
  local domain="$1"
  if [[ -n "$dns_resolver" ]]; then
    dig +short "@$dns_resolver" "$domain" A
  else
    dig +short "$domain" A
  fi | awk '/^([0-9]{1,3}[.]){3}[0-9]{1,3}$/ { print; exit }'
}

calls_target="$calls_domain"
turn_target="$turn_domain"
if [[ -n "$dns_resolver" ]]; then
  calls_target="$(resolve_public_ipv4 "$calls_domain")"
  turn_target="$(resolve_public_ipv4 "$turn_domain")"
  [[ -n "$calls_target" ]] || { echo "No public DNS answer for $calls_domain" >&2; exit 1; }
  [[ -n "$turn_target" ]] || { echo "No public DNS answer for $turn_domain" >&2; exit 1; }
else
  for domain in "$calls_domain" "$turn_domain"; do
    if ! dig +short "$domain" A "$domain" AAAA | grep -q .; then
      echo "No public DNS answer for $domain" >&2
      exit 1
    fi
  done
fi

if [[ -n "$dns_resolver" ]]; then
  curl --fail --silent --show-error --max-time 10 \
    --resolve "$calls_domain:443:$calls_target" "https://$calls_domain/" >/dev/null
else
  curl --fail --silent --show-error --max-time 10 "https://$calls_domain/" >/dev/null
fi
nc -z -w 5 "$calls_target" "${PTT_CALLS_ICE_TCP_PORT:-7881}" >/dev/null 2>&1 || {
  echo "LiveKit ICE/TCP is unavailable on $calls_domain:${PTT_CALLS_ICE_TCP_PORT:-7881}" >&2
  exit 1
}
echo | openssl s_client -connect "$turn_target:5349" -servername "$turn_domain" -verify_return_error 2>/dev/null \
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
  # Use paired test clients so the allocation, permission, channel and relayed packets are all
  # exercised without relying on an operator-managed echo peer. Plain UDP proves the normal TURN
  # path; TLS/TCP proves the restrictive-network fallback. Certificate validation is performed
  # independently above because turnutils_uclient does not enable it by default.
  turnutils_uclient -y -c -p 3478 \
    -u "$PTT_TURN_USERNAME" -w "$PTT_TURN_PASSWORD" "$turn_target" >/dev/null
  turnutils_uclient -t -S -y -c -p 5349 \
    -u "$PTT_TURN_USERNAME" -w "$PTT_TURN_PASSWORD" "$turn_target" >/dev/null
  echo "Call signaling, TLS, ICE/TCP, media readiness, TURN/UDP, and TURN/TLS checks passed."
else
  echo "Call signaling, TLS certificate, ICE/TCP, and media-readiness checks passed."
fi
