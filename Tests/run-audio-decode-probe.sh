#!/bin/zsh
# Usage: Tests/run-audio-decode-probe.sh ios|watchos BOOTED_SIMULATOR_UDID AUDIO_PATH...
# Uses an already booted simulator; it does not alter its UI or play sound.
set -eu
if (( $# < 3 )); then
  print -u2 'Usage: run-audio-decode-probe.sh ios|watchos BOOTED_SIMULATOR_UDID AUDIO_PATH...'
  exit 2
fi
test_platform="$1"
test_device="$2"
shift 2
test_arch="$(uname -m)"
case "$test_platform" in
  ios)
    test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    test_target="$test_arch-apple-ios17.0-simulator"
    ;;
  watchos)
    test_sdk="$(xcrun --sdk watchsimulator --show-sdk-path)"
    test_target="$test_arch-apple-watchos10.0-simulator"
    ;;
  *)
    print -u2 'Platform must be ios or watchos.'
    exit 2
    ;;
esac
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-audio-decode-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc -parse-as-library -sdk "$test_sdk" -target "$test_target" "$test_root/Tests/AudioDecodeProbe.swift" -o "$test_output_dir/AudioDecodeProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/AudioDecodeProbe" "$@"
