#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-reception-status.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$test_root/Shared/Localization.swift" "$test_root/Shared/AudioFileFormat.swift" \
  "$test_root/Shared/LANTransferProtocol.swift" "$test_root/Shared/LANBackgroundTransferState.swift" \
  "$test_root/Shared/LANReceptionStatus.swift" "$test_root/Tests/LANReceptionStatusTests.swift" \
  -o "$test_output_dir/LANReceptionStatusTests"
"$test_output_dir/LANReceptionStatusTests"
