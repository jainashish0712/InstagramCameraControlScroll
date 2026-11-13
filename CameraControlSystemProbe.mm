// Temporary SpringBoard-side probe for Camera Control HID delivery.
// This observer logs events and always forwards them unchanged.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdint.h>
#import <unistd.h>
#import <math.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDEventField;

static const IOHIDEventType kProbeHIDEventTypeVendorDefined = 1;
static const IOHIDEventType kProbeHIDEventTypeDigitizer = 11;
static const IOHIDEventField kProbeDigitizerX = 0x000B0000;
static const IOHIDEventField kProbeDigitizerY = 0x000B0001;
static const IOHIDEventField kProbeDigitizerEventMask = 0x000B0007;
static const IOHIDEventField kProbeDigitizerTouch = 0x000B0009;
static const IOHIDEventField kProbeDigitizerDisplayIntegrated = 0x000B0019;
static const IOHIDEventField kProbeVendorUsagePage = 0x00010000;
static const IOHIDEventField kProbeVendorUsage = 0x00010001;
static const IOHIDEventField kProbeVendorDataLength = 0x00010003;

typedef IOHIDEventType (*IOHIDEventGetTypeFunc)(IOHIDEventRef);
typedef int32_t (*IOHIDEventGetIntegerValueFunc)(IOHIDEventRef, IOHIDEventField);
typedef double (*IOHIDEventGetFloatValueFunc)(IOHIDEventRef, IOHIDEventField);
typedef CFArrayRef (*IOHIDEventGetChildrenFunc)(IOHIDEventRef);

static IOHIDEventGetTypeFunc s_getType;
static IOHIDEventGetIntegerValueFunc s_getInteger;
static IOHIDEventGetFloatValueFunc s_getFloat;
static IOHIDEventGetChildrenFunc s_getChildren;
static void *s_iokitHandle;
static void (*s_originalHandleHIDEvent)(id, SEL, IOHIDEventRef);

// IOHIDEventSystemClient is private SPI. Resolve it dynamically so the probe
// still loads if a symbol is absent on a particular iOS build.
typedef void *(*IOHIDEventSystemClientCreateWithTypeFunc)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*IOHIDEventSystemClientScheduleWithRunLoopFunc)(void *, CFRunLoopRef, CFStringRef);
typedef void (*IOHIDEventSystemClientRegisterEventCallbackFunc)(void *, int32_t (*)(void *, void *, void *, IOHIDEventRef), void *, void *);
typedef uint32_t (*ProbeNotifyRegisterCheckFunc)(const char *, int *);
typedef uint32_t (*ProbeNotifySetStateFunc)(int, uint64_t);
typedef uint32_t (*ProbeNotifyPostFunc)(const char *);
static IOHIDEventSystemClientCreateWithTypeFunc s_createHIDClient;
static IOHIDEventSystemClientScheduleWithRunLoopFunc s_scheduleHIDClient;
static IOHIDEventSystemClientRegisterEventCallbackFunc s_registerHIDCallback;
static void *s_hidClient;
static ProbeNotifySetStateFunc s_notifySetState;
static ProbeNotifyPostFunc s_notifyPost;
static int s_notifyToken = -1;
static uint32_t s_swipeSequence;
static BOOL s_cameraControlTouchActive;
static double s_lastCameraControlX;
static double s_lastCameraControlY;
static NSInteger s_cameraControlAxis;

#define PROBE_LOG(fmt, ...) NSLog(@"[CameraControlSystemProbe] " fmt, ##__VA_ARGS__)

static void ProcessSystemHIDTree(IOHIDEventRef event, NSUInteger depth);

static double ProbeFloat(IOHIDEventRef event, IOHIDEventField field) {
    if (s_getFloat) return s_getFloat(event, field);
    if (s_getInteger) return (double)s_getInteger(event, field);
    return 0.0;
}

static void LogHIDTree(IOHIDEventRef event, NSUInteger depth) {
    if (!event || depth > 8 || !s_getType) return;

    IOHIDEventType type = s_getType(event);
    CFArrayRef children = s_getChildren ? s_getChildren(event) : NULL;
    CFIndex childCount = children ? CFArrayGetCount(children) : 0;
    PROBE_LOG("HID event depth=%lu type=%u children=%ld pointer=%p",
              (unsigned long)depth, type, (long)childCount, event);

    if (type == kProbeHIDEventTypeDigitizer) {
        int32_t touch = s_getInteger ? s_getInteger(event, kProbeDigitizerTouch) : -1;
        int32_t display = s_getInteger ? s_getInteger(event, kProbeDigitizerDisplayIntegrated) : -1;
        int32_t mask = s_getInteger ? s_getInteger(event, kProbeDigitizerEventMask) : -1;
        PROBE_LOG("DIGITIZER depth=%lu touch=%d displayIntegrated=%d mask=0x%x x=%.6f y=%.6f",
                  (unsigned long)depth, touch, display, (unsigned int)mask,
                  ProbeFloat(event, kProbeDigitizerX), ProbeFloat(event, kProbeDigitizerY));
    } else if (type == kProbeHIDEventTypeVendorDefined) {
        int32_t page = s_getInteger ? s_getInteger(event, kProbeVendorUsagePage) : -1;
        int32_t usage = s_getInteger ? s_getInteger(event, kProbeVendorUsage) : -1;
        int32_t length = s_getInteger ? s_getInteger(event, kProbeVendorDataLength) : -1;
        PROBE_LOG("VENDOR depth=%lu page=0x%x usage=0x%x dataLength=%d",
                  (unsigned long)depth, (unsigned int)page, (unsigned int)usage, length);
    }

    for (CFIndex index = 0; index < childCount; ++index) {
        LogHIDTree((IOHIDEventRef)CFArrayGetValueAtIndex(children, index), depth + 1);
    }
}

static int32_t ProbeSystemHIDEvent(void *target, void *context, void *sender, IOHIDEventRef event) {
    if (!event) return 0;
    PROBE_LOG("IOHIDEventSystemClient callback sender=%p event=%p", sender, event);
    LogHIDTree(event, 0);
    ProcessSystemHIDTree(event, 0);
    return 0;
}

static void RelayFeedSwipeDelta(double deltaPoints) {
    if (s_notifyToken < 0 || !s_notifySetState || !s_notifyPost || !isfinite(deltaPoints)) return;
    int32_t centipoints = (int32_t)llround(fmax(-120.0, fmin(120.0, deltaPoints)) * 100.0);
    if (!centipoints) return;
    uint32_t sequence = ++s_swipeSequence;
    if (!sequence) sequence = ++s_swipeSequence;
    uint64_t state = ((uint64_t)sequence << 32) | (uint32_t)centipoints;
    if (s_notifySetState(s_notifyToken, state) == 0) {
        s_notifyPost("com.instagramscroll.cameracontrol.feed-swipe");
    }
}

static void ProcessSystemHIDTree(IOHIDEventRef event, NSUInteger depth) {
    if (!event || depth > 8 || !s_getType) return;
    CFArrayRef children = s_getChildren ? s_getChildren(event) : NULL;
    CFIndex count = children ? CFArrayGetCount(children) : 0;

    if (s_getType(event) == kProbeHIDEventTypeDigitizer && count == 0 && s_getInteger) {
        int32_t displayIntegrated = s_getInteger(event, kProbeDigitizerDisplayIntegrated);
        int32_t touch = s_getInteger(event, kProbeDigitizerTouch);
        if (displayIntegrated) {
            s_cameraControlTouchActive = NO;
            s_cameraControlAxis = 0;
        } else if (!touch) {
            s_cameraControlTouchActive = NO;
            s_cameraControlAxis = 0;
        } else {
            double x = s_getFloat ? s_getFloat(event, kProbeDigitizerX)
                                  : (double)s_getInteger(event, kProbeDigitizerX);
            double y = s_getFloat ? s_getFloat(event, kProbeDigitizerY)
                                  : (double)s_getInteger(event, kProbeDigitizerY);
            if (isfinite(x) && isfinite(y)) {
                if (!s_cameraControlTouchActive) {
                    s_cameraControlTouchActive = YES;
                    s_lastCameraControlX = x;
                    s_lastCameraControlY = y;
                    s_cameraControlAxis = 0;
                } else {
                    double dx = x - s_lastCameraControlX;
                    double dy = y - s_lastCameraControlY;
                    s_lastCameraControlX = x;
                    s_lastCameraControlY = y;
                    if (!s_cameraControlAxis && (fabs(dx) > 0.0001 || fabs(dy) > 0.0001))
                        s_cameraControlAxis = fabs(dx) > fabs(dy) ? 1 : 2;
                    double delta = s_cameraControlAxis == 1 ? dx : dy;
                    if (s_cameraControlAxis && fabs(delta) > 0.00001) {
                        double scale = fmax(fabs(x), fabs(y)) <= 1.5
                            ? UIScreen.mainScreen.bounds.size.height : 15.0;
                        RelayFeedSwipeDelta(delta * scale);
                    }
                }
            }
        }
    }

    for (CFIndex index = 0; index < count; ++index)
        ProcessSystemHIDTree((IOHIDEventRef)CFArrayGetValueAtIndex(children, index), depth + 1);
}

static void InstallSystemHIDMonitor(void) {
    if (!s_iokitHandle) s_iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    s_createHIDClient = (IOHIDEventSystemClientCreateWithTypeFunc)dlsym(s_iokitHandle ?: RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    s_scheduleHIDClient = (IOHIDEventSystemClientScheduleWithRunLoopFunc)dlsym(s_iokitHandle ?: RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    s_registerHIDCallback = (IOHIDEventSystemClientRegisterEventCallbackFunc)dlsym(s_iokitHandle ?: RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
    PROBE_LOG("System HID monitor symbols create=%d schedule=%d register=%d",
              s_createHIDClient != NULL, s_scheduleHIDClient != NULL, s_registerHIDCallback != NULL);

    if (!s_createHIDClient || !s_scheduleHIDClient || !s_registerHIDCallback) {
        PROBE_LOG("System HID monitor unavailable: required private SPI symbol missing");
        return;
    }

    ProbeNotifyRegisterCheckFunc registerCheck =
        (ProbeNotifyRegisterCheckFunc)dlsym(RTLD_DEFAULT, "notify_register_check");
    s_notifySetState = (ProbeNotifySetStateFunc)dlsym(RTLD_DEFAULT, "notify_set_state");
    s_notifyPost = (ProbeNotifyPostFunc)dlsym(RTLD_DEFAULT, "notify_post");
    if (registerCheck && s_notifySetState && s_notifyPost) {
        uint32_t status = registerCheck("com.instagramscroll.cameracontrol.feed-swipe", &s_notifyToken);
        PROBE_LOG("Feed swipe relay token status=%u token=%d", status, s_notifyToken);
        if (status != 0) s_notifyToken = -1;
    } else {
        PROBE_LOG("Feed swipe relay unavailable: Darwin notify symbols missing");
    }

    // Apple defines Monitor as the second client type (Admin is first).
    // This is observational; we never dispatch or filter system input.
    const int kIOHIDEventSystemClientTypeMonitorValue = 1;
    s_hidClient = s_createHIDClient(kCFAllocatorDefault, kIOHIDEventSystemClientTypeMonitorValue, NULL);
    if (!s_hidClient) {
        PROBE_LOG("System HID monitor client creation failed (permission or unsupported client type)");
        return;
    }

    s_scheduleHIDClient(s_hidClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    s_registerHIDCallback(s_hidClient, ProbeSystemHIDEvent, NULL, NULL);
    PROBE_LOG("Registered passive IOHIDEventSystemClient monitor client=%p", s_hidClient);
}

static void ProbeHandleHIDEvent(id self, SEL selector, IOHIDEventRef event) {
    if (event) {
        IOHIDEventType type = s_getType ? s_getType(event) : UINT32_MAX;
        PROBE_LOG("SpringBoard UIApplication received HID event=%p type=%u", event, type);
        LogHIDTree(event, 0);
    }

    if (s_originalHandleHIDEvent) {
        s_originalHandleHIDEvent(self, selector, event);
    }
}

__attribute__((constructor))
static void CameraControlSystemProbeInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        PROBE_LOG("Loaded in process=%@ pid=%d", bundleID, getpid());
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

        s_iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        void *symbolHandle = s_iokitHandle ?: RTLD_DEFAULT;
        PROBE_LOG("IOKit framework handle=%p", s_iokitHandle);
        s_getType = (IOHIDEventGetTypeFunc)dlsym(symbolHandle, "IOHIDEventGetType");
        s_getInteger = (IOHIDEventGetIntegerValueFunc)dlsym(symbolHandle, "IOHIDEventGetIntegerValue");
        s_getFloat = (IOHIDEventGetFloatValueFunc)dlsym(symbolHandle, "IOHIDEventGetFloatValue");
        s_getChildren = (IOHIDEventGetChildrenFunc)dlsym(symbolHandle, "IOHIDEventGetChildren");
        PROBE_LOG("IOHID symbol availability type=%d integer=%d float=%d children=%d",
                  s_getType != NULL, s_getInteger != NULL, s_getFloat != NULL, s_getChildren != NULL);

        InstallSystemHIDMonitor();

        SEL selector = sel_registerName("_handleHIDEvent:");
        Method method = class_getInstanceMethod(UIApplication.class, selector);
        if (!method) {
            PROBE_LOG("UIApplication -_handleHIDEvent: unavailable in SpringBoard");
            return;
        }

        IMP current = method_getImplementation(method);
        if (current == (IMP)ProbeHandleHIDEvent) return;
        s_originalHandleHIDEvent = (void (*)(id, SEL, IOHIDEventRef))current;
        method_setImplementation(method, (IMP)ProbeHandleHIDEvent);
        PROBE_LOG("Installed observational hook on UIApplication -_handleHIDEvent:");
    }
}
