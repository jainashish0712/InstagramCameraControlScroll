# SpringBoard HID probe

This SpringBoard component receives Camera Control input independently of Instagram's active capture session:

- `IOHIDEventSystemClient` uses the Monitor client type to observe system HID events.
- Non-display digitizer deltas are relayed to Instagram through a Darwin notification. Instagram applies them through its existing scroll engine only while foregrounded and no Instagram capture-control slider session is running.
- `UIApplication -_handleHIDEvent:` remains observational and forwards the original event unchanged.

The private HID monitor and Darwin notification functions are resolved dynamically. If monitor client creation or notification registration fails, the component logs that failure and the Feed receiver cannot work on that build. HID input is never consumed or dispatched. Non-display digitizer events are treated as Camera Control candidates; this hardware classification remains an inference because iOS does not expose a public Feed API for these swipes.

## Install

On the rootless Dopamine/ElleKit device, copy `CameraControlSystemProbe.dylib` and its matching `CameraControlSystemProbe.plist` to:

`/var/jb/Library/MobileSubstrate/DynamicLibraries/`

Then respring. The filter limits injection to `com.apple.springboard`. Keep the existing Instagram dylib and its filter installed separately.

## Capture a trace

Clear or note the current log, then test the same Camera Control swipe in Instagram Feed with the camera screen closed and again in Instagram Camera. On-device, inspect the trace with:

```sh
log show --last 5m --style compact --predicate 'process == "SpringBoard" AND eventMessage CONTAINS "CameraControlSystemProbe"'
```

The component logs every callback event from the system monitor plus events reaching SpringBoard's UIKit handler, so ordinary input can produce substantial output. Use a short capture window.

The existing `logs/` files are Instagram telemetry databases and do not record these SpringBoard events. Feed scrolling requires the monitor to receive non-display digitizer samples and the Instagram notification receiver to register successfully.
