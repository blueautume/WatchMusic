#!/bin/bash
set -euo pipefail

website_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$website_dir/.." && pwd)"
source_dir="$project_dir/PhoneApp/Legal"
output_dir="$project_dir/Artifacts/Deployment"
version="2026-10-29"
archive="watchmusic-web-$version.zip"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchmusic-web.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

for page in privacy terms support; do
    test -f "$source_dir/$page.html"
    cp "$source_dir/$page.html" "$stage_dir/$page.html"
done
cp "$stage_dir/support.html" "$stage_dir/index.html"
mkdir -p "$output_dir"
(
    cd "$stage_dir"
    /usr/bin/zip -X -q "$archive" index.html privacy.html terms.html support.html
)
mv "$stage_dir/$archive" "$output_dir/$archive"
printf '%s\n' "$output_dir/$archive"
