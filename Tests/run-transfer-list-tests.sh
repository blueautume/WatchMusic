#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-transfer-list-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/TransferRecordState.swift" "$test_root/Shared/TransferMetrics.swift" \
  "$test_root/Shared/TransferListOrdering.swift" "$test_root/Tests/TransferListOrderingTests.swift" \
  -o "$test_output_dir/TransferListOrderingTests"
"$test_output_dir/TransferListOrderingTests"
