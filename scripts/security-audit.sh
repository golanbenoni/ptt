#!/bin/sh
set -eu

command -v trivy >/dev/null || {
  echo "trivy is required for vulnerability and secret scanning" >&2
  exit 1
}
command -v syft >/dev/null || {
  echo "syft is required for CycloneDX SBOM generation" >&2
  exit 1
}

report_dir=${PTT_SECURITY_REPORT_DIR:-build/security}
mkdir -p "$report_dir"

set -- \
  --skip-dirs .git \
  --skip-dirs build \
  --skip-dirs target \
  --skip-dirs node_modules \
  --skip-dirs '**/.build' \
  --skip-dirs '**/.build/**' \
  --skip-dirs '**/.derived*' \
  --skip-dirs '**/.derived*/**'

trivy fs --skip-version-check --scanners secret --exit-code 1 "$@" .
# Fail releases for known fixed critical vulnerabilities. High-severity results
# remain visible in the machine-readable report for explicit release review.
trivy fs --skip-version-check --scanners vuln --severity CRITICAL --ignore-unfixed \
  --exit-code 1 --format json --output "$report_dir/trivy-critical.json" "$@" .
trivy fs --skip-version-check --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
  --exit-code 0 --format json --output "$report_dir/trivy-review.json" "$@" .

syft scan dir:. --quiet \
  --exclude './.git/**' \
  --exclude './**/build/**' \
  --exclude './**/target/**' \
  --exclude './**/node_modules/**' \
  --exclude './**/.build/**' \
  --exclude './**/.derived*/**' \
  --source-name ptt-talk \
  --output "cyclonedx-json=$report_dir/sbom.cdx.json"

test -s "$report_dir/trivy-critical.json"
test -s "$report_dir/trivy-review.json"
test -s "$report_dir/sbom.cdx.json"
echo "Security scans and CycloneDX SBOM: ok"
