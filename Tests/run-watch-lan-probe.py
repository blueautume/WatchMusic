#!/usr/bin/env python3
"""Exercise daemon-owned Watch downloads with real simulator HTTP (Debug only).

Switching to Settings verifies an actual simulator scene transition. It does not
validate physical display sleep, system resource policy, or TestFlight behavior.
"""
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
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BUNDLE = "com.lihao.WatchMusic.watchkitapp"
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
        self.completed_response_body = False
        try:
            self.serve_route(route)
        finally:
            with self.server.request_lock:
                self.server.active_requests.pop(self, None)
            if self.completed_response_body and hasattr(self.server, "response_finished"):
                self.server.response_finished.set()

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
        disconnect_this_request = False
        if behavior == "disconnect_resume":
            requested_range = self.headers.get("Range")
            if requested_range is not None:
                self.server.range_requests.append(requested_range)
                assert requested_range.startswith("bytes=") and requested_range.endswith("-"), "unexpected native Range header"
                resume_offset = int(requested_range[6:-1])
                assert 0 < resume_offset < full_size, "native download requested an invalid continuation"
                body = body[resume_offset:]
            elif self.path not in self.server.disconnected_paths:
                self.server.disconnected_paths.add(self.path)
                disconnect_this_request = True
        if behavior == "range_tail":
            body = body[full_size // 2:]
        self.send_response(206 if behavior.startswith("range_") or resume_offset is not None else 200)
        if behavior == "disconnect_resume":
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '"' + hashlib.sha256(route[0]).hexdigest() + '"')
            if resume_offset is not None:
                self.send_header("Content-Range", f"bytes {resume_offset}-{full_size - 1}/{full_size}")
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
                        self.completed_response_body = True
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
             check_handshake=False, inactive_during=None, pause_restart=False,
             background_during_save=False, cancel_during_save=False, delayed_restart=False):
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
        if behavior == "redirect":
            routes["/v1/files/" + identifier + "/redirected"] = (body, "normal")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.routes, server.token = routes, token
    server.range_requests, server.disconnected_paths = [], set()
    server.request_started = threading.Event()
    server.response_finished = threading.Event()
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
    lifecycle_path = documents / "lan-lifecycle-events.json"
    destination = documents / "Music" / folder
    try:
        if delayed_restart:
            # Avoid force-quit semantics even when clearing a previous idle
            # process: a manual launch followed by SIGKILL leaves daemon work
            # eligible for system relaunch.
            crash_process(device, simctl("launch", device, BUNDLE))
        else:
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
        if background or restart or delayed_restart or pause_restart or check_handshake or inactive_during or cancel_during_save:
            lifecycle_path.unlink(missing_ok=True)
            args += ["-lan-record-lifecycle"]
        if background_during_save or cancel_during_save:
            args += ["-lan-save-delay", "3.0"]
        if cancel_during_save:
            args += ["-lan-cancel-during-save"]
        if inactive_during:
            args += ["-lan-inactive-during-" + inactive_during]
            if inactive_during == "save":
                args += ["-lan-save-delay", "1.0"]
        if cancel:
            args += ["-lan-cancel-after", str(pause_after + 0.9) if pause else "0.3"]
        if cancel_first:
            args += ["-lan-cancel-first-after", "0.8"]
        if pause:
            args += ["-lan-pause-after", str(pause_after), "-lan-resume-after", str(resume_after)]
        launch_output = simctl(*args)
        if background or restart or delayed_restart or pause_restart:
            assert server.request_started.wait(timeout=25), "download did not start before lifecycle test"
        if background_during_save:
            snapshot = documents.parent / "Library/Application Support/LANBackground-v2/transfer.json"
            wait_for_events(snapshot, lambda value: any(item.get("phase") == "validating" for item in value.get("items", {}).values()),
                            "download did not enter durable validation before switching apps")
        if background:
            simctl("launch", device, "com.apple.NanoSettings")
            wait_for_lifecycle(lifecycle_path, lambda item: item.get("event") == "scenePhase" and item.get("phase") == "background",
                               "the system did not move the app to background")
        if restart:
            crash_process(device, launch_output)
            simctl("launch", device, BUNDLE, "-lan-restore-events", "-lan-record-lifecycle")
            wait_for_lifecycle(lifecycle_path, lambda item: item.get("event") == "probeTasksReconciled" and item.get("count", 0) > 0,
                               "a relaunched process did not re-associate a live daemon task")
        if delayed_restart:
            crash_process(device, launch_output)
            assert server.response_finished.wait(timeout=45), "daemon did not finish HTTP while the app process was absent"
            # The OS may relaunch with no Debug arguments. Give that path a
            # chance, then manually reopen only after the body is complete.
            time.sleep(3)
            simctl("launch", device, BUNDLE, "-lan-restore-events", "-lan-record-lifecycle")
            target = destination / manifest[0]["fileName"]
            wait_for_saved_file(target, manifest[0], timeout=45)
            # Late completion/error delivery must neither replace the saved
            # file nor create a second HTTP request after this final save.
            saved_stat = target.stat()
            time.sleep(2)
            assert target.stat().st_ino == saved_stat.st_ino, "late callback saved the same file again"
            assert hashlib.sha256(target.read_bytes()).hexdigest() == manifest[0]["sha256"], "late callback changed saved content"
            with server.request_lock:
                requests = [item for item in server.requests if item["fileID"] == manifest[0]["id"]]
            assert len(requests) == 1, f"completed daemon download was fetched again after relaunch: {len(requests)} requests"
            print(f"PASS: {title}; exact SHA, one HTTP request, stable saved inode", flush=True)
            return
        if pause_restart:
            wait_for_events(log_path, lambda items: any(item.get("kind") == "paused" for item in items),
                            "manual pause was not acknowledged")
            crash_process(device, launch_output)
            relaunch = simctl("launch", device, BUNDLE, "-lan-restore-events", "-lan-record-lifecycle")
            wait_for_lifecycle(lifecycle_path, lambda item: item.get("event") == "probeTasksReconciled" and item.get("count", 0) > 0,
                               "paused daemon task was not re-associated")
            before = {file["id"]: (destination / file["fileName"]).exists() for file in manifest}
            assert not any(before.values()), "manually paused file saved during restart"
            time.sleep(1)
            assert not any((destination / file["fileName"]).exists() for file in manifest), "restart automatically resumed a manual pause"
            crash_process(device, relaunch)
            command = {"sessionID": offer["sessionID"], "kind": "stop" if cancel else "resume", "controlRevision": 2}
            command_path = documents / "lan-probe-command.json"
            command_path.write_text(json.dumps(command))
            simctl("launch", device, BUNDLE, "-lan-restore-events", "-lan-record-lifecycle",
                   "-lan-probe-command-file", command_path.name)
        if capture:
            assert server.request_started.wait(timeout=15), "download did not reach the HTTP server"
            # Capture the active reception card, after launch-screen dismissal.
            time.sleep(0.8)
            capture.parent.mkdir(parents=True, exist_ok=True)
            simctl("io", device, "screenshot", str(capture))
        deadline = time.monotonic() + 120
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
                            held_without_store = True
                except (json.JSONDecodeError, OSError):
                    pass
            if len(terminal) == len(manifest):
                break
            time.sleep(0.1)
        assert len(terminal) == len(manifest), f"{title}: terminal receipts missing; observed {terminal}"
        if pause and not pause_restart:
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
        if cancel_during_save:
            wait_for_lifecycle(lifecycle_path, lambda item: item.get("event") == "probeCancelledDuringSave",
                               "cancellation did not race an in-flight validation")
            time.sleep(3.2)
            events = json.loads(log_path.read_text())
        expected = [expected_kind] * len(manifest) if isinstance(expected_kind, str) else expected_kind
        for file, expected_file_kind in zip(manifest, expected, strict=True):
            event = terminal[file["id"]]
            assert event["kind"] == expected_file_kind, f"{title}: expected {expected_file_kind}, got {event}"
            outcomes = {item["kind"] for item in events
                        if item.get("fileID") == file["id"] and item.get("kind") in ("stored", "failed", "cancelled")}
            assert outcomes == {expected_file_kind}, f"{title}: replay or late callbacks changed the final outcome: {outcomes}"
            target = destination / file["fileName"]
            if expected_file_kind == "stored":
                assert target.is_file(), f"{title}: receipt without saved file"
                assert target.stat().st_size == file["byteCount"], f"{title}: wrong saved size"
                assert hashlib.sha256(target.read_bytes()).hexdigest() == file["sha256"], f"{title}: wrong saved content"
            else:
                assert not target.exists(), f"{title}: rejected/cancelled data must not enter the library"
        if check_handshake:
            lifecycle = json.loads(lifecycle_path.read_text())
            assert any(item["event"] == "probeTasksReconciled" for item in lifecycle), "daemon enumeration was not observed"
            assert any(item["event"] == "offerAccepted" for item in lifecycle), "offer was not accepted"
        if inactive_during:
            lifecycle = json.loads(lifecycle_path.read_text())
            observations = [(index, event["phase"]) for index, event in enumerate(lifecycle)
                            if event["event"] == "probeEnteredInactive"]
            expected_phase = "validating" if inactive_during == "save" else "downloading"
            assert len(observations) == 1 and observations[0][1] == expected_phase, (
                f"{title}: missing inactive transition during {expected_phase}; observed {observations}"
            )
            stored_after_inactive = {event["fileID"] for event in lifecycle[observations[0][0] + 1:]
                                     if event["event"] == "stored" and event.get("sessionID") == offer["sessionID"]}
            assert stored_after_inactive == {file["id"] for file in manifest}, f"{title}: not all files saved after entering inactive"
            assert not any(event["kind"] in ("paused", "resumed") for event in events), f"{title}: inactive interrupted the batch"
        if background:
            lifecycle = json.loads(lifecycle_path.read_text())
            entered = next(index for index, item in enumerate(lifecycle)
                           if item.get("event") == "scenePhase" and item.get("phase") == "background")
            saved_after_background = {item.get("fileID") for item in lifecycle[entered + 1:]
                                      if item.get("event") == "stored" and item.get("sessionID") == offer["sessionID"]}
            assert saved_after_background == {file["id"] for file, kind in zip(manifest, expected) if kind == "stored"}, (
                "files did not complete after the real simulator background transition"
            )
            assert not any(item.get("kind") == "paused" and item.get("automaticPause") is True for item in events), (
                "backgrounding automatically paused daemon-owned downloads"
            )
        if require_range:
            assert server.range_requests, "system download did not request a Range continuation"
            print("Native continuation observed: " + ", ".join(server.range_requests), flush=True)
        if serial:
            with server.request_lock:
                requested = {request["fileID"] for request in server.requests}
            assert requested <= {file["id"] for file in manifest}, "HTTP requested a file outside the accepted manifest"
            print(f"Batch outcomes verified: {len(manifest)}; daemon controls HTTP scheduling", flush=True)
        print(f"PASS: {title} ({len(manifest)} file(s))", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        offer_path.unlink(missing_ok=True)
        (documents / "lan-probe-command.json").unlink(missing_ok=True)
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
    run_case(device, documents, "three pre-submitted files download and save with exact outcomes",
             [(mp3, "slow"), (flac, "normal"), (mp3, "normal")], "stored", serial=True)
    run_case(device, documents, "one failed file leaves other accepted files runnable",
             [(mp3, "http_error"), (flac, "normal"), (mp3, "normal")], ["failed", "stored", "stored"], serial=True)
    run_case(device, documents, "cancelling one accepted file leaves the other files runnable",
             [(flac, "trickle"), (mp3, "normal"), (mp3, "normal")], ["cancelled", "stored", "stored"],
             cancel_first=True, serial=True)
    run_case(device, documents, "manually paused batch does not publish files until resume",
             [(mp3, "trickle"), (flac, "trickle"), (mp3, "trickle")], "stored", pause=True, serial=True,
             pause_after=2, resume_after=6)


def run_inactive_cases(device, documents, mp3, flac):
    run_case(device, documents, "policy-only inactive transition preserves an accepted batch",
             [(mp3, "trickle"), (flac, "normal")], "stored", serial=True, inactive_during="download")
    run_case(device, documents, "policy-only inactive transition preserves an in-flight save",
             [(mp3, "normal")], "stored", serial=True, inactive_during="save")


def wait_for_events(path, predicate, message, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            items = json.loads(path.read_text())
            if predicate(items):
                return items
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise AssertionError(message)


def wait_for_lifecycle(path, predicate, message, timeout=30):
    return wait_for_events(path, lambda items: any(predicate(item) for item in items), message, timeout)


def wait_for_saved_file(path, file, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if path.stat().st_size == file["byteCount"] and hashlib.sha256(path.read_bytes()).hexdigest() == file["sha256"]:
                return
        except OSError:
            pass
        time.sleep(0.05)
    raise AssertionError("completed daemon bytes were not validated and saved after delayed relaunch")


def crash_process(device, launch_output):
    pid = int(launch_output.rsplit(":", 1)[1].strip())
    command = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True)
    assert "WatchMusicWatch" in command, "unexpected simulator process"
    # SIGKILL simulates a crash, not the user's force-quit cancellation intent.
    os.kill(pid, signal.SIGKILL)
    time.sleep(0.15)


def run_save_cases(device, documents, mp3):
    run_case(device, documents, "in-flight validation saves after an actual simulator background transition",
             [(mp3, "normal")], "stored", background=True, background_during_save=True)
    run_case(device, documents, "cancel during validation blocks late atomic save",
             [(mp3, "normal")], "cancelled", cancel_during_save=True)


def run_background_cases(device, documents, mp3, flac):
    run_case(device, documents, "accepted batch completes after switching to Settings (actual simulator background)",
             [(mp3, "trickle"), (flac, "trickle")], "stored", background=True)
    run_save_cases(device, documents, mp3)
    run_case(device, documents, "new process re-associates daemon download without a fresh offer",
             [(mp3, "trickle")], "stored", restart=True)
    run_case(device, documents, "completed daemon download is delivered after delayed process relaunch",
             [(mp3, "trickle")], "stored", delayed_restart=True)
    run_case(device, documents, "manual pause survives process recreation and explicit resume saves",
             [(mp3, "trickle")], "stored", pause=True, pause_after=1.5, resume_after=60, pause_restart=True)
    run_case(device, documents, "cancel restored manually paused download prevents later save",
             [(mp3, "trickle")], "cancelled", pause=True, cancel=True, pause_after=1.5,
             resume_after=60, pause_restart=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Booted watch simulator UDID")
    parser.add_argument("--app", type=Path, help="Install this Debug Watch .app before running")
    parser.add_argument("--capture", type=Path, help="Save a screenshot during the first download")
    parser.add_argument("--success-only", action="store_true", help="Run only the successful-download scenario")
    parser.add_argument("--background-only", action="store_true", help="Verify actual simulator background and process re-association")
    parser.add_argument("--pause-only", action="store_true", help="Run native pause/resume and cancellation-while-paused scenarios")
    parser.add_argument("--range-only", action="store_true", help="Run complete, malformed and incomplete HTTP 206 response scenarios")
    parser.add_argument("--disconnect-resume-only", action="store_true", help="Verify daemon task re-association after process recreation")
    parser.add_argument("--serial-only", action="store_true", help="Verify accepted batch outcomes, failure/cancel isolation and manual pause")
    parser.add_argument("--foreground-only", action="store_true", help="Compatibility alias for the background download suite")
    parser.add_argument("--inactive-only", action="store_true", help="Verify accepted downloads and saves continue while frontmost inactive")
    parser.add_argument("--handshake-only", action="store_true", help="Verify daemon task enumeration and offer acceptance")
    parser.add_argument("--save-only", action="store_true", help="Verify real background validation and cancellation before atomic save")
    parser.add_argument("--completion-replay-only", action="store_true", help="Crash, finish HTTP without the app, then restore without refetching or duplicate save")
    args = parser.parse_args()
    if args.app:
        simctl("install", args.device, str(args.app.resolve()))
    container = Path(simctl("get_app_container", args.device, BUNDLE, "data"))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    mp3, flac = (ROOT / "Tests/Fixtures" / name for name in ["EmbeddedResources.mp3", "EmbeddedResources.flac"])
    try:
        if args.completion_replay_only:
            run_case(args.device, documents, "completed daemon download is delivered after delayed process relaunch",
                     [(mp3, "trickle")], "stored", delayed_restart=True)
            return
        if args.save_only:
            run_save_cases(args.device, documents, mp3)
            return
        if args.handshake_only:
            run_case(args.device, documents, "daemon task enumeration and offer acceptance",
                     [(mp3, "normal")], "stored", serial=True, check_handshake=True)
            return
        if args.foreground_only or args.background_only or args.disconnect_resume_only:
            run_background_cases(args.device, documents, mp3, flac)
            return
        if args.inactive_only:
            run_inactive_cases(args.device, documents, mp3, flac)
            return
        if args.serial_only:
            run_serial_cases(args.device, documents, mp3, flac)
            return
        if args.range_only:
            run_range_cases(args.device, documents, mp3)
            return
        if args.pause_only:
            run_case(args.device, documents, "partially received native task stops bytes then resumes",
                     [(mp3, "trickle")], "stored", pause=True, pause_after=2, resume_after=6, partial=True,
                     )
            run_case(args.device, documents, "native pause then resume preserves MP3 and FLAC",
                     [(mp3, "slow"), (flac, "slow")], "stored", pause=True)
            run_case(args.device, documents, "cancel paused batch prevents late resume and save",
                     [(mp3, "slow")], "cancelled", pause=True, cancel=True)
            return
        run_case(args.device, documents, "MP3 and FLAC download, integrity and save receipts",
                 [(mp3, "slow"), (flac, "normal")], "stored", args.capture)
        if args.success_only:
            return
        run_case(args.device, documents, "same-size corrupt content rejected", [(flac, "corrupt")], "failed")
        run_case(args.device, documents, "HTTP failure rejected", [(mp3, "http_error")], "failed")
        run_case(args.device, documents, "redirected final URL rejected even for matching bytes", [(mp3, "redirect")], "failed")
        run_case(args.device, documents, "oversized response rejected", [(mp3, "oversize")], "failed")
        run_case(args.device, documents, "cancel prevents later save", [(flac, "slow")], "cancelled", cancel=True,
                 )
        run_range_cases(args.device, documents, mp3)
        run_background_cases(args.device, documents, mp3, flac)
        print("PASS: simulator daemon-owned Watch URLSession probe; physical sleep still requires device acceptance", flush=True)
    finally:
        if not args.completion_replay_only:
            subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True, check=False, timeout=15)


if __name__ == "__main__":
    main()
