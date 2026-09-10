#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d -t ptt-call-validator.XXXXXX)"
MOCK_BIN="$WORK_DIR/bin"
TURN_LOG="$WORK_DIR/turn.log"

cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
[[ "${PTT_TEST_NO_DNS:-0}" != 1 ]] && echo 192.0.2.1
MOCK
cat >"$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
url=""
for argument in "$@"; do url="$argument"; done
if [[ "$url" == */v1/capabilities ]]; then
  printf '%s' '{"callProtocol":{"major":1},"maximumParticipants":8,"mediaReady":true,"enabled":true}'
fi
MOCK
cat >"$MOCK_BIN/nc" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat >"$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == s_client ]]; then printf '%s\n' certificate-fixture; fi
exit 0
MOCK
cat >"$MOCK_BIN/turnutils_uclient" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$PTT_TEST_TURN_LOG"
printf '\n' >>"$PTT_TEST_TURN_LOG"
MOCK
chmod +x "$MOCK_BIN"/*

PATH="$MOCK_BIN:$PATH" "$ROOT/scripts/validate-calls-deployment.sh" \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com \
  >"$WORK_DIR/basic.out"
grep -q 'media-readiness checks passed' "$WORK_DIR/basic.out"
test ! -e "$TURN_LOG"

PATH="$MOCK_BIN:$PATH" PTT_TEST_TURN_LOG="$TURN_LOG" \
PTT_CALLS_REQUIRE_TURN_PROBE=1 PTT_TURN_USERNAME=test-user PTT_TURN_PASSWORD=test-password \
  "$ROOT/scripts/validate-calls-deployment.sh" \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com \
  >"$WORK_DIR/full.out"
grep -q 'TURN/UDP, and TURN/TLS checks passed' "$WORK_DIR/full.out"
test "$(wc -l <"$TURN_LOG" | tr -d ' ')" = 2
sed -n '1p' "$TURN_LOG" | grep -q -- '-y -c -p 3478'
sed -n '2p' "$TURN_LOG" | grep -q -- '-t -S -y -c -p 5349'

: >"$TURN_LOG"
PATH="$MOCK_BIN:$PATH" PTT_TEST_TURN_LOG="$TURN_LOG" \
PTT_CALLS_DNS_RESOLVER=1.1.1.1 PTT_CALLS_REQUIRE_TURN_PROBE=1 \
PTT_TURN_USERNAME=test-user PTT_TURN_PASSWORD=test-password \
  "$ROOT/scripts/validate-calls-deployment.sh" \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com \
  >"$WORK_DIR/public-resolver.out"
grep -q 'TURN/UDP, and TURN/TLS checks passed' "$WORK_DIR/public-resolver.out"
test "$(wc -l <"$TURN_LOG" | tr -d ' ')" = 2
sed -n '1p' "$TURN_LOG" | grep -q -- '192.0.2.1'
sed -n '2p' "$TURN_LOG" | grep -q -- '192.0.2.1'

if PATH="$MOCK_BIN:$PATH" PTT_CALLS_DNS_RESOLVER=resolver.example \
  "$ROOT/scripts/validate-calls-deployment.sh" \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com \
  >"$WORK_DIR/invalid-resolver.out" 2>&1; then
  echo "Call deployment validator accepted a non-address DNS resolver" >&2
  exit 1
fi
grep -q 'must be an IPv4 resolver address' "$WORK_DIR/invalid-resolver.out"

if PATH="$MOCK_BIN:$PATH" PTT_TEST_NO_DNS=1 \
  "$ROOT/scripts/validate-calls-deployment.sh" \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com \
  >"$WORK_DIR/no-dns.out" 2>&1; then
  echo "Call deployment validator accepted missing public DNS" >&2
  exit 1
fi
grep -q 'No public DNS answer' "$WORK_DIR/no-dns.out"

echo "Call deployment validator fail-closed fixtures passed."
