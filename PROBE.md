# SpringBoard HID probe

This temporary probe observes `UIApplication -_handleHIDEvent:` inside SpringBoard. It logs each event and nested digitizer/vendor event fields, then calls the original handler unchanged. It does not claim every logged event is from Camera Control and does not scroll the feed.

## Install

On the rootless Dopamine/ElleKit device, copy `CameraControlSystemProbe.dylib` and its matching `CameraControlSystemProbe.plist` to:

`/var/jb/Library/MobileSubstrate/DynamicLibraries/`

Then respring. The filter limits injection to `com.apple.springboard`. Keep the existing Instagram dylib and its filter installed separately.

## Capture a trace

Clear or note the current log, then test the same Camera Control swipe in Instagram Feed with the camera screen closed and again in Instagram Camera. On-device, inspect the trace with:

```sh
log show --last 5m --style compact --predicate 'process == "SpringBoard" AND eventMessage CONTAINS "CameraControlSystemProbe"'
```

The probe logs every HID event that reaches SpringBoard's UIKit handler, so ordinary system input can produce substantial output.

If a swipe appears in the SpringBoard trace, compare its type and digitizer/vendor fields with baseline input before implementing a handler. If it does not appear, that only rules out this SpringBoard UIKit entry point; it does not prove the event is absent from BackBoard or another system process.
