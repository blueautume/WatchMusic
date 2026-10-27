#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-player-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/PlaybackQueueLogic.swift" "$test_root/Tests/PlaybackQueueTests.swift" -o "$test_output_dir/PlaybackQueueTests"
"$test_output_dir/PlaybackQueueTests"
