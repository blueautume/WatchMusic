#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-playback-layout.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/PhoneApp/PhonePlaybackLayout.swift" \
  "$test_root/Tests/PhonePlaybackLayoutTests.swift" -o "$test_output_dir/PhonePlaybackLayoutTests"
"$test_output_dir/PhonePlaybackLayoutTests"
