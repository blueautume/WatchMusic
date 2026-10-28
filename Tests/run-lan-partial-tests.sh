#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-partial.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/AudioFileFormat.swift" "$test_root/Shared/LANTransferProtocol.swift" "$test_root/Shared/LANPartialDownloadStore.swift" "$test_root/Tests/LANPartialDownloadStoreTests.swift" -o "$test_output_dir/LANPartialDownloadStoreTests"
"$test_output_dir/LANPartialDownloadStoreTests"
