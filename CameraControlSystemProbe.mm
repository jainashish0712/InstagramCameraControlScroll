// Temporary SpringBoard-side probe for Camera Control HID delivery.
// This observer logs events and always forwards them unchanged.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdint.h>
#import <unistd.h>

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
static void (*s_originalHandleHIDEvent)(id, SEL, IOHIDEventRef);

#define PROBE_LOG(fmt, ...) NSLog(@"[CameraControlSystemProbe] " fmt, ##__VA_ARGS__)

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

        s_getType = (IOHIDEventGetTypeFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        s_getInteger = (IOHIDEventGetIntegerValueFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        s_getFloat = (IOHIDEventGetFloatValueFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
        s_getChildren = (IOHIDEventGetChildrenFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
        PROBE_LOG("IOHID symbol availability type=%d integer=%d float=%d children=%d",
                  s_getType != NULL, s_getInteger != NULL, s_getFloat != NULL, s_getChildren != NULL);

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
