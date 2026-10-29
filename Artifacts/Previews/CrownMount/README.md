# Native Crown volume mounting evidence

The original implementation put `WKInterfaceVolumeControl` inside a
`digitalCrownAccessory`. In this actual non-scrolling playback page, the native
control was never instantiated: both 40mm and 49mm baseline traces contain only
`page-appeared` and no `made`, `updated`, or `focus-requested` events.

The fix mounts the native control at normal size/opacity behind the existing
opaque page. It does not add a visible volume control or change the foreground
player layout. The 40mm before/after screenshots have zero changed pixels after
excluding the physical system-clock corner. The 49mm fixed screenshot was
visually checked; its baseline screenshot caught a launch overlay and is not
included as a misleading comparison.

For each simulator size:

- `baseline.jsonl`: old accessory implementation, page appears but no native control.
- `fixed.jsonl`: actual native creation, update, and initial focus request.
- `dialog.jsonl`: the native control mounts, but does not request Crown focus
  while a speed-selection dialog is presented.
- `cycle.jsonl`: a DEBUG-only fixture waits for the actual initial focus request,
  then presents the original speed dialog, closes it, and calls the same page
  dismissal action. Actual events verify focus release, refocus, navigation pop,
  native dismantling, and final cleanup without a later focus request.

These are real simulator lifecycle events, not manually generated event lists.
The cycle uses programmatic DEBUG fixture actions, not manual OS input. No audio
is played. The fixtures cannot demonstrate physical Crown rotation, successful
focus ownership on every Watch, or an audible change on a Bluetooth output.
Those final checks belong to the user's manual device test.

Diagnostics require a Debug simulator build and the explicit
`-preview-crown-trace` launch flag; Release and physical-device builds produce
no trace. Run the regression against a built Debug Watch app with:

```sh
python3 Tests/run-watch-crown-mount-probe.py BOOTED_WATCH_SIMULATOR_UDID /absolute/path/WatchMusicWatch.app
python3 Tests/run-watch-crown-mount-probe.py BOOTED_WATCH_SIMULATOR_UDID /absolute/path/WatchMusicWatch.app --dialog
python3 Tests/run-watch-crown-mount-probe.py BOOTED_WATCH_SIMULATOR_UDID /absolute/path/WatchMusicWatch.app --cycle
```
