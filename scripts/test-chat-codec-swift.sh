#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_DIR="$(mktemp -d -t ptt-chat-codec.XXXXXX)"
cleanup() { rm -rf "$PROBE_DIR"; }
trap cleanup EXIT

swiftc \
  "$ROOT/ios/PttTalk/Sources/PttTalkLib/EncryptedChat.swift" \
  "$ROOT/ios/PttTalk/Sources/PttTalkLib/SecureChatArchive.swift" \
  "$ROOT/ios/PttTalk/ChatCodecProbe/main.swift" \
  -o "$PROBE_DIR/chat-codec-probe"
"$PROBE_DIR/chat-codec-probe"
