#!/bin/zsh
# Uses real PhoneLibrary APIs in an already booted iPhone simulator; no audio.
set -eu
if (( $# < 1 || $# > 2 )); then
  print -u2 'Usage: run-phone-bulk-probe.sh BOOTED_IPHONE_SIMULATOR_UDID [FIXTURE_MP3]'
  exit 2
fi
test_device="$1"
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_fixture="${2:-$test_root/Tests/Fixtures/EmbeddedResources.mp3}"
test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
test_target="$(uname -m)-apple-ios17.0-simulator"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-bulk-integration.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
# Compile a snapshot so unrelated editing cannot change an input mid-build.
test_sources="$test_output_dir/Sources"
mkdir -p "$test_sources/Shared" "$test_sources/PhoneApp" "$test_sources/Tests"
cp "$test_root"/Shared/*.swift "$test_sources/Shared/"
for test_file in PhoneLibrary.swift PhoneLibrary+Bulk.swift PhoneResourceImport.swift LANHTTPServer.swift LANSendPreparation.swift LANPhoneQueuePersistence.swift; do
  cp "$test_root/PhoneApp/$test_file" "$test_sources/PhoneApp/$test_file"
done
cp "$test_root/Tests/PhoneBulkIntegrationProbe.swift" "$test_sources/Tests/"
xcrun swiftc -parse-as-library -D DEBUG -swift-version 5 -sdk "$test_sdk" -target "$test_target" \
  "$test_sources"/Shared/*.swift \
  "$test_sources/PhoneApp/PhoneLibrary.swift" "$test_sources/PhoneApp/PhoneLibrary+Bulk.swift" \
  "$test_sources/PhoneApp/PhoneResourceImport.swift" "$test_sources/PhoneApp/LANHTTPServer.swift" \
  "$test_sources/PhoneApp/LANSendPreparation.swift" \
  "$test_sources/PhoneApp/LANPhoneQueuePersistence.swift" \
  "$test_sources/Tests/PhoneBulkIntegrationProbe.swift" -o "$test_output_dir/PhoneBulkIntegrationProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/PhoneBulkIntegrationProbe" "$test_fixture" "$test_device"
