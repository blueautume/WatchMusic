#!/usr/bin/env python3
"""Verify the real native volume bridge mounts and requests focus in a Watch simulator.

This does not rotate a physical Crown or assert that an audio output changed.
The preview restores a paused local fixture and never activates playback.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time


def simctl(*arguments, check=True):
    return subprocess.run(["xcrun", "simctl", *arguments], check=check,
                          text=True, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device", help="booted watchOS simulator UUID")
    parser.add_argument("app", type=Path, help="Debug Watch .app with crown diagnostics")
    scenario = parser.add_mutually_exclusive_group()
    scenario.add_argument("--dialog", action="store_true", help="verify a presented speed dialog prevents volume focus")
    scenario.add_argument("--cycle", action="store_true", help="exercise actual dialog presentation, closure and page teardown")
    parser.add_argument("--trace-output", type=Path)
    arguments = parser.parse_args()
    devices = json.loads(simctl("list", "devices", "--json"))["devices"]
    matching = [(runtime, item) for runtime, items in devices.items() for item in items
                if item["udid"] == arguments.device]
    assert matching and "watchOS" in matching[0][0] and matching[0][1]["state"] == "Booted", "requires a booted Watch simulator"
    app = arguments.app.resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    assert bundle == "com.lihao.WatchMusic.watchkitapp", "unexpected app"
    root = Path(__file__).resolve().parent.parent

    def container():
        return Path(simctl("get_app_container", arguments.device, bundle, "data"))

    preference_name = f"{bundle}.plist"
    existing = simctl("get_app_container", arguments.device, bundle, "data", check=False)
    preferences = Path(existing) / "Library/Preferences" / preference_name if existing else None
    values = plistlib.loads(preferences.read_bytes()) if preferences and preferences.exists() else {}
    keys = ("player.session", "player.volume")
    backup = {key: values[key] for key in keys if key in values}
    simctl("terminate", arguments.device, bundle, check=False)
    simctl("install", arguments.device, str(app))
    data = container()  # Reinstallation can migrate the app's sandbox UUID.
    fixture = data / "Documents/Music/UI预览/测试旋律.flac"
    fixture_created = not fixture.exists()
    folder_created = not fixture.parent.exists()
    trace = data / "Library/Application Support/.watch-crown-trace.jsonl"
    prior_trace = trace.read_bytes() if trace.exists() else None
    try:
        if fixture_created:
            fixture.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / "Tests/Fixtures/EmbeddedResources.flac", fixture)
        trace.unlink(missing_ok=True)
        launch = ["launch", arguments.device, bundle, "-preview-player", "-preview-crown-trace"]
        if arguments.dialog:
            launch.append("-preview-playback-rate")
        if arguments.cycle:
            launch.append("-preview-crown-cycle")
        simctl(*launch)
        events = []
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            events = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            names = [event["event"] for event in events]
            complete = "page-appeared" in names and "made" in names and "updated" in names
            cycle_complete = not arguments.cycle or ("dismantled" in names and "page-disappeared" in names
                                                      and "focus-resigned" in names[names.index("dismantled") + 1:])
            if complete and cycle_complete and (arguments.dialog or "focus-requested" in names):
                if arguments.dialog:
                    # An absence assertion needs to include the settled page,
                    # not just the first pre-appearance representable update.
                    time.sleep(.4)
                    events = [json.loads(line) for line in trace.read_text().splitlines()]
                break
            time.sleep(.05)
        names = [event["event"] for event in events]
        if arguments.trace_output:
            arguments.trace_output.parent.mkdir(parents=True, exist_ok=True)
            arguments.trace_output.write_text("".join(json.dumps(event, sort_keys=True) + "\n" for event in events))
        assert "page-appeared" in names, f"playback page never appeared: {names}"
        assert "made" in names and "updated" in names, f"native volume control not mounted: {names}"
        if arguments.dialog:
            assert "focus-requested" not in names, f"volume must not capture the dialog's Crown: {names}"
            assert all(not event.get("focused", False) for event in events if event["event"] == "updated")
        else:
            assert "focus-requested" in names, f"mounted volume control did not request native Crown focus: {names}"
        if arguments.cycle:
            expected = ["made", "page-appeared", "focus-requested", "cycle-dialog-open",
                        "focus-resigned", "cycle-dialog-close", "focus-requested", "cycle-page-dismiss"]
            cursor = 0
            for event in expected:
                assert event in names[cursor:], f"missing/out-of-order {event}: {names}"
                cursor = names.index(event, cursor) + 1
            assert "page-disappeared" in names[cursor:] and "dismantled" in names[cursor:], names
            assert "focus-resigned" in names[names.index("dismantled") + 1:], names
            assert "focus-requested" not in names[cursor:], names
        print("PASS: native Watch volume bridge mounted; " +
              ("dialog release/refocus and native teardown" if arguments.cycle else
               "dialog retains Crown input" if arguments.dialog else "native Crown focus requested") +
              f" ({len(events)} actual lifecycle events)")
    finally:
        simctl("terminate", arguments.device, bundle, check=False)
        if fixture_created:
            fixture.unlink(missing_ok=True)
        if folder_created and fixture.parent.exists() and not any(fixture.parent.iterdir()):
            fixture.parent.rmdir()
        if prior_trace is not None:
            trace.write_bytes(prior_trace)
        else:
            trace.unlink(missing_ok=True)
        preferences = data / "Library/Preferences" / preference_name
        values = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
        for key in keys:
            values.pop(key, None)
            if key in backup:
                values[key] = backup[key]
        preferences.parent.mkdir(parents=True, exist_ok=True)
        preferences.write_bytes(plistlib.dumps(values))


if __name__ == "__main__":
    main()
