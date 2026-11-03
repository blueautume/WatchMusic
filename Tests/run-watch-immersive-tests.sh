#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-immersive-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/WatchTransferOrientation.swift" \
  "$test_root/WatchApp/WatchSurfaceMetrics.swift" \
  "$test_root/WatchApp/WatchImmersivePlayback.swift" \
  "$test_root/Tests/WatchImmersivePlaybackTests.swift" -o "$test_output_dir/WatchImmersivePlaybackTests"
"$test_output_dir/WatchImmersivePlaybackTests"
