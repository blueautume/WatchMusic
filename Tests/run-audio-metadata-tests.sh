#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-metadata-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/AudioMetadataReader.swift" "$test_root/Tests/AudioMetadataReaderTests.swift" -o "$test_output_dir/AudioMetadataReaderTests"
if (( $# == 0 )); then
  "$test_output_dir/AudioMetadataReaderTests" "$test_root/Tests/Fixtures/EmbeddedResources.mp3" "$test_root/Tests/Fixtures/EmbeddedResources.flac"
else
  "$test_output_dir/AudioMetadataReaderTests" "$@"
fi
