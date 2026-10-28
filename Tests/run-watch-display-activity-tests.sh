#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-display-activity.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/WatchDisplayActivityState.swift" "$test_root/Tests/WatchDisplayActivityTests.swift" -o "$test_output_dir/WatchDisplayActivityTests"
"$test_output_dir/WatchDisplayActivityTests"
