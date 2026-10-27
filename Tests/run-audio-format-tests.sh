#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-audio-format-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/AudioFileFormat.swift" "$test_root/Tests/AudioFileFormatTests.swift" -o "$test_output_dir/AudioFileFormatTests"
"$test_output_dir/AudioFileFormatTests"
