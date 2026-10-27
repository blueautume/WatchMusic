#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-transfer-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/TransferMetrics.swift" "$test_root/Tests/TransferMetricsTests.swift" -o "$test_output_dir/TransferMetricsTests"
"$test_output_dir/TransferMetricsTests"
