#!/bin/zsh
# Uses an already booted Watch simulator; does not activate audio or drive UI.
set -eu
if (( $# != 1 )); then
  print -u2 'Usage: run-watch-volume-feedback-probe.sh BOOTED_WATCH_SIMULATOR_UDID'
  exit 2
fi
test_device="$1"
xcrun simctl list devices booted --json | python3 -c '
import json, sys
device = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
if not any("watchOS" in runtime and item["udid"] == device and item["state"] == "Booted"
           for runtime, items in devices.items() for item in items):
    sys.exit("Requires an already booted Watch simulator UUID.")
' "$test_device"
test_sdk="$(xcrun --sdk watchsimulator --show-sdk-path)"
test_target="$(uname -m)-apple-watchos10.0-simulator"
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-volume-feedback.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" -parse-as-library -sdk "$test_sdk" -target "$test_target" \
  "$test_root/WatchApp/WatchVolumeFeedback.swift" \
  "$test_root/Tests/WatchVolumeFeedbackProbe.swift" -o "$test_output_dir/WatchVolumeFeedbackProbe"
xcrun simctl spawn "$test_device" "$test_output_dir/WatchVolumeFeedbackProbe"
