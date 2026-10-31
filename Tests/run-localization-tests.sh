#!/bin/zsh
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$test_root/Tests/check-localization.py" "$@"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchmusic-localization.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
test_bundle="$test_output_dir/LocalizationProbe.bundle"
mkdir -p "$test_bundle/Contents/MacOS" "$test_bundle/Contents/Resources"
for test_language in en zh-Hans; do
  cp -R "$test_root/Shared/$test_language.lproj" "$test_bundle/Contents/Resources/"
done
python3 - "$test_bundle/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleExecutable': 'LocalizationProbe',
        'CFBundleIdentifier': 'local.watchmusic.localization-probe',
        'CFBundlePackageType': 'BNDL',
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleLocalizations': ['en', 'zh-Hans'],
    }, output)
PY
xcrun swiftc -parse-as-library "$test_root/Shared/Localization.swift" \
  "$test_root/Tests/LocalizationProbe.swift" -o "$test_bundle/Contents/MacOS/LocalizationProbe"
"$test_bundle/Contents/MacOS/LocalizationProbe" en -AppleLanguages '(en)' -AppleLocale en_US
"$test_bundle/Contents/MacOS/LocalizationProbe" zh-Hans -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
"$test_bundle/Contents/MacOS/LocalizationProbe" en -AppleLanguages '(de-DE, en)' -AppleLocale de_DE
"$test_bundle/Contents/MacOS/LocalizationProbe" en -AppleLanguages '(fr-FR)' -AppleLocale fr_FR
