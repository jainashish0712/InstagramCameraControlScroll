# SpringBoard HID probe

This temporary probe has two passive observers in SpringBoard:

- `IOHIDEventSystemClient` with the Monitor client type, which logs every callback event and its nested digitizer/vendor fields.
- `UIApplication -_handleHIDEvent:`, which logs events reaching UIKit and calls the original handler unchanged.

The private HID monitor is resolved dynamically. The log states whether its symbols were found and whether client creation succeeded; a failed or absent callback means this observation path is unavailable on that device/build. Neither observer consumes or dispatches events, and neither scrolls the feed. The trace does not identify Camera Control by itself; compare the event shape against ordinary touchscreen swipes and the working Instagram Camera swipe.

## Install

On the rootless Dopamine/ElleKit device, copy `CameraControlSystemProbe.dylib` and its matching `CameraControlSystemProbe.plist` to:

`/var/jb/Library/MobileSubstrate/DynamicLibraries/`

Then respring. The filter limits injection to `com.apple.springboard`. Keep the existing Instagram dylib and its filter installed separately.

## Capture a trace

Clear or note the current log, then test the same Camera Control swipe in Instagram Feed with the camera screen closed and again in Instagram Camera. On-device, inspect the trace with:

```sh
log show --last 5m --style compact --predicate 'process == "SpringBoard" AND eventMessage CONTAINS "CameraControlSystemProbe"'
```

The probe logs every callback event from the system monitor plus events reaching SpringBoard's UIKit handler, so ordinary input can produce substantial output. Use a short capture window.

If the swipe appears in the system-monitor callback, its payload can guide the Feed receiver. If it appears only in UIKit, that gives a different candidate path. If it appears in neither, that only rules out these SpringBoard observers; it does not prove the event is absent from BackBoard or another system process.
