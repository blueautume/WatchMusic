#!/bin/zsh
set -eu
if (( $# != 1 )); then
  print -u2 'Usage: run-phone-transfer-control-probe.sh BOOTED_IPHONE_SIMULATOR_UDID'
  exit 2
fi
test_device="$1"
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-transfer-control.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
mkdir -p "$test_output_dir/Sources/Shared" "$test_output_dir/Sources/PhoneApp"
cp "$test_root"/Shared/*.swift "$test_output_dir/Sources/Shared/"
for test_file in PhoneLibrary.swift PhoneLibrary+Bulk.swift PhoneResourceImport.swift LANHTTPServer.swift LANSendPreparation.swift LANContinuedProcessing.swift LANPhoneQueuePersistence.swift; do
  cp "$test_root/PhoneApp/$test_file" "$test_output_dir/Sources/PhoneApp/$test_file"
done
cp "$test_root/Tests/PhoneTransferControlProbe.swift" "$test_output_dir/Sources/"
xcrun --sdk iphonesimulator swiftc -parse-as-library -D DEBUG -swift-version 5 -sdk "$test_sdk" -target "$(uname -m)-apple-ios17.0-simulator" \
  "$test_output_dir"/Sources/Shared/*.swift "$test_output_dir"/Sources/PhoneApp/*.swift \
  "$test_output_dir/Sources/PhoneTransferControlProbe.swift" -o "$test_output_dir/PhoneTransferControlProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/PhoneTransferControlProbe" -preview-transfers-in-progress
