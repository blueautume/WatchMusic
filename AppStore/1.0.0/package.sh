#!/bin/bash
set -euo pipefail
store_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$store_dir/../.." && pwd)"
python3 "$store_dir/tools/validate-package.py"
python3 "$store_dir/tools/package-iphone.py"
archive="$project_dir/Artifacts/Deployment/watchmusic-appstore-1.0.0.zip"
mkdir -p "$(dirname "$archive")"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchmusic-appstore.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
(
    cd "$store_dir"
    /usr/bin/zip -X -q -r "$stage_dir/store.zip" index.html README.md metadata*.md metadata.json keyword-bank.md submission-guide.md capture-notes.md manifest.json creative screenshots tools qa package.sh -x '*/__pycache__/*' '*.pyc' '*.DS_Store'
)
mv "$stage_dir/store.zip" "$archive"
printf '%s\n' "$archive"
