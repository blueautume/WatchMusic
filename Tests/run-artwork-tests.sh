#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-artwork-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/ArtworkDecoder.swift" "$test_root/Tests/ArtworkTests.swift" -o "$test_output_dir/ArtworkTests"
"$test_output_dir/ArtworkTests"
