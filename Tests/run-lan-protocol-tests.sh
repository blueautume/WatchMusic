#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-protocol.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" "$test_root/Shared/AudioFileFormat.swift" "$test_root/Shared/LANTransferProtocol.swift" "$test_root/Tests/LANTransferProtocolTests.swift" -o "$test_output_dir/LANTransferProtocolTests"
"$test_output_dir/LANTransferProtocolTests"
