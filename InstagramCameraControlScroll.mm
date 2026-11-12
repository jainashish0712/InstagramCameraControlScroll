//
//  InstagramCameraControlScroll.mm
//  InstagramCameraControlScroll
//
//  Hardware Camera Control (iPhone 16 Pro / iOS 18+) Scroll Engine for Instagram
//  Repurposes the capacitive swipe strip and multi-stage pressure sensor for:
//  - Light Press (Half-press): Page down / Next Reel
//  - Double Light Press: Page up / Previous Reel
//  - Swipe / Slide: Tactile continuous scrolling or swipe-between-reels
//  - Hard Click: Scroll to top of feed / Quick action
//

#import "InstagramCameraControlScroll.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <atomic>
#import <cmath>

#define CC_LOG(fmt, ...) NSLog(@"[InstagramCameraControlScroll] " fmt, ##__VA_ARGS__)

// ============================================================================
// Low-Level IOHIDEvent Definitions & Dynamic Resolvers
// ============================================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDEventField;

// IOHID Event Types
static const IOHIDEventType kIOHIDEventTypeVendorDefined = 1;
static const IOHIDEventType kIOHIDEventTypeKeyboard      = 3;
static const IOHIDEventType kIOHIDEventTypeScroll        = 6;
static const IOHIDEventType kIOHIDEventTypeDigitizer     = 11;
static const IOHIDEventType kIOHIDEventTypeForce         = 32;

// Digitizer fields (event type 11 << 16 | field offset).
static const IOHIDEventField kIOHIDEventFieldDigitizerX = 0x000B0000;
static const IOHIDEventField kIOHIDEventFieldDigitizerY = 0x000B0001;
static const IOHIDEventField kIOHIDEventFieldDigitizerEventMask = 0x000B0007;
static const IOHIDEventField kIOHIDEventFieldDigitizerTouch = 0x000B0009;
static const IOHIDEventField kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x000B0019;
static const IOHIDEventField kIOHIDEventFieldScrollX = 0x00060000;
static const IOHIDEventField kIOHIDEventFieldScrollY = 0x00060001;
static const IOHIDEventField kIOHIDEventFieldVendorDefinedUsagePage = 0x00010000;
static const IOHIDEventField kIOHIDEventFieldVendorDefinedUsage = 0x00010001;
static const IOHIDEventField kIOHIDEventFieldVendorDefinedDataLength = 0x00010003;

// HID Usage Pages
static const uint32_t kHIDPage_GenericDesktop            = 0x01;
static const uint32_t kHIDPage_Consumer                  = 0x0C;
static const uint32_t kHIDPage_Digitizer                 = 0x0D;
static const uint32_t kHIDPage_CameraControl             = 0x90; // USB-IF Camera Control Page

// Camera Control (Page 0x90) Usages
static const uint32_t kHIDUsage_CC_Autofocus             = 0x20; // Light-press / Half-press
static const uint32_t kHIDUsage_CC_Shutter               = 0x21; // Full click / Mechanical shutter

// Consumer Page (0x0C) Usages
static const uint32_t kHIDUsage_Csmr_CameraShutter       = 0x20E;
static const uint32_t kHIDUsage_Csmr_CameraAutofocus     = 0x20F;

// Function pointers dynamically resolved at runtime
typedef IOHIDEventType (*IOHIDEventGetTypeFunc)(IOHIDEventRef event);
typedef int32_t (*IOHIDEventGetIntegerValueFunc)(IOHIDEventRef event, IOHIDEventField field);
typedef double (*IOHIDEventGetFloatValueFunc)(IOHIDEventRef event, IOHIDEventField field);
typedef CFArrayRef (*IOHIDEventGetChildrenFunc)(IOHIDEventRef event);

static IOHIDEventGetTypeFunc s_IOHIDEventGetType = NULL;
static IOHIDEventGetIntegerValueFunc s_IOHIDEventGetIntegerValue = NULL;
static IOHIDEventGetFloatValueFunc s_IOHIDEventGetFloatValue = NULL;
static IOHIDEventGetChildrenFunc s_IOHIDEventGetChildren = NULL;

static void ResolveIOHIDSymbolsOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_IOHIDEventGetType = (IOHIDEventGetTypeFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        s_IOHIDEventGetIntegerValue = (IOHIDEventGetIntegerValueFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        s_IOHIDEventGetFloatValue = (IOHIDEventGetFloatValueFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
        s_IOHIDEventGetChildren = (IOHIDEventGetChildrenFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
        
        CC_LOG("Resolved IOHID symbols: GetType=%p, GetInt=%p, GetFloat=%p, GetChildren=%p",
               s_IOHIDEventGetType, s_IOHIDEventGetIntegerValue, s_IOHIDEventGetFloatValue, s_IOHIDEventGetChildren);
    });
}

// ============================================================================
// State Management & Atomic Configuration
// ============================================================================

static std::atomic<bool> s_enabled{true};
static std::atomic<bool> s_invertDirection{false};
static std::atomic<bool> s_hapticsEnabled{true};
static std::atomic<float> s_sensitivity{1.0f};

// Telemetry
static std::atomic<NSUInteger> s_swipeCount{0};
static std::atomic<NSUInteger> s_lightPressCount{0};
static std::atomic<NSUInteger> s_clickCount{0};

// Debounce & timing tracking (Main Thread only)
static NSTimeInterval s_lastLightPressTime = 0.0;
static NSTimeInterval s_lastClickTime = 0.0;
static NSTimeInterval s_lastPageScrollTime = 0.0;
static const NSTimeInterval kMinPageInterval = 0.28; // Cooldown between reel snaps
static const NSTimeInterval kDoublePressWindow = 0.38; // Double-press detection window

// Capacitive Swipe Accumulator
static CGFloat s_accumulatedSwipeDelta = 0.0;
static const CGFloat kSwipeSnapThreshold = 35.0; // Point delta required to trigger reel flip
static std::atomic<uint64_t> s_loggedHIDEventTypes{0};

// Candidate non-display digitizer state. iOS does not document raw Camera
// Control swipe delivery through UIApplication; these values are diagnostic
// candidates only until the event source is confirmed on-device.
static BOOL s_cameraControlTouchActive = NO;
static CGFloat s_lastCameraControlX = 0.0;
static CGFloat s_lastCameraControlY = 0.0;
static NSInteger s_cameraControlSwipeAxis = 0; // 0 = undecided, 1 = X, 2 = Y
static std::atomic<bool> s_cameraControlPageFlipTriggered{false};

// ============================================================================
// Haptic Feedback Generator
// ============================================================================

static void PlayHapticFeedback(UIImpactFeedbackStyle style) {
    if (!s_hapticsEnabled.load()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        [generator prepare];
        [generator impactOccurred];
    });
}

// ============================================================================
// Viewport & Active ScrollView Discovery Engine
// ============================================================================

static UIWindow *GetActiveKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    
    // 1. Scene-based window lookup (iOS 13+)
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *win in windowScene.windows) {
                if (win.isKeyWindow && !win.hidden && win.alpha > 0.01f) {
                    return win;
                }
            }
            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }
    
    // 2. Legacy keyWindow fallback
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow && !app.keyWindow.hidden && app.keyWindow.alpha > 0.01f) {
        return app.keyWindow;
    }
    if (app.windows.count > 0) {
        return app.windows.firstObject;
    }
#pragma clang diagnostic pop
    
    return nil;
}

static UIViewController *GetTopViewController(UIViewController *root) {
    if (!root) return nil;
    
    if (root.presentedViewController && !root.presentedViewController.isBeingDismissed) {
        return GetTopViewController(root.presentedViewController);
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        return GetTopViewController(((UINavigationController *)root).visibleViewController);
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return GetTopViewController(((UITabBarController *)root).selectedViewController);
    }
    return root;
}

static UIScrollView *FindActiveScrollViewRecursive(UIView *view, CGFloat minHeight) {
    if (!view || view.hidden || view.alpha < 0.01f) return nil;
    
    // If view itself is a UIScrollView and is enabled
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (sv.isScrollEnabled && sv.bounds.size.height >= minHeight) {
            // Prioritize Reels vertical pagers or primary vertical scrollviews
            if (sv.isPagingEnabled || sv.contentSize.height > sv.bounds.size.height) {
                CGRect windowRect = [sv convertRect:sv.bounds toView:nil];
                CGRect screenBounds = [UIScreen mainScreen].bounds;
                if (CGRectIntersectsRect(windowRect, screenBounds) && windowRect.size.height >= minHeight) {
                    return sv;
                }
            }
        }
    }
    
    // Traverse subviews in reverse order (topmost subview first)
    for (UIView *subview in [view.subviews reverseObjectEnumerator]) {
        UIScrollView *candidate = FindActiveScrollViewRecursive(subview, minHeight);
        if (candidate) return candidate;
    }
    
    return nil;
}

static UIScrollView *GetActiveScrollView(void) {
    UIWindow *window = GetActiveKeyWindow();
    if (!window) return nil;
    
    UIViewController *topVC = GetTopViewController(window.rootViewController);
    if (!topVC) return nil;
    
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat minH = screenH * 0.40f; // Only pick main viewport containers
    
    // 1. Search top view controller's view hierarchy
    UIScrollView *sv = FindActiveScrollViewRecursive(topVC.view, minH);
    if (sv) return sv;
    
    // 2. Search entire window hierarchy if not found in topVC
    return FindActiveScrollViewRecursive(window, minH);
}

// ============================================================================
// Core Scrolling Actions
// ============================================================================

typedef NS_ENUM(NSInteger, CCScrollDirection) {
    CCScrollDirectionNext = 1,
    CCScrollDirectionPrevious = -1
};

static BOOL PerformPageScroll(CCScrollDirection direction) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) {
        CC_LOG("PerformPageScroll: No active visible UIScrollView found in hierarchy");
        return NO;
    }
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - s_lastPageScrollTime < kMinPageInterval) {
        return NO; // Debounce rapid consecutive triggers
    }
    s_lastPageScrollTime = now;
    
    CGFloat viewportH = sv.bounds.size.height;
    if (viewportH <= 0.0f) return NO;
    
    BOOL isPaging = sv.isPagingEnabled;
    const char *className = class_getName(object_getClass(sv.delegate ?: sv));
    if (className && (strstr(className, "Clips") || strstr(className, "Reel"))) {
        isPaging = YES;
    }
    
    CGPoint currentOffset = sv.contentOffset;
    CGFloat targetY = currentOffset.y;
    
    if (isPaging) {
        // Discrete page snap (Reels / Stories)
        if (direction == CCScrollDirectionNext) {
            targetY = (floorf(currentOffset.y / viewportH) + 1.0f) * viewportH;
        } else {
            targetY = (ceilf(currentOffset.y / viewportH) - 1.0f) * viewportH;
        }
    } else {
        // Continuous Feed / Explore page advance (75% screen height)
        CGFloat step = viewportH * 0.75f;
        if (direction == CCScrollDirectionNext) {
            targetY = currentOffset.y + step;
        } else {
            targetY = currentOffset.y - step;
        }
    }
    
    // Clamp to valid content boundaries
    CGFloat minY = -sv.contentInset.top;
    CGFloat maxY = fmaxf(minY, sv.contentSize.height - viewportH + sv.contentInset.bottom);
    targetY = fmaxf(minY, fminf(targetY, maxY));
    
    if (fabs(targetY - currentOffset.y) > 0.5f) {
        [sv setContentOffset:CGPointMake(currentOffset.x, targetY) animated:YES];
        PlayHapticFeedback(UIImpactFeedbackStyleMedium);
        CC_LOG("Page Scroll executed: direction=%ld, isPaging=%d, targetY=%.1f", (long)direction, isPaging, targetY);
        return YES;
    }
    
    return NO;
}

static BOOL PerformContinuousDeltaScroll(CGFloat deltaY, BOOL isDigitizerSwipe) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) return NO;
    
    CGFloat viewportH = sv.bounds.size.height;
    if (viewportH <= 0.0f) return NO;
    
    BOOL isPaging = sv.isPagingEnabled;
    const char *className = class_getName(object_getClass(sv.delegate ?: sv));
    if (className && (strstr(className, "Clips") || strstr(className, "Reel"))) {
        isPaging = YES;
    }
    
    if (isPaging) {
        // In paging mode (Reels), accumulate swipe delta to trigger crisp page flips
        if (isDigitizerSwipe && s_cameraControlPageFlipTriggered.load()) return YES;
        s_accumulatedSwipeDelta += deltaY;
        CGFloat snapThreshold = isDigitizerSwipe ? viewportH * 0.18f : kSwipeSnapThreshold;
        if (s_accumulatedSwipeDelta >= snapThreshold) {
            s_accumulatedSwipeDelta = 0.0;
            BOOL didScroll = PerformPageScroll(CCScrollDirectionNext);
            if (isDigitizerSwipe && didScroll) s_cameraControlPageFlipTriggered.store(true);
            return didScroll;
        } else if (s_accumulatedSwipeDelta <= -snapThreshold) {
            s_accumulatedSwipeDelta = 0.0;
            BOOL didScroll = PerformPageScroll(CCScrollDirectionPrevious);
            if (isDigitizerSwipe && didScroll) s_cameraControlPageFlipTriggered.store(true);
            return didScroll;
        }
        return YES;
    }
    
    // In continuous mode (Main Feed), apply smooth proportional offset
    CGPoint offset = sv.contentOffset;
    CGFloat scaledDelta = deltaY * s_sensitivity.load();
    CGFloat newY = offset.y + scaledDelta;
    
    CGFloat minY = -sv.contentInset.top;
    CGFloat maxY = fmaxf(minY, sv.contentSize.height - viewportH + sv.contentInset.bottom);
    newY = fmaxf(minY, fminf(newY, maxY));
    
    [sv setContentOffset:CGPointMake(offset.x, newY) animated:NO];
    return YES;
}

static BOOL PerformScrollToTop(void) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) return NO;
    
    CGPoint topOffset = CGPointMake(sv.contentOffset.x, -sv.contentInset.top);
    [sv setContentOffset:topOffset animated:YES];
    PlayHapticFeedback(UIImpactFeedbackStyleHeavy);
    CC_LOG("Scroll to top executed");
    return YES;
}

// ============================================================================
// Event Dispatches & Gesture Classifier
// ============================================================================

static void HandleLightPressTriggered(void) {
    if (!s_enabled.load()) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsedSinceLast = now - s_lastLightPressTime;
        s_lastLightPressTime = now;
        
        s_lightPressCount.fetch_add(1);
        
        // Detect double light-press -> Page Up / Previous Reel
        if (elapsedSinceLast > 0.05 && elapsedSinceLast < kDoublePressWindow) {
            CC_LOG("Double Light-Press detected! Scrolling to previous page/reel...");
            PerformPageScroll(s_invertDirection.load() ? CCScrollDirectionNext : CCScrollDirectionPrevious);
        } else {
            // Single light-press -> Page Down / Next Reel
            CC_LOG("Single Light-Press detected! Scrolling to next page/reel...");
            PerformPageScroll(s_invertDirection.load() ? CCScrollDirectionPrevious : CCScrollDirectionNext);
        }
    });
}

static void HandleHardClickTriggered(void) {
    if (!s_enabled.load()) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - s_lastClickTime < 0.35) return;
        s_lastClickTime = now;
        
        s_clickCount.fetch_add(1);
        CC_LOG("Hard Click detected! Scrolling to top of feed...");
        PerformScrollToTop();
    });
}

static void HandleSwipeDeltaTriggered(CGFloat deltaY) {
    if (!s_enabled.load()) return;
    
    s_swipeCount.fetch_add(1);
    CGFloat effectiveDelta = s_invertDirection.load() ? -deltaY : deltaY;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        PerformContinuousDeltaScroll(effectiveDelta, NO);
    });
}

static void HandleDigitizerSwipeDeltaTriggered(CGFloat deltaY) {
    if (!s_enabled.load()) return;

    s_swipeCount.fetch_add(1);
    CGFloat effectiveDelta = s_invertDirection.load() ? -deltaY : deltaY;
    dispatch_async(dispatch_get_main_queue(), ^{
        PerformContinuousDeltaScroll(effectiveDelta, YES);
    });
}

// ============================================================================
// Low-Level Hook: -[UIApplication _handleHIDEvent:]
// ============================================================================

static void (*orig__handleHIDEvent)(id self, SEL _cmd, IOHIDEventRef event) = NULL;

static double ReadHIDFloatField(IOHIDEventRef event, IOHIDEventField field) {
    if (s_IOHIDEventGetFloatValue) {
        return s_IOHIDEventGetFloatValue(event, field);
    }
    if (s_IOHIDEventGetIntegerValue) {
        return (double)s_IOHIDEventGetIntegerValue(event, field);
    }
    return 0.0;
}

static void ProcessCameraControlDigitizer(IOHIDEventRef event) {
    if (!s_IOHIDEventGetIntegerValue && !s_IOHIDEventGetFloatValue) return;

    // Ignore touchscreen digitizers. Camera Control is a separate, non-display
    // touch surface; using this field also avoids turning ordinary screen drags
    // into duplicate scroll input.
    int32_t displayIntegrated = s_IOHIDEventGetIntegerValue
        ? s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated)
        : 0;
    int32_t touch = s_IOHIDEventGetIntegerValue
        ? s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerTouch)
        : (int32_t)(ReadHIDFloatField(event, kIOHIDEventFieldDigitizerTouch) != 0.0);

    if (displayIntegrated) {
        CC_LOG("HID DIGITIZER ignored: display-integrated touch");
        return;
    }
    if (!touch) {
        if (s_cameraControlTouchActive) {
            CC_LOG("HID DIGITIZER candidate touch ended; clearing swipe state");
        }
        s_cameraControlTouchActive = NO;
        s_cameraControlSwipeAxis = 0;
        s_cameraControlPageFlipTriggered.store(false);
        return;
    }

    CGFloat x = (CGFloat)ReadHIDFloatField(event, kIOHIDEventFieldDigitizerX);
    CGFloat y = (CGFloat)ReadHIDFloatField(event, kIOHIDEventFieldDigitizerY);
    if (!std::isfinite((double)x) || !std::isfinite((double)y)) return;

    if (!s_cameraControlTouchActive) {
        s_cameraControlTouchActive = YES;
        s_lastCameraControlX = x;
        s_lastCameraControlY = y;
        s_cameraControlSwipeAxis = 0;
        s_cameraControlPageFlipTriggered.store(false);
        CC_LOG("HID DIGITIZER candidate began (non-display; source unclassified) x=%.5f y=%.5f",
               (double)x, (double)y);
        return;
    }

    CGFloat deltaX = x - s_lastCameraControlX;
    CGFloat deltaY = y - s_lastCameraControlY;
    s_lastCameraControlX = x;
    s_lastCameraControlY = y;

    if (s_cameraControlSwipeAxis == 0) {
        if (fabs(deltaX) < 0.0001 && fabs(deltaY) < 0.0001) return;
        s_cameraControlSwipeAxis = fabs(deltaX) > fabs(deltaY) ? 1 : 2;
        CC_LOG("HID DIGITIZER candidate movement axis=%ld (source unclassified)",
               (long)s_cameraControlSwipeAxis);
    }

    CGFloat delta = s_cameraControlSwipeAxis == 1 ? deltaX : deltaY;
    if (fabs(delta) < 0.00001) return;

    // HID digitizer positions may be normalized (0...1) or reported in device
    // units. Convert either representation into screen-like scroll distance.
    CGFloat coordinateMagnitude = fmaxf(fmaxf(fabsf(x), fabsf(y)),
                                        fmaxf(fabsf(s_lastCameraControlX), fabsf(s_lastCameraControlY)));
    CGFloat scrollDelta = coordinateMagnitude <= 1.5f
        ? delta * [UIScreen mainScreen].bounds.size.height
        : delta * 15.0f;
    CGFloat maxDelta = [UIScreen mainScreen].bounds.size.height * 0.12f;
    scrollDelta = fmaxf(-maxDelta, fminf(scrollDelta, maxDelta));
    CC_LOG("HID DIGITIZER candidate sample rawDelta=(%.5f,%.5f) scrollDelta=%.2f",
           (double)deltaX, (double)deltaY, (double)scrollDelta);
    HandleDigitizerSwipeDeltaTriggered(scrollDelta);
}

static void ProcessHIDEvent(IOHIDEventRef event, NSUInteger depth) {
    // UIKit may deliver a compound HID event whose useful scroll or button
    // event is nested several levels below the root event.
    if (!event || depth > 8 || !s_IOHIDEventGetType) return;

    IOHIDEventType eventType = s_IOHIDEventGetType(event);
    if (eventType < 64) {
        uint64_t typeBit = (uint64_t)1 << eventType;
        uint64_t loggedTypes = s_loggedHIDEventTypes.fetch_or(typeBit);
        if ((loggedTypes & typeBit) == 0) {
            CC_LOG("First HID event observed by app hook: type=%u", eventType);
        }
    }

    CFArrayRef children = s_IOHIDEventGetChildren ? s_IOHIDEventGetChildren(event) : NULL;
    BOOL hasChildren = children && CFArrayGetCount(children) > 0;

    if (eventType == kIOHIDEventTypeDigitizer) {
        int32_t displayIntegrated = s_IOHIDEventGetIntegerValue
            ? s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated)
            : -1;
        int32_t touch = s_IOHIDEventGetIntegerValue
            ? s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerTouch)
            : -1;
        int32_t eventMask = s_IOHIDEventGetIntegerValue
            ? s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerEventMask)
            : -1;
        double x = ReadHIDFloatField(event, kIOHIDEventFieldDigitizerX);
        double y = ReadHIDFloatField(event, kIOHIDEventFieldDigitizerY);
        CC_LOG("HID DIGITIZER event depth=%lu touch=%d displayIntegrated=%d eventMask=0x%x x=%.5f y=%.5f children=%d source=unclassified",
               (unsigned long)depth, touch, displayIntegrated, (unsigned int)eventMask, x, y, hasChildren);
    } else if (eventType == kIOHIDEventTypeVendorDefined && s_IOHIDEventGetIntegerValue) {
        uint32_t usagePage = (uint32_t)s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldVendorDefinedUsagePage);
        uint32_t usage = (uint32_t)s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldVendorDefinedUsage);
        uint32_t dataLength = (uint32_t)s_IOHIDEventGetIntegerValue(event, kIOHIDEventFieldVendorDefinedDataLength);
        CC_LOG("HID VENDOR event depth=%lu page=0x%04x usage=0x%04x dataLength=%u children=%d",
               (unsigned long)depth, usagePage, usage, dataLength, hasChildren);
    }

    if (eventType == kIOHIDEventTypeDigitizer && !hasChildren) {
        ProcessCameraControlDigitizer(event);
    } else if (eventType == kIOHIDEventTypeScroll &&
        (s_IOHIDEventGetFloatValue || s_IOHIDEventGetIntegerValue)) {
        double deltaX = ReadHIDFloatField(event, kIOHIDEventFieldScrollX);
        double deltaY = ReadHIDFloatField(event, kIOHIDEventFieldScrollY);
        CC_LOG("HID SCROLL event depth=%lu deltaX=%.5f deltaY=%.5f",
               (unsigned long)depth, deltaX, deltaY);
        // Camera Control is a one-axis surface; some firmware reports it as X.
        if (fabs(deltaY) <= 0.01) deltaY = deltaX;
        if (fabs(deltaY) > 0.01) {
            HandleSwipeDeltaTriggered((CGFloat)(deltaY * 15.0));
        }
    } else if (eventType == kIOHIDEventTypeKeyboard && s_IOHIDEventGetIntegerValue) {
        uint32_t usagePage = (uint32_t)s_IOHIDEventGetIntegerValue(event, 0x00030000);
        uint32_t usage     = (uint32_t)s_IOHIDEventGetIntegerValue(event, 0x00030001);
        int32_t isDown     = s_IOHIDEventGetIntegerValue(event, 0x00030002);

        if (isDown) {
            if (usagePage == kHIDPage_CameraControl) {
                if (usage == kHIDUsage_CC_Autofocus) {
                    CC_LOG("IOHIDEvent: Camera Control Autofocus (Light-Press) detected!");
                    HandleLightPressTriggered();
                } else if (usage == kHIDUsage_CC_Shutter) {
                    CC_LOG("IOHIDEvent: Camera Control Shutter (Hard Click) detected!");
                    HandleHardClickTriggered();
                }
            } else if (usagePage == kHIDPage_Consumer) {
                if (usage == kHIDUsage_Csmr_CameraAutofocus) {
                    HandleLightPressTriggered();
                } else if (usage == kHIDUsage_Csmr_CameraShutter) {
                    HandleHardClickTriggered();
                }
            }
        }
    }

    if (hasChildren) {
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex i = 0; i < count; ++i) {
            IOHIDEventRef child = (IOHIDEventRef)CFArrayGetValueAtIndex(children, i);
            ProcessHIDEvent(child, depth + 1);
        }
    }
}

static void Hook__handleHIDEvent(id self, SEL _cmd, IOHIDEventRef event) {
    // Observe before forwarding: the original handler may consume or transform
    // the event. Keep diagnostics active while scrolling is disabled; the
    // action handlers independently enforce s_enabled.
    if (event) {
        IOHIDEventType eventType = s_IOHIDEventGetType ? s_IOHIDEventGetType(event) : UINT32_MAX;
        CC_LOG("UIApplication HID hook received event=%p type=%u enabled=%d",
               event, eventType, s_enabled.load());
        ProcessHIDEvent(event, 0);
    }

    if (orig__handleHIDEvent) {
        orig__handleHIDEvent(self, _cmd, event);
    }
}

static void InstallHIDHook(void) {
    ResolveIOHIDSymbolsOnce();
    
    Class appClass = [UIApplication class];
    SEL sel = sel_registerName("_handleHIDEvent:");
    Method m = class_getInstanceMethod(appClass, sel);
    if (m) {
        orig__handleHIDEvent = (void (*)(id, SEL, IOHIDEventRef))method_getImplementation(m);
        method_setImplementation(m, (IMP)Hook__handleHIDEvent);
        CC_LOG("Successfully hooked -[UIApplication _handleHIDEvent:]");
    } else {
        CC_LOG("Warning: -[UIApplication _handleHIDEvent:] not found on UIApplication");
    }
}

// ============================================================================
// AVKit AVCaptureEventInteraction Setup (iOS 17.2+ / iOS 18+)
// ============================================================================

static void AttachCaptureEventInteractionToWindow(UIWindow *window) {
    if (!window) return;
    
    Class interactionClass = NSClassFromString(@"AVCaptureEventInteraction");
    if (!interactionClass) return;
    
    // Check if interaction already attached
    for (id<UIInteraction> interaction in window.interactions) {
        if ([interaction isKindOfClass:interactionClass]) {
            return;
        }
    }
    
    @try {
        SEL primarySel = sel_registerName("initWithPrimaryEventHandler:secondaryEventHandler:");
        if ([interactionClass instancesRespondToSelector:primarySel]) {
            id interaction = [interactionClass alloc];
            
            void (^primaryHandler)(id) = ^(id event) {
                NSInteger phase = 0;
                if ([event respondsToSelector:@selector(phase)]) {
                    phase = ((NSInteger (*)(id, SEL))objc_msgSend)(event, @selector(phase));
                }
                if (phase == 0) { // AVCaptureEventPhaseBegan
                    HandleHardClickTriggered();
                }
            };
            
            void (^secondaryHandler)(id) = ^(id event) {
                NSInteger phase = 0;
                if ([event respondsToSelector:@selector(phase)]) {
                    phase = ((NSInteger (*)(id, SEL))objc_msgSend)(event, @selector(phase));
                }
                if (phase == 0) { // AVCaptureEventPhaseBegan
                    HandleLightPressTriggered();
                }
            };
            
            interaction = ((id (*)(id, SEL, id, id))objc_msgSend)(interaction, primarySel, primaryHandler, secondaryHandler);
            if (interaction) {
                [window addInteraction:interaction];
                CC_LOG("Attached dual-handler AVCaptureEventInteraction to window: %p", window);
                return;
            }
        }
        
        // Single handler fallback
        SEL singleSel = sel_registerName("initWithEventHandler:");
        if ([interactionClass instancesRespondToSelector:singleSel]) {
            id interaction = [interactionClass alloc];
            void (^handler)(id) = ^(id event) {
                NSInteger phase = 0;
                if ([event respondsToSelector:@selector(phase)]) {
                    phase = ((NSInteger (*)(id, SEL))objc_msgSend)(event, @selector(phase));
                }
                if (phase == 0) {
                    HandleLightPressTriggered();
                }
            };
            interaction = ((id (*)(id, SEL, id))objc_msgSend)(interaction, singleSel, handler);
            if (interaction) {
                [window addInteraction:interaction];
                CC_LOG("Attached single-handler AVCaptureEventInteraction to window: %p", window);
            }
        }
    } @catch (NSException *e) {
        CC_LOG("Exception attaching AVCaptureEventInteraction: %@", e);
    }
}

// ============================================================================
// Public C API Implementation
// ============================================================================

void InstagramCameraControlScroll_SetEnabled(BOOL enabled) {
    s_enabled.store(enabled);
    CC_LOG("CameraControlScroll Enabled set to: %d", enabled);
}

BOOL InstagramCameraControlScroll_IsEnabled(void) {
    return s_enabled.load();
}

void InstagramCameraControlScroll_SetSensitivity(CGFloat sensitivity) {
    sensitivity = fmaxf(0.2f, fminf(3.0f, (float)sensitivity));
    s_sensitivity.store((float)sensitivity);
}

CGFloat InstagramCameraControlScroll_GetSensitivity(void) {
    return (CGFloat)s_sensitivity.load();
}

void InstagramCameraControlScroll_SetInvertDirection(BOOL inverted) {
    s_invertDirection.store(inverted);
}

BOOL InstagramCameraControlScroll_IsInvertDirection(void) {
    return s_invertDirection.load();
}

void InstagramCameraControlScroll_SetHapticsEnabled(BOOL enabled) {
    s_hapticsEnabled.store(enabled);
}

BOOL InstagramCameraControlScroll_IsHapticsEnabled(void) {
    return s_hapticsEnabled.load();
}

BOOL InstagramCameraControlScroll_ScrollNextPage(void) {
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = PerformPageScroll(CCScrollDirectionNext);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = PerformPageScroll(CCScrollDirectionNext);
        });
    }
    return success;
}

BOOL InstagramCameraControlScroll_ScrollPreviousPage(void) {
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = PerformPageScroll(CCScrollDirectionPrevious);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = PerformPageScroll(CCScrollDirectionPrevious);
        });
    }
    return success;
}

BOOL InstagramCameraControlScroll_ScrollToTop(void) {
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = PerformScrollToTop();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = PerformScrollToTop();
        });
    }
    return success;
}

NSUInteger InstagramCameraControlScroll_GetSwipeCount(void) {
    return s_swipeCount.load();
}

NSUInteger InstagramCameraControlScroll_GetLightPressCount(void) {
    return s_lightPressCount.load();
}

NSUInteger InstagramCameraControlScroll_GetClickCount(void) {
    return s_clickCount.load();
}

// ============================================================================
// Initialization & Constructor
// ============================================================================

void InstagramCameraControlScroll_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CC_LOG("=================================================");
        CC_LOG("Initializing InstagramCameraControlScroll Engine");
        CC_LOG("Target Device: iPhone 16 Pro / iOS 18+");
        CC_LOG("Repurposing Camera Control: Swipe, Light-Press & Click");
        CC_LOG("=================================================");
        
        // 1. Install Low-Level HID Hook on UIApplication
        InstallHIDHook();
        
        // 2. Observe Window Lifecycle to attach AVKit Interactions
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            UIWindow *win = (UIWindow *)note.object;
            if (win && [win isKindOfClass:[UIWindow class]]) {
                AttachCaptureEventInteractionToWindow(win);
            }
        }];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            UIWindow *win = GetActiveKeyWindow();
            if (win) {
                AttachCaptureEventInteractionToWindow(win);
            }
        }];
        
        // Attach immediately if key window is already present
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = GetActiveKeyWindow();
            if (win) {
                AttachCaptureEventInteractionToWindow(win);
            }
        });
        
        CC_LOG("InstagramCameraControlScroll initialized successfully!");
    });
}

__attribute__((constructor))
static void InstagramCameraControlScroll_Ctor(void) {
    InstagramCameraControlScroll_Init();
}
