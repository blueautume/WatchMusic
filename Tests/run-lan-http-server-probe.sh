#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-lan-http-probe.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" -parse-as-library \
  "$test_root/Shared/AudioFileFormat.swift" "$test_root/Shared/LANTransferProtocol.swift" \
  "$test_root/Shared/LANHTTPParsing.swift" "$test_root/PhoneApp/LANHTTPServer.swift" \
  "$test_root/Tests/LANHTTPServerProbe.swift" -o "$test_output_dir/LANHTTPServerProbe"
"$test_output_dir/LANHTTPServerProbe" "$test_root/Tests/Fixtures/EmbeddedResources.flac"
