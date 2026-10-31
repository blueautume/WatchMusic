#!/bin/zsh
# Host-only; no simulator, app, audio session, or user media is used.
set -eu
test_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/audio-session-executor.XXXXXX")"
trap 'rm -rf "$test_output_dir"' EXIT
xcrun swiftc -parse-as-library "$test_root/Shared/AudioSessionExecutor.swift" \
  "$test_root/Tests/AudioSessionExecutorProbe.swift" -o "$test_output_dir/AudioSessionExecutorProbe"
python3 - "$test_output_dir/AudioSessionExecutorProbe" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("AUDIO_SESSION_EXECUTOR_FAIL: executor stalled or blocked the main actor", file=sys.stderr)
    sys.exit(1)
sys.exit(result.returncode)
PY
