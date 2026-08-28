#!/bin/sh
set -eu

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
test "$#" -gt 0

tag="${PTT_INTERNAL_RELEASE_TAG:-ptt-internal-builds}"
api="https://api.github.com/repos/$GITHUB_REPOSITORY"
headers="Accept: application/vnd.github+json"
version_header="X-GitHub-Api-Version: 2022-11-28"

release_response=$(curl -sS \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "$headers" \
  -H "$version_header" \
  "$api/releases/tags/$tag")
release_id=$(printf '%s' "$release_response" | jq -r '.id // empty')

if [ -z "$release_id" ]; then
  payload=$(jq -nc \
    --arg tag "$tag" \
    --arg target "$GITHUB_SHA" \
    '{tag_name:$tag,target_commitish:$target,name:"PTT Talk internal build artifacts",body:"Private build handoff for Play internal testing and TestFlight.",draft:true,prerelease:true}')
  release_response=$(curl -fsS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "$headers" \
    -H "$version_header" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$api/releases")
  release_id=$(printf '%s' "$release_response" | jq -er '.id')
fi

for asset in "$@"; do
  test -f "$asset"
  name=$(basename "$asset")
  encoded_name=$(jq -nr --arg name "$name" '$name | @uri')
  curl -fsS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "$headers" \
    -H "$version_header" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$asset" \
    "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$release_id/assets?name=$encoded_name" | \
    jq -e '.state == "uploaded"' >/dev/null
  printf 'uploaded %s\n' "$name"
done
