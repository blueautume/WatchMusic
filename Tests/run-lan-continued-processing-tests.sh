#!/bin/zsh
set -eu
if (( $# > 1 )); then
  print -u2 'Usage: run-lan-continued-processing-tests.sh [BOOTED_IPHONE_SIMULATOR_UDID]'
  exit 2
fi
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/lan-continued-processing.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
if (( $# == 0 )); then
  xcrun swiftc -parse-as-library -swift-version 5 \
    "$test_root/Shared/LANContinuedProcessingState.swift" "$test_root/Tests/LANContinuedProcessingTests.swift" \
    -o "$test_output_dir/LANContinuedProcessingTests"
  "$test_output_dir/LANContinuedProcessingTests"
else
  test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  xcrun --sdk iphonesimulator swiftc -parse-as-library -D DEBUG -swift-version 5 -sdk "$test_sdk" \
    -target "$(uname -m)-apple-ios17.0-simulator" \
    "$test_root/Shared/LANContinuedProcessingState.swift" "$test_root/PhoneApp/LANContinuedProcessing.swift" \
    "$test_root/Tests/LANContinuedProcessingTests.swift" -o "$test_output_dir/LANContinuedProcessingTests"
  xcrun simctl spawn "$1" "$test_output_dir/LANContinuedProcessingTests"
fi
