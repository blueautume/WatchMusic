#!/bin/zsh
set -eu
if (( $# != 3 )); then
  print -u2 'Usage: run-playback-control-integration-probe.sh ios|watchos BOOTED_SIMULATOR_UDID AUDIO'
  exit 2
fi
test_platform="$1"
test_device="$2"
test_audio="$3"
test_arch="$(uname -m)"
case "$test_platform" in
  ios) test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"; test_target="$test_arch-apple-ios17.0-simulator" ;;
  watchos) test_sdk="$(xcrun --sdk watchsimulator --show-sdk-path)"; test_target="$test_arch-apple-watchos10.0-simulator" ;;
  *) exit 2 ;;
esac
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/playback-control-integration.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc -DDEBUG -parse-as-library -sdk "$test_sdk" -target "$test_target" \
  "$test_root/Shared/AudioFileFormat.swift" "$test_root/Shared/PlaybackQueueLogic.swift" \
  "$test_root/Shared/ArtworkDecoder.swift" "$test_root/Shared/AudioMetadataReader.swift" "$test_root/Shared/MusicPlayer.swift" \
  "$test_root/Shared/PlaybackControlProtocol.swift" "$test_root/Shared/PlaybackControlCenter.swift" \
  "$test_root/Tests/PlaybackControlIntegrationProbe.swift" -o "$test_output_dir/PlaybackControlIntegrationProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/PlaybackControlIntegrationProbe" "$test_audio"
