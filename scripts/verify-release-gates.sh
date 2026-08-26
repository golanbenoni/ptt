#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

require_successful_workflow() {
  local workflow="$1"
  local label="$2"
  local run
  run="$(gh run list \
    --repo "$GITHUB_REPOSITORY" \
    --workflow "$workflow" \
    --commit "$GITHUB_SHA" \
    --limit 20 \
    --json databaseId,conclusion,url \
    --jq 'map(select(.conclusion == "success")) | first | if . then "\(.databaseId) \(.url)" else "" end')"
  if [[ -z "$run" ]]; then
    echo "Release blocked: $label has not passed for commit $GITHUB_SHA." >&2
    echo "Run $workflow for this exact commit, fix any failure, and retry the release." >&2
    return 1
  fi
  echo "$label passed: $run"
}

require_successful_workflow ci.yml "complete CI"
require_successful_workflow voice-release.yml "bidirectional production voice gate"

ios_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' \
  ios/TalkApp/TalkApp.xcodeproj/project.pbxproj | sort -u)"
ios_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' \
  ios/TalkApp/TalkApp.xcodeproj/project.pbxproj | sort -u)"
android_version="$(sed -nE 's/^[[:space:]]*versionName = "([^"]+)"/\1/p' \
  android/talk/build.gradle.kts | head -1)"
android_build="$(sed -nE 's/^[[:space:]]*versionCode = ([0-9]+)/\1/p' \
  android/talk/build.gradle.kts | head -1)"

if [[ -z "$ios_version" || "$ios_version" == *$'\n'* ||
      -z "$ios_build" || "$ios_build" == *$'\n'* ||
      "$ios_version" != "$android_version" || "$ios_build" != "$android_build" ]]; then
  echo "Release blocked: iOS and Android versions are not a single synchronized value." >&2
  printf 'iOS=%q (%q), Android=%q (%q)\n' \
    "$ios_version" "$ios_build" "$android_version" "$android_build" >&2
  exit 1
fi

echo "Synchronized mobile release: $ios_version ($ios_build)"
