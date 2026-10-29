#!/bin/bash
set -euo pipefail

website_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$website_dir/.." && pwd)"
source_dir="$website_dir/marketing"
legal_dir="$project_dir/PhoneApp/Legal"
output_dir="$project_dir/Artifacts/Deployment"
archive="watchmusic-marketing-1.0.0.zip"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchmusic-marketing.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

test -s "$source_dir/index.html"
for asset in app-icon.png phone-player.png watch-player.png; do
    test -s "$source_dir/assets/$asset"
done
python3 - "$source_dir" "$stage_dir/index.html" <<'PY'
import base64
import pathlib
import sys

source_dir = pathlib.Path(sys.argv[1])
html = (source_dir / "index.html").read_text(encoding="utf-8")
for name in ("app-icon.png", "phone-player.png", "watch-player.png"):
    path = f"assets/{name}"
    image = base64.b64encode((source_dir / path).read_bytes()).decode("ascii")
    html = html.replace(f'"{path}"', f'"data:image/png;base64,{image}"')
if "assets/" in html:
    raise SystemExit("Unembedded asset reference in marketing HTML")
pathlib.Path(sys.argv[2]).write_text(html, encoding="utf-8")
PY
for page in privacy terms support; do
    test -s "$legal_dir/$page.html"
    cp "$legal_dir/$page.html" "$stage_dir/$page.html"
done
mkdir -p "$output_dir"
(
    cd "$stage_dir"
    /usr/bin/zip -X -q "$archive" index.html privacy.html terms.html support.html
)
mv "$stage_dir/$archive" "$output_dir/$archive"
printf '%s\n' "$output_dir/$archive"
