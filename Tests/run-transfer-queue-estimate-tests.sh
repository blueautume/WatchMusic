#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/transfer-queue-estimate.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/TransferRecordState.swift" "$test_root/Shared/TransferMetrics.swift" \
  "$test_root/Shared/TransferQueueEstimate.swift" "$test_root/Tests/TransferQueueEstimateTests.swift" \
  -o "$test_output_dir/TransferQueueEstimateTests"
"$test_output_dir/TransferQueueEstimateTests"
xcrun swiftc -parse-as-library "$test_root/Shared/TransferMetrics.swift" \
  "$test_root/PhoneApp/PhoneTransferProgress.swift" "$test_root/Tests/TransferProgressObservationTests.swift" \
  -o "$test_output_dir/TransferProgressObservationTests"
"$test_output_dir/TransferProgressObservationTests"
