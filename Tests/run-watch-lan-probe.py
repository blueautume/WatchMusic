#!/usr/bin/env python3
"""Exercise the real watch downloader against a local HTTP server (Debug only)."""
import argparse
import hashlib
import hmac
import json
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BUNDLE = "com.lihao.OfflineWatchPlayerLab.watchkitapp"
ROOT = Path(__file__).resolve().parents[1]


def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=45).strip()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.server.token):
            self.send_error(401)
            return
        route = self.server.routes.get(self.path)
        if not route:
            self.send_error(404)
            return
        body, behavior = route
        if behavior == "http_error":
            self.send_error(503)
            return
        if behavior == "corrupt":
            body = body[:-1] + bytes([body[-1] ^ 0xFF])
        if behavior == "oversize":
            body += b"unexpected extra bytes"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.server.request_started.set()
        if behavior == "slow":
            time.sleep(2)
        try:
            for index in range(0, len(body), 32_768):
                self.wfile.write(body[index:index + 32_768])
                self.wfile.flush()
                time.sleep(0.04)
        except (BrokenPipeError, ConnectionResetError):
            pass


def run_case(device, documents, title, specifications, expected_kind, capture=None, cancel=False):
    folder = "LANProbe-" + str(uuid.uuid4())
    manifest = []
    routes = {}
    token = uuid.uuid4().hex + uuid.uuid4().hex
    for index, (fixture, behavior) in enumerate(specifications):
        body = fixture.read_bytes()
        identifier = str(uuid.uuid4())
        manifest.append({"id": identifier, "folder": folder, "fileName": f"probe-{index}.{fixture.suffix[1:]}",
                         "byteCount": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        routes["/v1/files/" + identifier] = (body, behavior)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.routes, server.token = routes, token
    server.request_started = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    offer_path = documents / "lan-probe-offer.json"
    log_path = documents / "lan-test-events.json"
    destination = documents / "Music" / folder
    try:
        subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, check=False, timeout=15)
        log_path.unlink(missing_ok=True)
        offer = {"protocolVersion": 1, "sessionID": str(uuid.uuid4()), "token": token,
                 "baseURLs": [f"http://127.0.0.1:{server.server_port}"],
                 "expiresAt": time.time() - 978_307_200 + 120, "files": manifest}
        offer_path.write_text(json.dumps(offer))
        args = ["launch", device, BUNDLE, "-lan-offer-file", offer_path.name]
        if cancel:
            args += ["-lan-cancel-after", "0.3"]
        simctl(*args)
        if capture:
            assert server.request_started.wait(timeout=15), "download did not reach the HTTP server"
            # Capture the active reception card, after launch-screen dismissal.
            time.sleep(0.8)
            capture.parent.mkdir(parents=True, exist_ok=True)
            simctl("io", device, "screenshot", str(capture))
        deadline = time.monotonic() + 40
        terminal = {}
        while time.monotonic() < deadline:
            if log_path.exists():
                try:
                    events = json.loads(log_path.read_text())
                    terminal = {event["fileID"]: event for event in events if event["kind"] != "progress"}
                except (json.JSONDecodeError, OSError):
                    pass
            if len(terminal) == len(manifest):
                break
            time.sleep(0.1)
        assert len(terminal) == len(manifest), f"{title}: terminal receipts missing; observed {terminal}"
        for file in manifest:
            event = terminal[file["id"]]
            assert event["kind"] == expected_kind, f"{title}: expected {expected_kind}, got {event}"
            target = destination / file["fileName"]
            if expected_kind == "stored":
                assert target.is_file(), f"{title}: receipt without saved file"
                assert target.stat().st_size == file["byteCount"], f"{title}: wrong saved size"
                assert hashlib.sha256(target.read_bytes()).hexdigest() == file["sha256"], f"{title}: wrong saved content"
            else:
                assert not target.exists(), f"{title}: rejected/cancelled data must not enter the library"
        print(f"PASS: {title} ({len(manifest)} file(s))", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        offer_path.unlink(missing_ok=True)
        if destination.exists():
            shutil.rmtree(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Booted watch simulator UDID")
    parser.add_argument("--app", type=Path, help="Install this Debug Watch .app before running")
    parser.add_argument("--capture", type=Path, help="Save a screenshot during the first download")
    parser.add_argument("--success-only", action="store_true", help="Run only the successful-download scenario")
    args = parser.parse_args()
    if args.app:
        simctl("install", args.device, str(args.app.resolve()))
    container = Path(simctl("get_app_container", args.device, BUNDLE, "data"))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    mp3, flac = (ROOT / "Tests/Fixtures" / name for name in ["EmbeddedResources.mp3", "EmbeddedResources.flac"])
    try:
        run_case(args.device, documents, "MP3 and FLAC download, integrity and save receipts",
                 [(mp3, "slow"), (flac, "normal")], "stored", args.capture)
        if args.success_only:
            return
        run_case(args.device, documents, "same-size corrupt content rejected", [(flac, "corrupt")], "failed")
        run_case(args.device, documents, "HTTP failure rejected", [(mp3, "http_error")], "failed")
        run_case(args.device, documents, "oversized response rejected", [(mp3, "oversize")], "failed")
        run_case(args.device, documents, "cancel prevents later save", [(flac, "slow")], "cancelled", cancel=True)
        print("PASS: real watch URLSession LAN transfer probe", flush=True)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True, check=False, timeout=15)


if __name__ == "__main__":
    main()
