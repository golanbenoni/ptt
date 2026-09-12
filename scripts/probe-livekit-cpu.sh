#!/usr/bin/env bash
# Sample a protected Prometheus endpoint across one LiveKit load window and
# print only the normalized process CPU percentage. The load driver consumes
# this value without exposing the metrics credential or raw labels.
set -euo pipefail

sum_process_cpu_seconds() {
  awk '
    $1 ~ /^process_cpu_seconds_total(\{[^}]*\})?$/ &&
      $2 ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ {
        total += $2
        found = 1
      }
    END {
      if (!found) exit 1
      printf "%.6f", total
    }
  '
}

normalized_cpu_percent() {
  local before="$1" after="$2" elapsed="$3" cores="$4"
  awk -v before="$before" -v after="$after" -v elapsed="$elapsed" -v cores="$cores" '
    BEGIN {
      delta = after - before
      if (delta < 0 || elapsed <= 0 || cores <= 0) exit 1
      printf "%.2f", (delta / elapsed / cores) * 100
    }
  '
}

valid_bearer_token() {
  local token="$1"
  local token_length="${#token}"
  (( token_length >= 16 && token_length <= 512 )) &&
    [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

if [[ "${1:-}" == --self-test ]]; then
  sample="$(printf '%s\n' \
    '# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.' \
    'process_cpu_seconds_total{instance="one"} 4.25' \
    'process_cpu_seconds_total{instance="two"} 5.75' |
    sum_process_cpu_seconds)"
  [[ "$sample" == 10.000000 ]]
  [[ "$(normalized_cpu_percent 100 112 10 4)" == 30.00 ]]
  valid_bearer_token '1234567890abcdef'
  if valid_bearer_token 'too-short' ||
     valid_bearer_token '1234567890abcde?' ||
     valid_bearer_token "$(printf '%0513d' 0)"; then
    echo "Bearer-token validation accepted an invalid value" >&2
    exit 1
  fi
  if normalized_cpu_percent 112 100 10 4 >/dev/null 2>&1; then
    echo "CPU counter reset was accepted" >&2
    exit 1
  fi
  echo "LiveKit CPU probe self-test passed"
  exit 0
fi

duration="${1:-}"
[[ "$duration" =~ ^[1-9][0-9]*s$ ]] || {
  echo "Usage: $0 POSITIVE_SECONDS or $0 --self-test" >&2
  exit 1
}
duration_seconds="${duration%s}"
(( duration_seconds <= 3600 )) || {
  echo "The CPU sampling window may not exceed 3600 seconds" >&2
  exit 1
}
: "${PTT_LIVEKIT_METRICS_URL:?PTT_LIVEKIT_METRICS_URL is required}"
: "${PTT_LIVEKIT_METRICS_BEARER_TOKEN:?PTT_LIVEKIT_METRICS_BEARER_TOKEN is required}"
: "${PTT_LIVEKIT_MEDIA_CPU_CORES:?PTT_LIVEKIT_MEDIA_CPU_CORES is required}"

case "$PTT_LIVEKIT_METRICS_URL" in
  https://*) ;;
  *) echo "PTT_LIVEKIT_METRICS_URL must use HTTPS" >&2; exit 1 ;;
esac
if [[ "$PTT_LIVEKIT_METRICS_URL" == *$'\n'* ||
      "$PTT_LIVEKIT_METRICS_URL" == *$'\r'* ||
      "$PTT_LIVEKIT_METRICS_URL" == *' '* ||
      "$PTT_LIVEKIT_METRICS_URL" == *'@'* ||
      "$PTT_LIVEKIT_METRICS_URL" == *'?'* ||
      "$PTT_LIVEKIT_METRICS_URL" == *'#'* ]]; then
  echo "PTT_LIVEKIT_METRICS_URL must be a canonical credential-free HTTPS URL" >&2
  exit 1
fi
valid_bearer_token "$PTT_LIVEKIT_METRICS_BEARER_TOKEN" || {
  echo "PTT_LIVEKIT_METRICS_BEARER_TOKEN has an invalid format" >&2
  exit 1
}
[[ "$PTT_LIVEKIT_MEDIA_CPU_CORES" =~ ^[1-9][0-9]*$ ]] || {
  echo "PTT_LIVEKIT_MEDIA_CPU_CORES must be a positive integer" >&2
  exit 1
}
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

work_dir="$(mktemp -d -t ptt-livekit-cpu.XXXXXX)"
cleanup() {
  find "$work_dir" -depth -delete
}
trap cleanup EXIT INT TERM
curl_config="$work_dir/curl.conf"
umask 077
printf '%s\n' \
  'silent' \
  'show-error' \
  'fail' \
  'connect-timeout = 5' \
  'max-time = 10' \
  "header = \"Authorization: Bearer $PTT_LIVEKIT_METRICS_BEARER_TOKEN\"" \
  >"$curl_config"

sample_cpu() {
  curl --disable --config "$curl_config" "$PTT_LIVEKIT_METRICS_URL" |
    sum_process_cpu_seconds
}

before="$(sample_cpu)" || {
  echo "LiveKit metrics did not expose process_cpu_seconds_total" >&2
  exit 1
}
started_at="$(python3 -c 'import time; print(time.monotonic())')"
sleep "$duration_seconds"
after="$(sample_cpu)" || {
  echo "LiveKit metrics did not expose process_cpu_seconds_total after the load window" >&2
  exit 1
}
finished_at="$(python3 -c 'import time; print(time.monotonic())')"
elapsed="$(awk -v start="$started_at" -v finish="$finished_at" 'BEGIN { printf "%.6f", finish-start }')"
normalized_cpu_percent "$before" "$after" "$elapsed" "$PTT_LIVEKIT_MEDIA_CPU_CORES"
printf '\n'
