#!/bin/sh
set -eu

work_dir=$(mktemp -d -t ptt-security-timeout.XXXXXX)
cleanup() {
  find "$work_dir" -depth -delete
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$work_dir/bin"

cat >"$work_dir/bin/trivy" <<'MOCK'
#!/bin/sh
set -eu
{
  echo CALL
  for arg in "$@"; do
    printf 'ARG=%s\n' "$arg"
  done
} >>"$PTT_FAKE_TRIVY_LOG"

while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    shift
    printf '{}\n' >"$1"
  fi
  shift
done
MOCK

cat >"$work_dir/bin/syft" <<'MOCK'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    shift
    output=${1#cyclonedx-json=}
    printf '{}\n' >"$output"
  fi
  shift
done
MOCK

chmod +x "$work_dir/bin/trivy" "$work_dir/bin/syft"
: >"$work_dir/trivy.log"

PATH="$work_dir/bin:$PATH" \
PTT_FAKE_TRIVY_LOG="$work_dir/trivy.log" \
PTT_SECURITY_REPORT_DIR="$work_dir/reports" \
PTT_TRIVY_TIMEOUT=17m \
  ./scripts/security-audit.sh >/dev/null

test "$(grep -c '^CALL$' "$work_dir/trivy.log")" -eq 3
test "$(grep -c '^ARG=17m$' "$work_dir/trivy.log")" -eq 3
awk '
  previous == "ARG=--timeout" && $0 == "ARG=17m" { matched += 1 }
  { previous = $0 }
  END { exit matched == 3 ? 0 : 1 }
' "$work_dir/trivy.log"

echo "Security audit timeout propagation: ok"
