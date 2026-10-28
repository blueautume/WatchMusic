#!/usr/bin/env python3
"""Exercise the real watch downloader against a local HTTP server (Debug only)."""
import argparse
import hashlib
import hmac
import json
import os
import signal
import shutil
import socket
import subprocess
import threading
import time
import tempfile
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BUNDLE = "com.lihao.OfflineWatchPlayerLab.watchkitapp"
ROOT = Path(__file__).resolve().parents[1]


def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=45).strip()


def terminal_receipts(path):
    try:
        value = json.loads(path.read_text())
        events = value.values() if isinstance(value, dict) else value
        return {item["fileID"]: item for item in events if item["kind"] in ("stored", "failed", "cancelled")}
    except (OSError, json.JSONDecodeError):
        return {}


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
        # Capture the durable receiver outcome at request arrival, rather than
        # relying on the asynchronous main-queue debug log reaching disk first.
        terminal = terminal_receipts(self.server.outbox_path)
        terminal.update(terminal_receipts(self.server.log_path))
        identifier = self.path.rsplit("/", 1)[-1]
        with self.server.request_lock:
            self.server.active_requests[self] = identifier
            self.server.peak_requests = max(self.server.peak_requests, len(self.server.active_requests))
            live = [file_id for file_id in self.server.active_requests.values() if file_id not in terminal]
            self.server.peak_live_requests = max(self.server.peak_live_requests, len(live))
            self.server.requests.append({"fileID": identifier, "terminal": terminal,
                                         "saved": {file["id"]: (self.server.destination / file["fileName"]).is_file()
                                                   for file in self.server.manifest}})
        try:
            self.serve_route(route)
        finally:
            with self.server.request_lock:
                self.server.active_requests.pop(self, None)

    def serve_route(self, route):
        body, behavior = route
        if behavior == "redirect":
            self.send_response(302)
            self.send_header("Location", self.path + "/redirected")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        if behavior == "http_error":
            self.send_error(503)
            return
        if behavior == "corrupt":
            body = body[:-1] + bytes([body[-1] ^ 0xFF])
        if behavior == "oversize":
            body += b"unexpected extra bytes"
        full_size = len(body)
        resume_offset = None
        range_end = full_size - 1
        disconnect_this_request = False
        requested_range = self.headers.get("Range")
        if requested_range is not None and not behavior.startswith("range_") and behavior != "oversize":
            assert requested_range.startswith("bytes="), "unexpected Range header"
            bounds = requested_range[6:].split("-", 1)
            resume_offset = int(bounds[0])
            range_end = int(bounds[1]) if bounds[1] else full_size - 1
            if self.server.first_range is None:
                self.server.first_range = resume_offset
            assert 0 <= resume_offset <= range_end < full_size, "invalid bounded range"
            if behavior == "fail_after_first" and resume_offset >= 4 * 1024 * 1024:
                self.send_error(503)
                return
            body = body[resume_offset:range_end + 1]
            if resume_offset > 0:
                self.server.range_requests.append(requested_range)
        if behavior == "disconnect_resume" and resume_offset in (None, 0) and self.path not in self.server.disconnected_paths:
            self.server.disconnected_paths.add(self.path)
            disconnect_this_request = True
        if behavior == "range_tail":
            body = body[full_size // 2:]
        self.send_response(206 if behavior.startswith("range_") or resume_offset is not None else 200)
        if requested_range is not None and not behavior.startswith("range_") and behavior != "oversize":
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '"' + hashlib.sha256(route[0]).hexdigest() + '"')
            self.send_header("Content-Range", f"bytes {resume_offset}-{range_end}/{full_size}")
        if behavior == "range_full":
            self.send_header("Content-Range", f"bytes 0-{full_size - 1}/{full_size}")
        elif behavior == "range_malformed":
            self.send_header("Content-Range", f"bytes 0-{full_size - 1}/{full_size + 1}")
        elif behavior == "range_tail":
            self.send_header("Content-Range", f"bytes {full_size // 2}-{full_size - 1}/{full_size}")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.server.request_started.set()
        if behavior == "slow":
            time.sleep(2)
        chunk = 8_192 if behavior in ("trickle", "disconnect_resume") else 32_768
        interval = 0.2 if behavior in ("trickle", "disconnect_resume") else 0.04
        try:
            for index in range(0, len(body), chunk):
                last_chunk = index + chunk >= len(body)
                if last_chunk:
                    # The last response bytes and accounting are one ordering:
                    # handler teardown / close are not ongoing file transfer.
                    with self.server.request_lock:
                        self.wfile.write(body[index:index + chunk])
                        self.wfile.flush()
                        self.server.active_requests.pop(self, None)
                else:
                    self.wfile.write(body[index:index + chunk])
                    self.wfile.flush()
                    time.sleep(interval)
                if disconnect_this_request and index >= chunk * 14:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
        except (BrokenPipeError, ConnectionResetError):
            pass


def run_case(device, documents, title, specifications, expected_kind, capture=None, cancel=False, background=False, restart=False, pause=False,
             pause_after=0.3, resume_after=3.5, partial=False, require_range=False, serial=False, cancel_first=False,
             folder_override=None, expected_first_offset=None):
    folder = folder_override or "LANProbe-" + str(uuid.uuid4())
    manifest = []
    routes = {}
    token = uuid.uuid4().hex + uuid.uuid4().hex
    for index, (fixture, behavior) in enumerate(specifications):
        body = fixture.read_bytes()
        identifier = str(uuid.uuid4())
        manifest.append({"id": identifier, "folder": folder, "fileName": f"probe-{index}.{fixture.suffix[1:]}",
                         "byteCount": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        routes["/v1/files/" + identifier] = (body, behavior)
        if behavior == "redirect":
            routes["/v1/files/" + identifier + "/redirected"] = (body, "normal")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.routes, server.token = routes, token
    server.range_requests, server.disconnected_paths = [], set()
    server.first_range = None
    server.request_started = threading.Event()
    server.request_lock = threading.Lock()
    server.active_requests, server.requests = {}, []
    server.peak_requests = server.peak_live_requests = 0
    server.log_path = documents / "lan-test-events.json"
    server.outbox_path = documents.parent / "Library/Application Support/LANBackground-v2/receipts.json"
    server.destination = documents / "Music" / folder
    server.manifest = manifest
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    offer_path = documents / "lan-probe-offer.json"
    log_path = documents / "lan-test-events.json"
    destination = documents / "Music" / folder
    try:
        subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, check=False, timeout=15)
        log_path.unlink(missing_ok=True)
        (documents / "lan-test-background.json").unlink(missing_ok=True)
        control_path = documents / "lan-test-control-states.json"
        control_path.unlink(missing_ok=True)
        offer = {"protocolVersion": 1, "sessionID": str(uuid.uuid4()), "token": token,
                 "baseURLs": [f"http://127.0.0.1:{server.server_port}"],
                 "expiresAt": time.time() - 978_307_200 + 120, "files": manifest}
        offer_path.write_text(json.dumps(offer))
        args = ["launch", device, BUNDLE, "-lan-offer-file", offer_path.name]
        if cancel:
            args += ["-lan-cancel-after", str(pause_after + 0.9) if pause else "0.3"]
        if cancel_first:
            args += ["-lan-cancel-first-after", "0.8"]
        if pause:
            args += ["-lan-pause-after", str(pause_after), "-lan-resume-after", str(resume_after)]
        if background:
            args += ["-lan-background-after", "0.3"]
        launch_output = simctl(*args)
        if restart:
            assert server.request_started.wait(timeout=20), "download did not start before process restart"
            pid = int(launch_output.rsplit(":", 1)[1].strip())
            command = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True)
            assert "OfflineWatchPlayerLabWatch" in command, "unexpected simulator process"
            # A crash-style kill tests system-owned tasks, unlike an explicit
            # user force-quit, which tells the OS to cancel background transfers.
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.15)
            simctl("launch", device, BUNDLE, "-lan-restore-events")
        if capture:
            assert server.request_started.wait(timeout=15), "download did not reach the HTTP server"
            # Capture the active reception card, after launch-screen dismissal.
            time.sleep(0.8)
            capture.parent.mkdir(parents=True, exist_ok=True)
            simctl("io", device, "screenshot", str(capture))
        deadline = time.monotonic() + 90
        terminal = {}
        pause_observed = None
        held_without_store = False
        events = []
        while time.monotonic() < deadline:
            if log_path.exists():
                try:
                    events = json.loads(log_path.read_text())
                    terminal = {event["fileID"]: event for event in events if event["kind"] in ("stored", "failed", "cancelled")}
                    if pause and any(event["kind"] == "paused" for event in events):
                        if pause_observed is None:
                            pause_observed = time.monotonic()
                        resumed = any(event.get("controlRevision") == 2 for event in events)
                        if not resumed and not terminal and time.monotonic() - pause_observed >= 0.5:
                            assert not destination.exists() or not any(destination.iterdir()), "paused data entered the library"
                            if serial:
                                with server.request_lock:
                                    assert len(server.requests) == 1, "a waiting file started while the batch was paused"
                            held_without_store = True
                except (json.JSONDecodeError, OSError):
                    pass
            if len(terminal) == len(manifest):
                break
            time.sleep(0.1)
        assert len(terminal) == len(manifest), f"{title}: terminal receipts missing; observed {terminal}"
        if pause:
            assert pause_observed is not None and held_without_store, "pause was not held before storage"
            states = json.loads(control_path.read_text())
            for file in manifest:
                paused_states = [item for item in states if item["fileID"] == file["id"] and item["revision"] == 1]
                assert paused_states and paused_states[-1]["phase"] == "paused", "receiver did not persist pause"
                assert paused_states[-1]["nativeState"] in ("suspended", "cached", "notCreated"), "native task was not suspended"
                if paused_states[-1]["nativeState"] == "notCreated":
                    assert paused_states[-1]["receivedBytes"] == 0, "partly received paused work lost its native task"
                if partial:
                    assert 0 < paused_states[0]["receivedBytes"] < file["byteCount"], "partial data was not received before pausing"
                    assert len(paused_states) >= 3, "native pause did not remain observable for two seconds"
                    assert paused_states[-2]["nativeState"] == paused_states[-1]["nativeState"] == "suspended", "native partial task did not stay suspended"
                    assert paused_states[-2]["receivedBytes"] == paused_states[-1]["receivedBytes"], "delegate progress advanced during settled pause"
                    assert paused_states[-2]["nativeBytes"] == paused_states[-1]["nativeBytes"], "native task bytes advanced during settled pause"
            if cancel:
                # Stay alive past the scheduled resume; old-session work must
                # never recreate either a task record or a saved file.
                time.sleep(3.6)
            else:
                assert any(event.get("controlRevision") == 2 for event in events), "resume acknowledgement was not observed"
        expected = [expected_kind] * len(manifest) if isinstance(expected_kind, str) else expected_kind
        for file, expected_file_kind in zip(manifest, expected, strict=True):
            event = terminal[file["id"]]
            assert event["kind"] == expected_file_kind, f"{title}: expected {expected_file_kind}, got {event}"
            target = destination / file["fileName"]
            if expected_file_kind == "stored":
                assert target.is_file(), f"{title}: receipt without saved file"
                assert target.stat().st_size == file["byteCount"], f"{title}: wrong saved size"
                assert hashlib.sha256(target.read_bytes()).hexdigest() == file["sha256"], f"{title}: wrong saved content"
            else:
                assert not target.exists(), f"{title}: rejected/cancelled data must not enter the library"
        if background:
            assert (documents / "lan-test-background.json").exists(), "background transition hook did not run"
        if require_range:
            assert server.range_requests, "system download did not request a Range continuation"
            print("Native continuation observed: " + ", ".join(server.range_requests), flush=True)
        if expected_first_offset is not None:
            assert server.first_range is not None, "new session did not use a bounded Range"
            assert server.first_range == expected_first_offset, f"expected new session to start at {expected_first_offset}, got {server.first_range}"
        if serial:
            with server.request_lock:
                requests = list(server.requests)
                peak, live_peak = server.peak_requests, server.peak_live_requests
            assert [request["fileID"] for request in requests] == [file["id"] for file in manifest], "HTTP requests did not follow manifest order exactly once"
            assert live_peak == 1, f"multiple unfinished downloads active at once: {live_peak}"
            if not cancel_first:
                assert peak == 1, f"multiple HTTP response bodies active at once: {peak}"
            for index in range(1, len(manifest)):
                previous = manifest[index - 1]
                outcome = requests[index]["terminal"].get(previous["id"])
                assert outcome and outcome["kind"] == expected[index - 1], "next request began before previous terminal outcome was durable"
                if expected[index - 1] == "stored":
                    assert requests[index]["saved"][previous["id"]], "next request began before previous music file was saved"
            print(f"Serial requests verified: {len(requests)}, peak unfinished downloads {live_peak}", flush=True)
        print(f"PASS: {title} ({len(manifest)} file(s))", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        offer_path.unlink(missing_ok=True)
        if destination.exists():
            shutil.rmtree(destination)


def run_range_cases(device, documents, mp3):
    run_case(device, documents, "complete HTTP 206 file preserves integrity and saves",
             [(mp3, "range_full")], "stored")
    run_case(device, documents, "malformed Content-Range rejected despite matching complete bytes",
             [(mp3, "range_malformed")], "failed")
    run_case(device, documents, "valid HTTP 206 tail without assembled prefix never saves",
             [(mp3, "range_tail")], "failed")


def run_serial_cases(device, documents, mp3, flac):
    run_case(device, documents, "three files download and save strictly one at a time",
             [(mp3, "slow"), (flac, "normal"), (mp3, "normal")], "stored", serial=True)
    run_case(device, documents, "failed first file advances to the remaining serial queue",
             [(mp3, "http_error"), (flac, "normal"), (mp3, "normal")], ["failed", "stored", "stored"], serial=True)
    run_case(device, documents, "cancelled current file advances without starting two unfinished downloads",
             [(flac, "trickle"), (mp3, "normal"), (mp3, "normal")], ["cancelled", "stored", "stored"],
             cancel_first=True, serial=True)
    run_case(device, documents, "paused serial batch keeps waiting files unrequested until resume",
             [(mp3, "trickle"), (flac, "normal"), (mp3, "normal")], "stored", pause=True, serial=True,
             pause_after=2, resume_after=6)
    run_case(device, documents, "receiver process recovery preserves one-at-a-time queue order",
             [(mp3, "slow"), (flac, "normal"), (mp3, "normal")], "stored", restart=True, serial=True)
    run_case(device, documents, "background receiver advances the remaining serial queue after each save",
             [(mp3, "slow"), (flac, "normal"), (mp3, "normal")], "stored", background=True, serial=True)


def run_checkpoint_case(device, documents, mp3):
    folder = "LANProbe-" + str(uuid.uuid4())
    cache_root = documents.parent / "Library/Application Support/LANBackground-v2/Partial"
    index = cache_root / "index.json"
    with tempfile.TemporaryDirectory(prefix="WatchMusic-checkpoint-") as temporary:
        fixture = Path(temporary) / "multi-chunk.mp3"
        # Concatenated complete MP3 frames remain decodable. No playback occurs.
        fixture.write_bytes(mp3.read_bytes() * 32)
        try:
            run_case(device, documents, "interrupted source retains one complete 4 MiB response prefix",
                     [(fixture, "fail_after_first")], "failed", folder_override=folder, expected_first_offset=0)
            entries = json.loads(index.read_text())
            matching = [entry for entry in entries.values() if entry["identity"]["path"].startswith(folder.lower() + "/")]
            assert len(matching) == 1 and matching[0]["byteCount"] == 4 * 1024 * 1024, "first range checkpoint was not durable"
            assert (cache_root / matching[0]["name"]).stat().st_size == 4 * 1024 * 1024, "checkpoint prefix size mismatch"
            # run_case uses a fresh offer UUID, file UUID, bearer token, server
            # port, and process launch. Only the destination and SHA stay equal.
            run_case(device, documents, "new source session resumes the prefix with fresh URL/token and exact final SHA",
                     [(fixture, "normal")], "stored", folder_override=folder, expected_first_offset=4 * 1024 * 1024)
            remaining = json.loads(index.read_text())
            assert not any(entry["identity"]["path"].startswith(folder.lower() + "/") for entry in remaining.values()), "stored file retained an abandoned checkpoint"
            run_case(device, documents, "source interruption prepares a second prefix for corruption recovery",
                     [(fixture, "fail_after_first")], "failed", folder_override=folder, expected_first_offset=0)
            entries = json.loads(index.read_text())
            damaged = next(entry for entry in entries.values() if entry["identity"]["path"].startswith(folder.lower() + "/"))
            with (cache_root / damaged["name"]).open("r+b") as partial_file:
                first = partial_file.read(1)
                partial_file.seek(0)
                partial_file.write(bytes([first[0] ^ 0xFF]))
            run_case(device, documents, "final SHA rejects a damaged local prefix and discards its checkpoint",
                     [(fixture, "normal")], "failed", folder_override=folder, expected_first_offset=4 * 1024 * 1024)
            remaining = json.loads(index.read_text())
            assert not any(entry["identity"]["path"].startswith(folder.lower() + "/") for entry in remaining.values()), "integrity failure retained a bad checkpoint"
            run_case(device, documents, "retry after integrity failure starts clean and saves exact content",
                     [(fixture, "normal")], "stored", folder_override=folder, expected_first_offset=0)
        finally:
            # Clean only this unique synthetic test folder's abandoned prefix.
            if index.exists():
                entries = json.loads(index.read_text())
                for key, entry in list(entries.items()):
                    if entry["identity"]["path"].startswith(folder.lower() + "/"):
                        (cache_root / entry["name"]).unlink(missing_ok=True)
                        del entries[key]
                index.write_text(json.dumps(entries))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Booted watch simulator UDID")
    parser.add_argument("--app", type=Path, help="Install this Debug Watch .app before running")
    parser.add_argument("--capture", type=Path, help="Save a screenshot during the first download")
    parser.add_argument("--success-only", action="store_true", help="Run only the successful-download scenario")
    parser.add_argument("--background-only", action="store_true", help="Run background and process-recovery scenarios only")
    parser.add_argument("--pause-only", action="store_true", help="Run native pause/resume and cancellation-while-paused scenarios")
    parser.add_argument("--range-only", action="store_true", help="Run complete, malformed and incomplete HTTP 206 response scenarios")
    parser.add_argument("--disconnect-resume-only", action="store_true", help="Diagnose one suspended TCP disconnect and native Range continuation")
    parser.add_argument("--serial-only", action="store_true", help="Verify serial order, terminal gating, failure/cancel advance, pause and process recovery")
    parser.add_argument("--checkpoint-only", action="store_true", help="Verify durable 4 MiB prefix recovery using a fresh session, URL, and token")
    args = parser.parse_args()
    if args.app:
        simctl("install", args.device, str(args.app.resolve()))
    container = Path(simctl("get_app_container", args.device, BUNDLE, "data"))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    mp3, flac = (ROOT / "Tests/Fixtures" / name for name in ["EmbeddedResources.mp3", "EmbeddedResources.flac"])
    try:
        if args.checkpoint_only:
            run_checkpoint_case(args.device, documents, mp3)
            return
        if args.serial_only:
            run_serial_cases(args.device, documents, mp3, flac)
            return
        if args.disconnect_resume_only:
            run_case(args.device, documents, "suspended TCP disconnect resumes with native Range request and matching SHA",
                     [(mp3, "disconnect_resume")], "stored", pause=True, pause_after=2, resume_after=6,
                     partial=True, require_range=True)
            return
        if args.range_only:
            run_range_cases(args.device, documents, mp3)
            return
        if args.pause_only:
            run_case(args.device, documents, "partially received native task stops bytes then resumes",
                     [(mp3, "trickle")], "stored", pause=True, pause_after=2, resume_after=6, partial=True)
            run_case(args.device, documents, "native pause then resume preserves MP3 and FLAC",
                     [(mp3, "slow"), (flac, "slow")], "stored", pause=True)
            run_case(args.device, documents, "cancel paused batch prevents late resume and save",
                     [(mp3, "slow")], "cancelled", pause=True, cancel=True)
            return
        if args.background_only:
            run_case(args.device, documents, "background transition does not cancel batch",
                     [(mp3, "slow"), (flac, "slow")], "stored", background=True)
            run_case(args.device, documents, "system download survives receiver process restart",
                     [(mp3, "slow"), (flac, "slow")], "stored", restart=True)
            return
        run_case(args.device, documents, "MP3 and FLAC download, integrity and save receipts",
                 [(mp3, "slow"), (flac, "normal")], "stored", args.capture)
        if args.success_only:
            return
        run_case(args.device, documents, "same-size corrupt content rejected", [(flac, "corrupt")], "failed")
        run_case(args.device, documents, "HTTP failure rejected", [(mp3, "http_error")], "failed")
        run_case(args.device, documents, "redirected final URL rejected even for matching bytes", [(mp3, "redirect")], "failed")
        run_case(args.device, documents, "oversized response rejected", [(mp3, "oversize")], "failed")
        run_case(args.device, documents, "cancel prevents later save", [(flac, "slow")], "cancelled", cancel=True)
        run_range_cases(args.device, documents, mp3)
        print("PASS: real watch URLSession LAN transfer probe", flush=True)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True, check=False, timeout=15)


if __name__ == "__main__":
    main()
