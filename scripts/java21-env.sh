#!/usr/bin/env bash
# Source this file to select a JDK 21 runtime for generated JVM launchers.

is_java_21() {
  local java_home="$1"
  local specification_version
  [[ -x "$java_home/bin/java" ]] || return 1
  specification_version="$($java_home/bin/java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version/ {print $3; exit}')"
  [[ "$specification_version" == "21" ]]
}

java_home_21=""
if [[ -n "${JAVA_HOME:-}" ]] && is_java_21 "$JAVA_HOME"; then
  java_home_21="$JAVA_HOME"
else
  if [[ -x /usr/libexec/java_home ]]; then
    java_home_21="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    if [[ -n "$java_home_21" ]] && ! is_java_21 "$java_home_21"; then
      java_home_21=""
    fi
  fi

  for candidate in "$HOME/.local/opt/jdk-21"; do
    if [[ -z "$java_home_21" ]] && is_java_21 "$candidate"; then
      java_home_21="$candidate"
    fi
  done

  if [[ -d "$HOME/.gradle/jdks" ]]; then
    while IFS= read -r candidate; do
      candidate="${candidate%/bin/java}"
      if [[ -z "$java_home_21" ]] && is_java_21 "$candidate"; then
        java_home_21="$candidate"
      fi
    done < <(find "$HOME/.gradle/jdks" -type f -path '*/bin/java' 2>/dev/null)
  fi
fi

if [[ -z "$java_home_21" || ! -x "$java_home_21/bin/java" ]]; then
  echo "JDK 21 not found; set JAVA_HOME to a JDK 21 installation" >&2
  return 1 2>/dev/null || exit 1
fi

export JAVA_HOME="$java_home_21"
export PATH="$JAVA_HOME/bin:$PATH"
unset java_home_21 candidate
unset -f is_java_21
