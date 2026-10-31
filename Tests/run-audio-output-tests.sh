#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchmusic-audio-output.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/AudioOutputPresentation.swift" \
  "$test_root/Tests/AudioOutputPresentationTests.swift" -o "$test_output_dir/AudioOutputPresentationTests"
"$test_output_dir/AudioOutputPresentationTests"
