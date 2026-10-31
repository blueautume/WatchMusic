#!/bin/zsh
# Uses an already booted simulator. Does not launch/drive UI or play audio.
set -eu
if (( $# < 3 )); then
  print -u2 'Usage: run-player-integration-probe.sh ios|watchos BOOTED_SIMULATOR_UDID AUDIO [EMBEDDED_MP3 EMBEDDED_FLAC]'
  exit 2
fi
test_platform="$1"
test_device="$2"
shift 2
test_arch="$(uname -m)"
case "$test_platform" in
  ios) test_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"; test_target="$test_arch-apple-ios17.0-simulator" ;;
  watchos) test_sdk="$(xcrun --sdk watchsimulator --show-sdk-path)"; test_target="$test_arch-apple-watchos10.0-simulator" ;;
  *) print -u2 'Platform must be ios or watchos.'; exit 2 ;;
esac
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-player-integration.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" -parse-as-library -sdk "$test_sdk" -target "$test_target" \
  "$test_root/Shared/AudioFileFormat.swift" "$test_root/Shared/PlaybackQueueLogic.swift" \
  "$test_root/Shared/ArtworkDecoder.swift" "$test_root/Shared/AudioMetadataReader.swift" "$test_root/Shared/MusicPlayer.swift" \
  "$test_root/Tests/MusicPlayerIntegrationProbe.swift" -o "$test_output_dir/MusicPlayerIntegrationProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/MusicPlayerIntegrationProbe" "$@"
