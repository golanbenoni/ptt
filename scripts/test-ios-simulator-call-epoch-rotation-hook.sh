#!/usr/bin/env bash
# Force a live iOS simulator call through direct-to-private-group conversion and require both
# product instances to install and acknowledge the resulting epoch before the proof continues.
set -euo pipefail

: "${PTT_CALL_ACTIVE_CALLER_CONTAINER:?PTT_CALL_ACTIVE_CALLER_CONTAINER is required}"
: "${PTT_CALL_ACTIVE_CALLEE_CONTAINER:?PTT_CALL_ACTIVE_CALLEE_CONTAINER is required}"
: "${PTT_CALL_ACTIVE_CALL_ID:?PTT_CALL_ACTIVE_CALL_ID is required}"
: "${PTT_CALL_SERVER:?PTT_CALL_SERVER is required}"
: "${PTT_CALL_CALLER_TOKEN:?PTT_CALL_CALLER_TOKEN is required}"

INVITEE_ACI="${PTT_CALL_ROTATION_INVITEE_ACI:-33333333-3333-4333-8333-333333333333}"
TIMEOUT_SECONDS="${PTT_CALL_ROTATION_TIMEOUT_SECONDS:-20}"

for command in curl jq; do
  command -v "$command" >/dev/null || { echo "Missing call-rotation dependency: $command" >&2; exit 1; }
done
[[ "$PTT_CALL_ACTIVE_CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || {
  echo "The active call ID is invalid." >&2
  exit 1
}
[[ "$INVITEE_ACI" =~ ^[A-Fa-f0-9-]{36}$ ]] || {
  echo "The rotation invitee ACI is invalid." >&2
  exit 1
}
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "PTT_CALL_ROTATION_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
}

read_marker() {
  local marker="$1/Documents/ptt-e2e-$2.txt"
  [[ -f "$marker" ]] && tr -d '\r\n' <"$marker" || true
}

before="$(curl --fail --silent --show-error \
  -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  "$PTT_CALL_SERVER/v1/calls/$PTT_CALL_ACTIVE_CALL_ID")"
before_epoch="$(printf '%s' "$before" | jq -er '.callEpoch')"
before_conversation="$(printf '%s' "$before" | jq -er '.conversationId')"
request="$(jq -cn --arg invitee "$INVITEE_ACI" \
  '{invitees:[$invitee],confirmCreatePrivateGroup:true,displayName:"Epoch rotation proof"}')"
after="$(curl --fail --silent --show-error \
  -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$request" \
  "$PTT_CALL_SERVER/v1/calls/$PTT_CALL_ACTIVE_CALL_ID/participants")"
after_epoch="$(printf '%s' "$after" | jq -er '.callEpoch')"
after_conversation="$(printf '%s' "$after" | jq -er '.conversationId')"

(( after_epoch == before_epoch + 1 )) || {
  echo "Adding a participant did not advance the call epoch exactly once." >&2
  exit 1
}
[[ "$after_conversation" != "$before_conversation" ]] || {
  echo "Adding a third participant did not confirm and create a private-group conversation." >&2
  exit 1
}

for container in "$PTT_CALL_ACTIVE_CALLER_CONTAINER" "$PTT_CALL_ACTIVE_CALLEE_CONTAINER"; do
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    state="$(read_marker "$container" call-state)"
    secured_epoch="$(read_marker "$container" call-secured-media-epoch)"
    [[ "$state" == fail:* ]] && {
      echo "An iOS simulator failed during epoch rotation: $state" >&2
      exit 1
    }
    [[ "$secured_epoch" == "$after_epoch" ]] && break
    sleep 1
  done
  [[ "$(read_marker "$container" call-secured-media-epoch)" == "$after_epoch" ]] || {
    echo "An iOS simulator did not secure rotated call epoch $after_epoch." >&2
    exit 1
  }
done

echo "Both iOS simulator clients secured call epoch $after_epoch after private-group conversion."
