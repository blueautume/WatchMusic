#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/privacy-consent-tests.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc "$test_root/Shared/Localization.swift" "$test_root/PhoneApp/PrivacyConsentState.swift" \
  "$test_root/Tests/PrivacyConsentTests.swift" -o "$test_output_dir/PrivacyConsentTests"
"$test_output_dir/PrivacyConsentTests"
