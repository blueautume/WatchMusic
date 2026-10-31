#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-surface-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" "$test_root/Shared/WatchTransferOrientation.swift" \
  "$test_root/WatchApp/WatchSurfaceMetrics.swift" \
  "$test_root/Tests/WatchSurfaceMetricsTests.swift" -o "$test_output_dir/WatchSurfaceMetricsTests"
"$test_output_dir/WatchSurfaceMetricsTests"
