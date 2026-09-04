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
# Scan the deployable container and Kubernetes configuration with the chart's
# supported minimum version and synthetic required values. No live secret is
# needed or allowed in this report.
trivy fs --skip-version-check --scanners misconfig \
  --misconfig-scanners dockerfile,helm,kubernetes \
  --helm-kube-version 1.28.0 \
  --helm-set 'secrets.databasePassword=test-only,secrets.redisPassword=test-only,secrets.objectStorePassword=test-only,secrets.bootstrapToken=test-only-32-byte-bootstrap-token,secrets.relaySharedSecret=test-only-32-byte-relay-shared-key,secrets.metricsToken=test-only-32-byte-metrics-access-key' \
  --severity HIGH,CRITICAL --exit-code 1 --format json \
  --output "$report_dir/trivy-misconfig.json" "$@" .
# Fail releases for every known fixed high or critical vulnerability. The same
# findings remain available in a machine-readable report for release evidence.
trivy fs --skip-version-check --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
  --exit-code 1 --format json --output "$report_dir/trivy-review.json" "$@" .

syft scan dir:. --quiet \
  --exclude './.git/**' \
  --exclude './**/build/**' \
  --exclude './**/target/**' \
  --exclude './**/node_modules/**' \
  --exclude './**/.build/**' \
  --exclude './**/.derived*/**' \
  --source-name ptt-talk \
  --output "cyclonedx-json=$report_dir/sbom.cdx.json"

test -s "$report_dir/trivy-review.json"
test -s "$report_dir/trivy-misconfig.json"
test -s "$report_dir/sbom.cdx.json"
echo "Security scans and CycloneDX SBOM: ok"
