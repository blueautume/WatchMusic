#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-source-version-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/TransferSourceVersion.swift" \
  "$test_root/Tests/TransferSourceVersionTests.swift" -o "$test_output_dir/TransferSourceVersionTests"
"$test_output_dir/TransferSourceVersionTests"
