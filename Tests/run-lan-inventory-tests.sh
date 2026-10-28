#!/bin/zsh
set -eu
if (( $# > 1 )); then
  print -u2 'Usage: run-lan-inventory-tests.sh [BOOTED_IPHONE_SIMULATOR_UDID]'
  exit 2
fi
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-inventory.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
test_sources=(
  "$test_root/Shared/AudioFileFormat.swift"
  "$test_root/Shared/LANTransferProtocol.swift"
  "$test_root/Shared/TransferSourceVersion.swift"
  "$test_root/Shared/LANInventoryProtocol.swift"
  "$test_root/WatchApp/LANInventory.swift"
  "$test_root/Tests/LANInventoryTests.swift"
)
if (( $# == 1 )); then
  test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 -sdk "$test_sdk" \
    -target "$(uname -m)-apple-ios17.0-simulator" \
    "${test_sources[@]}" -o "$test_output_dir/LANInventoryTests"
  xcrun simctl spawn "$1" "$test_output_dir/LANInventoryTests"
else
  xcrun swiftc -parse-as-library -swift-version 5 \
    "${test_sources[@]}" -o "$test_output_dir/LANInventoryTests"
  "$test_output_dir/LANInventoryTests"
fi
