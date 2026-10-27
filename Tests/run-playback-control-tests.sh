#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-playback-control.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/PlaybackControlProtocol.swift" "$test_root/Tests/PlaybackControlProtocolTests.swift" -o "$test_output_dir/PlaybackControlProtocolTests"
"$test_output_dir/PlaybackControlProtocolTests"
