BEGIN {
  prefix = "PTT_E2E_MARKER " marker_name "="
}

index($0, prefix) {
  value = substr($0, index($0, prefix) + length(prefix))
}

END {
  # devicectl emits CRLF console records even when stdout is redirected.
  # Normalize the marker before the physical harness compares exact states.
  gsub(/\r/, "", value)
  if (value != "") print value
}
