#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-orientation-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/WatchTransferOrientation.swift" \
  "$test_root/Tests/WatchTransferOrientationTests.swift" -o "$test_output_dir/WatchTransferOrientationTests"
"$test_output_dir/WatchTransferOrientationTests"
