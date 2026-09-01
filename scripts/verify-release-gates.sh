#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

if [[ -z "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$(gh auth token)"
fi
: "${GH_TOKEN:?GH_TOKEN is required}"

github_api_url="${GITHUB_API_URL:-https://api.github.com}"

require_successful_workflow() {
  local workflow="$1"
  local label="$2"
  local response
  response="$(curl --fail --silent --show-error \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "$github_api_url/repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?head_sha=$GITHUB_SHA&status=success&per_page=1")"
  if ! grep -Eq '"total_count"[[:space:]]*:[[:space:]]*[1-9][0-9]*' <<<"$response"; then
    echo "Release blocked: $label has not passed for commit $GITHUB_SHA." >&2
    echo "Run $workflow for this exact commit, fix any failure, and retry the release." >&2
    return 1
  fi
  echo "$label passed for commit $GITHUB_SHA"
}

require_successful_workflow ci.yml "complete CI"
require_successful_workflow voice-release.yml "bidirectional production voice gate"
if [[ "${PTT_SKIP_PHYSICAL_RELEASE_GATE:-0}" == 1 ]]; then
  echo "Physical-device gate lookup deferred to the physical-release workflow that is currently running"
else
  require_successful_workflow physical-release.yml "four-device physical parity gate"
fi
if [[ "${PTT_SKIP_ANDROID_SOAK_GATE:-0}" == 1 ]]; then
  echo "Android soak gate lookup deferred to the android-soak workflow that is currently running"
else
  require_successful_workflow android-soak.yml "eight-hour Android screen-off receive soak"
fi

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
