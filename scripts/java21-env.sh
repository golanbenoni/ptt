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
if [[ -d /opt/homebrew/bin && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

# Homebrew's command-line tools cask installs a complete SDK here, but the
# Android Gradle discovery code does not know about that location.
if [[ -z "${ANDROID_HOME:-}" && -d /opt/homebrew/share/android-commandlinetools/platform-tools ]]; then
  export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
fi
if [[ -n "${ANDROID_HOME:-}" ]]; then
  export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
fi

# Some build hosts relocate ~/.gradle/wrapper onto a removable build volume.
# Keep clean-checkout builds working when that volume is not mounted.
if [[ -z "${GRADLE_USER_HOME:-}" && -L "$HOME/.gradle/wrapper" && ! -e "$HOME/.gradle/wrapper" ]]; then
  export GRADLE_USER_HOME="$HOME/.cache/ptt-gradle"
fi
unset java_home_21 candidate
unset -f is_java_21
