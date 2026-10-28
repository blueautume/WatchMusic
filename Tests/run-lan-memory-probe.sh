#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_source_root="$test_root"
test_device=""
test_expect_limit=""
while (( $# > 0 )); do
  case "$1" in
    --source-root)
      test_source_root="$2"
      shift 2
      ;;
    --expect-memory-limit)
      test_expect_limit="$1"
      shift
      ;;
    *)
      if [[ -n "$test_device" ]]; then
        print -u2 'Usage: run-lan-memory-probe.sh [BOOTED_IPHONE_SIMULATOR_UDID] [--source-root SOURCE_SNAPSHOT] [--expect-memory-limit]'
        exit 2
      fi
      test_device="$1"
      shift
      ;;
  esac
done
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-memory-probe.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
test_sources=(
  "$test_source_root/Shared/AudioFileFormat.swift"
  "$test_source_root/Shared/LANTransferProtocol.swift"
  "$test_source_root/Shared/LANHTTPParsing.swift"
  "$test_source_root/PhoneApp/LANHTTPServer.swift"
  "$test_root/Tests/LANMemoryProbe.swift"
)
# Independent streaming reference: the child never allocates a full fixture.
test_expected_sha="$(python3 - <<'PY'
import hashlib
digest = hashlib.sha256()
chunk = bytes(1024 * 1024)
for _ in range(512):
    digest.update(chunk)
print(digest.hexdigest())
PY
)"
if [[ -n "$test_device" ]]; then
  test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  xcrun --sdk iphonesimulator swiftc -O -parse-as-library -swift-version 5 -sdk "$test_sdk" \
    -target "$(uname -m)-apple-ios17.0-simulator" \
    "${test_sources[@]}" -o "$test_output_dir/LANMemoryProbe"
  xcrun simctl spawn "$test_device" "$test_output_dir/LANMemoryProbe" "$test_expected_sha" ${test_expect_limit:+"$test_expect_limit"}
else
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    "${test_sources[@]}" -o "$test_output_dir/LANMemoryProbe"
  "$test_output_dir/LANMemoryProbe" "$test_expected_sha" ${test_expect_limit:+"$test_expect_limit"}
fi
