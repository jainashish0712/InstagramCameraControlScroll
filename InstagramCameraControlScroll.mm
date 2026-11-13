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
#import <AVFoundation/AVFoundation.h>
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
    // Support custom Instagram container view controllers (IGTabBarController, IGNavigationController)
    if ([root respondsToSelector:sel_registerName("selectedViewController")]) {
        UIViewController *selected = ((id (*)(id, SEL))objc_msgSend)(root, sel_registerName("selectedViewController"));
        if (selected && selected != root) {
            return GetTopViewController(selected);
        }
    }
    if ([root respondsToSelector:sel_registerName("topViewController")]) {
        UIViewController *top = ((id (*)(id, SEL))objc_msgSend)(root, sel_registerName("topViewController"));
        if (top && top != root) {
            return GetTopViewController(top);
        }
    }
    if ([root respondsToSelector:sel_registerName("visibleViewController")]) {
        UIViewController *vis = ((id (*)(id, SEL))objc_msgSend)(root, sel_registerName("visibleViewController"));
        if (vis && vis != root) {
            return GetTopViewController(vis);
        }
    }
    return root;
}

static void CollectVerticalScrollViewCandidates(UIView *view,
                                                CGRect screenBounds,
                                                CGFloat screenH,
                                                CGFloat screenW,
                                                UIScrollView *__strong *bestCandidate,
                                                CGFloat *highestScore) {
    if (!view || view.hidden || view.alpha < 0.05f) return;

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (sv.isScrollEnabled) {
            CGFloat vertRange = sv.contentSize.height - sv.bounds.size.height;
            BOOL isPagingVertical = sv.isPagingEnabled &&
                (sv.contentSize.height > sv.contentSize.width || sv.bounds.size.height >= screenH * 0.70f);

            if (vertRange > 10.0f || isPagingVertical) {
                CGRect rectInWin = [sv convertRect:sv.bounds toView:nil];
                CGRect visibleRect = CGRectIntersection(rectInWin, screenBounds);
                CGFloat visArea = visibleRect.size.width * visibleRect.size.height;

                if (visibleRect.size.height >= screenH * 0.35f && visibleRect.size.width >= screenW * 0.60f) {
                    CGFloat score = visArea;
                    if (vertRange > 0.0f) {
                        score += fminf(vertRange, 50000.0f);
                    }
                    if ([sv isKindOfClass:[UICollectionView class]] || [sv isKindOfClass:[UITableView class]]) {
                        score += 20000.0f;
                    }
                    const char *cName = object_getClassName(sv);
                    if (cName && (strstr(cName, "Feed") || strstr(cName, "Main") || strstr(cName, "Home"))) {
                        score += 50000.0f;
                    }

                    if (score > *highestScore) {
                        *highestScore = score;
                        *bestCandidate = sv;
                    }
                }
            }
        }
    }

    for (UIView *child in view.subviews) {
        CollectVerticalScrollViewCandidates(child, screenBounds, screenH, screenW, bestCandidate, highestScore);
    }
}

static UIScrollView *FindBestVerticalScrollView(void) {
    UIWindow *window = GetActiveKeyWindow();
    if (!window) return nil;

    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    // 1. Center Screen Focus Check
    // Query the exact view directly under the user's eye at the center of the screen
    CGPoint screenCenter = CGPointMake(screenW * 0.5f, screenH * 0.5f);
    UIView *centerView = [window hitTest:screenCenter withEvent:nil];

    UIView *curr = centerView;
    while (curr && curr != window) {
        if ([curr isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)curr;
            if (sv.isScrollEnabled && !sv.hidden && sv.alpha > 0.05f) {
                CGFloat vertRange = sv.contentSize.height - sv.bounds.size.height;
                // Disqualify horizontal post carousels and story trays:
                // Main feed vertical collection view has vertical range > 10
                // and contentSize.height must exceed contentSize.width.
                if (vertRange > 10.0f && sv.contentSize.height > sv.contentSize.width) {
                    CGRect rectInWin = [sv convertRect:sv.bounds toView:nil];
                    CGRect visibleRect = CGRectIntersection(rectInWin, screenBounds);
                    if (visibleRect.size.height >= screenH * 0.35f) {
                        CC_LOG("FindBestVerticalScrollView: matched center focus scrollview %p (%s), contentH=%.1f",
                               sv, object_getClassName(sv), sv.contentSize.height);
                        return sv;
                    }
                }
            }
        }
        curr = curr.superview;
    }


    // 2. Comprehensive Search across window view hierarchy
    UIScrollView *bestCandidate = nil;
    CGFloat highestScore = -1.0f;
    CollectVerticalScrollViewCandidates(window, screenBounds, screenH, screenW, &bestCandidate, &highestScore);

    if (bestCandidate) {
        CC_LOG("FindBestVerticalScrollView: selected candidate %p (%s), score=%.1f, contentH=%.1f",
               bestCandidate, object_getClassName(bestCandidate), highestScore, bestCandidate.contentSize.height);
        return bestCandidate;
    }

    return nil;
}

static UIScrollView *GetActiveScrollView(void) {
    UIScrollView *sv = FindBestVerticalScrollView();
    if (sv) return sv;

    UIWindow *window = GetActiveKeyWindow();
    if (!window) return nil;
    UIViewController *topVC = GetTopViewController(window.rootViewController);
    if (topVC && [topVC.view isKindOfClass:[UIScrollView class]]) {
        return (UIScrollView *)topVC.view;
    }
    return nil;
}

// ============================================================================
// Core Scrolling Actions
// ============================================================================

typedef NS_ENUM(NSInteger, CCScrollDirection) {
    CCScrollDirectionNext = 1,
    CCScrollDirectionPrevious = -1
};

static BOOL PerformPageScroll(CCScrollDirection direction, NSInteger steps = 1) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) {
        CC_LOG("PerformPageScroll: No active visible UIScrollView found in hierarchy");
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (steps == 1 && (now - s_lastPageScrollTime < kMinPageInterval)) {
        return NO; // Debounce rapid consecutive triggers
    }
    s_lastPageScrollTime = now;

    CGFloat viewportH = sv.bounds.size.height;
    if (viewportH <= 0.0f) return NO;

    BOOL isPaging = sv.isPagingEnabled;
    const char *className = class_getName(object_getClass((id)sv.delegate ?: (id)sv));
    if (className && (strstr(className, "Clips") || strstr(className, "Reel"))) {
        isPaging = YES;
    }

    CGPoint currentOffset = sv.contentOffset;
    CGFloat targetY = currentOffset.y;

    if (isPaging) {
        // Discrete page snap (Reels / Stories)
        if (direction == CCScrollDirectionNext) {
            targetY = (floorf(currentOffset.y / viewportH) + (CGFloat)steps) * viewportH;
        } else {
            targetY = (ceilf(currentOffset.y / viewportH) - (CGFloat)steps) * viewportH;
        }
    } else {
        // Continuous Feed / Explore page advance (75% screen height per step)
        CGFloat step = viewportH * 0.75f * (CGFloat)steps;
        if (direction == CCScrollDirectionNext) {
            targetY = currentOffset.y + step;
        } else {
            targetY = currentOffset.y - step;
        }
    }

    // Clamp to valid content boundaries using adjustedContentInset
    UIEdgeInsets insets = [sv respondsToSelector:@selector(adjustedContentInset)] ? sv.adjustedContentInset : sv.contentInset;
    CGFloat minY = -insets.top;
    CGFloat maxY = fmaxf(minY, sv.contentSize.height - viewportH + insets.bottom);
    targetY = fmaxf(minY, fminf(targetY, maxY));

    if (fabs(targetY - currentOffset.y) > 0.5f) {
        [sv setContentOffset:CGPointMake(currentOffset.x, targetY) animated:YES];
        PlayHapticFeedback(UIImpactFeedbackStyleMedium);
        CC_LOG("Page Scroll executed: direction=%ld, steps=%ld, isPaging=%d, targetY=%.1f",
               (long)direction, (long)steps, isPaging, targetY);
        return YES;
    }

    return NO;
}

static BOOL PerformContinuousDeltaScroll(CGFloat deltaY, BOOL isDigitizerSwipe) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) {
        CC_LOG("PerformContinuousDeltaScroll: No active visible vertical UIScrollView found");
        return NO;
    }

    CGFloat viewportH = sv.bounds.size.height;
    if (viewportH <= 0.0f) return NO;

    BOOL isPaging = sv.isPagingEnabled;
    const char *className = class_getName(object_getClass((id)sv.delegate ?: (id)sv));
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

    UIEdgeInsets insets = [sv respondsToSelector:@selector(adjustedContentInset)] ? sv.adjustedContentInset : sv.contentInset;
    CGFloat minY = -insets.top;
    CGFloat maxY = fmaxf(minY, sv.contentSize.height - viewportH + insets.bottom);
    newY = fmaxf(minY, fminf(newY, maxY));

    if (fabs(newY - offset.y) > 0.1f) {
        [sv setContentOffset:CGPointMake(offset.x, newY) animated:NO];
        CC_LOG("Continuous scroll: sv=%p oldY=%.1f newY=%.1f maxY=%.1f delta=%.1f",
               sv, offset.y, newY, maxY, scaledDelta);
    }
    return YES;
}

static BOOL PerformScrollToTop(void) {
    UIScrollView *sv = GetActiveScrollView();
    if (!sv) return NO;

    UIEdgeInsets insets = [sv respondsToSelector:@selector(adjustedContentInset)] ? sv.adjustedContentInset : sv.contentInset;
    CGPoint topOffset = CGPointMake(sv.contentOffset.x, -insets.top);
    [sv setContentOffset:topOffset animated:YES];
    PlayHapticFeedback(UIImpactFeedbackStyleHeavy);
    CC_LOG("Scroll to top executed: sv=%p targetY=%.1f", sv, -insets.top);
    return YES;
}

// ============================================================================
// Documented Camera Control swipe path: AVCaptureSlider on a running session
// ============================================================================

static void HandleSwipeDeltaTriggered(CGFloat deltaY);

API_AVAILABLE(ios(18.0))
@interface CCSessionControlsDelegate : NSObject <AVCaptureSessionControlsDelegate>
@end

@implementation CCSessionControlsDelegate
- (void)sessionControlsDidBecomeActive:(AVCaptureSession *)session {
    CC_LOG("AVCaptureSession Camera Control became active: %p", session);
}
- (void)sessionControlsWillEnterFullscreenAppearance:(AVCaptureSession *)session {
    CC_LOG("AVCaptureSession Camera Control entering fullscreen appearance: %p", session);
}
- (void)sessionControlsWillExitFullscreenAppearance:(AVCaptureSession *)session {
    CC_LOG("AVCaptureSession Camera Control leaving fullscreen appearance: %p", session);
}
- (void)sessionControlsDidBecomeInactive:(AVCaptureSession *)session {
    CC_LOG("AVCaptureSession Camera Control became inactive: %p", session);
}
@end

// ============================================================================
// Native-Fidelity Bezel Pill Overlay (Zero-Camera Visual Feedback)
// ============================================================================

static __strong UIWindow *s_bezelOverlayWindow = nil;
static __strong UIView *s_bezelPillContainer = nil;
static __strong UIImageView *s_bezelIconView = nil;
static __strong UILabel *s_bezelTitleLabel = nil;
static __strong NSTimer *s_bezelDismissTimer = nil;
static BOOL s_bezelPillVisible = NO;

static void EnsureBezelOverlayViewCreated(void) {
    if (s_bezelOverlayWindow && s_bezelPillContainer) return;

    UIWindowScene *activeScene = nil;
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (activeScene) {
        s_bezelOverlayWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
    } else {
        s_bezelOverlayWindow = [[UIWindow alloc] initWithFrame:screenBounds];
    }

    s_bezelOverlayWindow.windowLevel = UIWindowLevelStatusBar - 1.0;
    s_bezelOverlayWindow.backgroundColor = [UIColor clearColor];
    s_bezelOverlayWindow.userInteractionEnabled = NO;
    s_bezelOverlayWindow.hidden = NO;

    // Camera Control button geometry on iPhone 16 / 16 Pro (Right Bezel, ~33% down)
    CGFloat pillWidth = 92.0f;
    CGFloat pillHeight = 34.0f;
    CGFloat pillX = screenBounds.size.width - pillWidth - 6.0f;
    CGFloat pillY = (screenBounds.size.height * 0.33f) - (pillHeight / 2.0f);

    s_bezelPillContainer = [[UIView alloc] initWithFrame:CGRectMake(pillX, pillY, pillWidth, pillHeight)];
    s_bezelPillContainer.userInteractionEnabled = NO;
    s_bezelPillContainer.layer.cornerRadius = 17.0f;
    s_bezelPillContainer.layer.masksToBounds = YES;
    s_bezelPillContainer.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.22f].CGColor;
    s_bezelPillContainer.layer.borderWidth = 0.5f;
    s_bezelPillContainer.alpha = 0.0f;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.frame = s_bezelPillContainer.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.userInteractionEnabled = NO;
    [s_bezelPillContainer addSubview:blurView];

    // Icon (SF Symbol)
    s_bezelIconView = [[UIImageView alloc] initWithFrame:CGRectMake(10.0f, 9.0f, 16.0f, 16.0f)];
    s_bezelIconView.contentMode = UIViewContentModeScaleAspectFit;
    s_bezelIconView.tintColor = [UIColor whiteColor];
    s_bezelIconView.image = [UIImage systemImageNamed:@"arrow.up.and.down"];
    [s_bezelPillContainer addSubview:s_bezelIconView];

    // Title label ("Scroll")
    s_bezelTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(32.0f, 0.0f, pillWidth - 36.0f, pillHeight)];
    s_bezelTitleLabel.text = @"Scroll";
    s_bezelTitleLabel.textColor = [UIColor whiteColor];
    s_bezelTitleLabel.font = [UIFont systemFontOfSize:12.5f weight:UIFontWeightSemibold];
    s_bezelTitleLabel.textAlignment = NSTextAlignmentLeft;
    [s_bezelPillContainer addSubview:s_bezelTitleLabel];

    [s_bezelOverlayWindow addSubview:s_bezelPillContainer];
}

static void ShowCameraControlBezelOverlay(CGFloat delta, NSString *title, NSString *symbolName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        EnsureBezelOverlayViewCreated();
        if (!s_bezelPillContainer) return;

        if (title && s_bezelTitleLabel) {
            s_bezelTitleLabel.text = title;
        }
        if (symbolName && s_bezelIconView) {
            UIImage *img = [UIImage systemImageNamed:symbolName];
            if (img) s_bezelIconView.image = img;
        }

        if (s_bezelDismissTimer) {
            [s_bezelDismissTimer invalidate];
            s_bezelDismissTimer = nil;
        }

        if (!s_bezelPillVisible) {
            s_bezelPillVisible = YES;
            s_bezelPillContainer.transform = CGAffineTransformMakeTranslation(40.0f, 0.0f);
            [UIView animateWithDuration:0.25
                                  delay:0.0
                 usingSpringWithDamping:0.75
                  initialSpringVelocity:0.5
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                s_bezelPillContainer.alpha = 1.0f;
                s_bezelPillContainer.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else if (fabs(delta) > 0.01) {
            CGFloat nudgeY = fmax(-3.0, fmin(3.0, (double)delta * 0.04));
            [UIView animateWithDuration:0.08 animations:^{
                s_bezelPillContainer.transform = CGAffineTransformMakeTranslation(0.0f, (CGFloat)nudgeY);
            } completion:^(BOOL finished) {
                [UIView animateWithDuration:0.08 animations:^{
                    s_bezelPillContainer.transform = CGAffineTransformIdentity;
                }];
            }];
        }

        s_bezelDismissTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                              repeats:NO
                                                                block:^(NSTimer *timer) {
            [UIView animateWithDuration:0.22 animations:^{
                s_bezelPillContainer.alpha = 0.0f;
                s_bezelPillContainer.transform = CGAffineTransformMakeTranslation(30.0f, 0.0f);
            } completion:^(BOOL finished) {
                s_bezelPillVisible = NO;
            }];
        }];
    });
}

static char kCCScrollSliderAssociationKey;
static char kCCControlsDelegateAssociationKey;

static void AddCameraControlScrollSlider(AVCaptureSession *session) {
    if (@available(iOS 18.0, *)) {
        if (!session || ![session respondsToSelector:@selector(supportsControls)]) return;
        if (objc_getAssociatedObject(session, &kCCScrollSliderAssociationKey)) return;

        if (!session.supportsControls) {
            CC_LOG("AVCaptureSession %p does not support Camera Control", session);
            return;
        }

        Class sliderClass = NSClassFromString(@"AVCaptureSlider");
        if (!sliderClass) {
            CC_LOG("AVCaptureSlider unavailable for AVCaptureSession %p", session);
            return;
        }

        id slider = ((id (*)(id, SEL, NSString *, NSString *, float, float))objc_msgSend)(
            [sliderClass alloc],
            sel_registerName("initWithLocalizedTitle:symbolName:minValue:maxValue:"),
            @"Scroll", @"arrow.up.and.down", -100.0f, 100.0f);
        if (!slider) return;

        // Center slider value at 0.0f initially
        if ([slider respondsToSelector:@selector(setValue:)]) {
            ((void (*)(id, SEL, float))objc_msgSend)(slider, @selector(setValue:), 0.0f);
        }

        __block float previousValue = 0.0f;
        __block BOOL isResetting = NO;

        __weak id weakSlider = slider;
        void (^action)(float) = ^(float value) {
            if (isResetting) return;

            float delta = value - previousValue;
            previousValue = value;

            if (fabsf(delta) < 0.0005f) return;

            // Direct non-inverted delta mapping
            CGFloat viewportHeight = [UIScreen mainScreen].bounds.size.height;
            CGFloat scrollDelta = (CGFloat)delta * (viewportHeight * 0.85f);

            CC_LOG("AVCaptureSlider swipe: val=%.4f delta=%.4f scrollDelta=%.2f",
                   value, delta, (double)scrollDelta);
            HandleSwipeDeltaTriggered(scrollDelta);
            ShowCameraControlBezelOverlay(scrollDelta, @"Scroll", @"arrow.up.and.down");

            // Infinite slider re-centering:
            // Programmatic setValue: does NOT trigger action callbacks in iOS 18 AVFoundation.
            // Re-centering when drifting away from 0 prevents hitting boundary clamps.
            if (fabsf(value) > 15.0f) {
                id strongSlider = weakSlider;
                if (strongSlider && [strongSlider respondsToSelector:@selector(setValue:)]) {
                    isResetting = YES;
                    ((void (*)(id, SEL, float))objc_msgSend)(strongSlider, @selector(setValue:), 0.0f);
                    previousValue = 0.0f;
                    isResetting = NO;
                }
            }
        };
        ((void (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(
            slider, sel_registerName("setActionQueue:action:"), dispatch_get_main_queue(), action);

        SEL delegateSelector = sel_registerName("controlsDelegate");
        id existingDelegate = [session respondsToSelector:delegateSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(session, delegateSelector)
            : nil;
        if (!existingDelegate) {
            CCSessionControlsDelegate *delegate = [CCSessionControlsDelegate new];
            SEL setDelegateSelector = sel_registerName("setControlsDelegate:queue:");
            if (![session respondsToSelector:setDelegateSelector]) return;
            ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(
                session, setDelegateSelector, delegate, dispatch_get_main_queue());
            objc_setAssociatedObject(session, &kCCControlsDelegateAssociationKey,
                                     delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CC_LOG("Installed Camera Control delegate on running session %p", session);
        }

        // AVCaptureSession permits adding controls while running. Use the same
        // configuration transaction as the app so the control is registered atomically.
        [session beginConfiguration];
        BOOL canAdd = [session canAddControl:(AVCaptureControl *)slider];
        if (canAdd) {
            [session addControl:(AVCaptureControl *)slider];
            objc_setAssociatedObject(session, &kCCScrollSliderAssociationKey,
                                     slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CC_LOG("Added Camera Control Scroll slider to session %p", session);
        } else {
            CC_LOG("AVCaptureSession %p rejected Camera Control Scroll slider", session);
        }
        [session commitConfiguration];
    }
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
            s_lastPageScrollTime = 0.0; // Reset debounce timer so double-press immediately executes
            // Compensate for the first press that already moved 1 step forward:
            // Move 2 steps backward so the net result is 1 step backward!
            PerformPageScroll(s_invertDirection.load() ? CCScrollDirectionNext : CCScrollDirectionPrevious, 2);
            ShowCameraControlBezelOverlay(0.0f, @"Prev", @"arrow.up");
        } else {
            // Single light-press -> Page Down / Next Reel
            CC_LOG("Single Light-Press detected! Scrolling to next page/reel...");
            PerformPageScroll(s_invertDirection.load() ? CCScrollDirectionPrevious : CCScrollDirectionNext, 1);
            ShowCameraControlBezelOverlay(0.0f, @"Next", @"arrow.down");
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
        ShowCameraControlBezelOverlay(0.0f, @"Top", @"arrow.up.to.line");
    });
}

static void HandleSwipeDeltaTriggered(CGFloat deltaY) {
    if (!s_enabled.load()) return;

    s_swipeCount.fetch_add(1);
    CGFloat effectiveDelta = s_invertDirection.load() ? -deltaY : deltaY;

    if ([NSThread isMainThread]) {
        PerformContinuousDeltaScroll(effectiveDelta, NO);
        ShowCameraControlBezelOverlay(effectiveDelta, @"Scroll", @"arrow.up.and.down");
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            PerformContinuousDeltaScroll(effectiveDelta, NO);
            ShowCameraControlBezelOverlay(effectiveDelta, @"Scroll", @"arrow.up.and.down");
        });
    }
}

static void HandleDigitizerSwipeDeltaTriggered(CGFloat deltaY) {
    if (!s_enabled.load()) return;

    s_swipeCount.fetch_add(1);
    CGFloat effectiveDelta = s_invertDirection.load() ? -deltaY : deltaY;
    dispatch_async(dispatch_get_main_queue(), ^{
        PerformContinuousDeltaScroll(effectiveDelta, YES);
        ShowCameraControlBezelOverlay(effectiveDelta, @"Scroll", @"arrow.up.and.down");
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

    // Ignore display-integrated digitizers to avoid turning ordinary screen
    // drags into duplicate scroll input. A non-display digitizer is still only
    // a candidate source; it is not proof that this event came from Camera Control.
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
    CGFloat coordinateMagnitude = fmax(fmax(fabs(x), fabs(y)),
                                       fmax(fabs(s_lastCameraControlX), fabs(s_lastCameraControlY)));
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

static void (*orig_AVCaptureSession_startRunning)(AVCaptureSession *session, SEL selector) = NULL;
static void (*orig_AVCaptureSession_stopRunning)(AVCaptureSession *session, SEL selector) = NULL;
static BOOL (*orig_AVCaptureSession_supportsControls)(AVCaptureSession *session, SEL selector) = NULL;
static BOOL (*orig_AVCaptureSession_canAddControl)(AVCaptureSession *session, SEL selector, id control) = NULL;

static __strong AVCaptureSession *s_persistedSession = nil;
static __strong AVCaptureSession *s_feedSession = nil;
static std::atomic<bool> s_isInBackground{false};
static dispatch_queue_t s_feedSessionQueue = NULL;

// ============================================================================
// System Volume Passthrough for AVCaptureEventInteraction
// ============================================================================

static void AdjustSystemVolumeBy(float step) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static __strong UISlider *s_volumeSlider = nil;
        static __strong UIView *s_volumeView = nil;

        if (!s_volumeSlider) {
            if (!s_volumeView) {
                dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY);
                Class volumeViewClass = NSClassFromString(@"MPVolumeView");
                if (volumeViewClass) {
                    s_volumeView = [[volumeViewClass alloc] initWithFrame:CGRectMake(-1000.0f, -1000.0f, 1.0f, 1.0f)];
                    s_volumeView.alpha = 0.0001f;
                    s_volumeView.userInteractionEnabled = NO;
                    UIWindow *win = GetActiveKeyWindow();
                    if (win) {
                        [win addSubview:s_volumeView];
                    }
                }
            }
            if (s_volumeView) {
                for (UIView *subview in s_volumeView.subviews) {
                    if ([subview isKindOfClass:[UISlider class]]) {
                        s_volumeSlider = (UISlider *)subview;
                        break;
                    }
                }
            }
        }

        if (s_volumeSlider) {
            float current = s_volumeSlider.value;
            float newVol = fmaxf(0.0f, fminf(1.0f, current + step));
            [s_volumeSlider setValue:newVol animated:YES];
            [s_volumeSlider sendActionsForControlEvents:UIControlEventValueChanged];
            CC_LOG("Volume passthrough: %.2f -> %.2f (step=%.4f)", current, newVol, step);
        }
    });
}

// ============================================================================
// AVKit AVCaptureEventInteraction Setup (iOS 17.2+ / iOS 18+)
// Active responder chain integration with volume passthrough
// ============================================================================

static void AttachCaptureEventInteractionToView(UIView *view) {
    if (!view) return;

    Class interactionClass = NSClassFromString(@"AVCaptureEventInteraction");
    if (!interactionClass) return;

    for (id<UIInteraction> interaction in view.interactions) {
        if ([interaction isKindOfClass:interactionClass]) {
            return; // Already attached to this view
        }
    }

    @try {
        SEL primarySel = sel_registerName("initWithPrimaryEventHandler:secondaryEventHandler:");
        if ([interactionClass instancesRespondToSelector:primarySel]) {
            id interaction = [interactionClass alloc];

            // Primary Handler (Volume Down): Adjusts volume DOWN without scrolling feed
            void (^primaryHandler)(id) = ^(id event) {
                NSInteger phase = 0;
                if ([event respondsToSelector:@selector(phase)]) {
                    phase = ((NSInteger (*)(id, SEL))objc_msgSend)(event, @selector(phase));
                }
                if (phase == 0) { // AVCaptureEventPhaseBegan
                    AdjustSystemVolumeBy(-0.0625f); // 1/16th volume step down
                }
            };

            // Secondary Handler (Volume Up): Adjusts volume UP without scrolling feed
            void (^secondaryHandler)(id) = ^(id event) {
                NSInteger phase = 0;
                if ([event respondsToSelector:@selector(phase)]) {
                    phase = ((NSInteger (*)(id, SEL))objc_msgSend)(event, @selector(phase));
                }
                if (phase == 0) { // AVCaptureEventPhaseBegan
                    AdjustSystemVolumeBy(0.0625f); // 1/16th volume step up
                }
            };

            interaction = ((id (*)(id, SEL, id, id))objc_msgSend)(
                interaction, primarySel, primaryHandler, secondaryHandler);

            if (interaction) {
                [view addInteraction:interaction];
                CC_LOG("Attached AVCaptureEventInteraction with volume passthrough to view: %p", view);
            }
        }
    } @catch (NSException *e) {
        CC_LOG("Exception attaching AVCaptureEventInteraction: %@", e);
    }
}

static void AttachCaptureEventInteractionToWindow(UIWindow *window) {
    AttachCaptureEventInteractionToView(window);
}

// ============================================================================
// UIViewController Swizzle: Active UI Responder Chain Registration
// ============================================================================

static void (*orig_UIViewController_viewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;

static void Hook_UIViewController_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_UIViewController_viewDidAppear) {
        orig_UIViewController_viewDidAppear(self, _cmd, animated);
    }

    if (self.view && !self.view.hidden) {
        AttachCaptureEventInteractionToView(self.view);
    }
}

static void InstallViewControllerHook(void) {
    Class vcClass = [UIViewController class];
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(vcClass, sel);
    if (m) {
        orig_UIViewController_viewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(m);
        method_setImplementation(m, (IMP)Hook_UIViewController_viewDidAppear);
        CC_LOG("Hooked -[UIViewController viewDidAppear:] for active responder chain integration");
    }
}

static BOOL Hook_AVCaptureSession_supportsControls(AVCaptureSession *session, SEL selector) {
    if (@available(iOS 18.0, *)) {
        return YES;
    }
    return orig_AVCaptureSession_supportsControls ? orig_AVCaptureSession_supportsControls(session, selector) : NO;
}

static BOOL Hook_AVCaptureSession_canAddControl(AVCaptureSession *session, SEL selector, id control) {
    if (@available(iOS 18.0, *)) {
        if (!control) return NO;
        NSArray *existing = [session respondsToSelector:@selector(controls)] ? session.controls : nil;
        if (existing && [existing containsObject:control]) return NO;
        NSInteger maxCount = [session respondsToSelector:@selector(maxControlsCount)] ? session.maxControlsCount : 2;
        if (existing && existing.count >= (NSUInteger)maxCount) return NO;
        return YES;
    }
    return orig_AVCaptureSession_canAddControl ? orig_AVCaptureSession_canAddControl(session, selector, (AVCaptureControl *)control) : YES;
}

static void EnsureFeedCaptureSessionRunning(void) {
    if (!s_enabled.load()) return;
    if (s_isInBackground.load()) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    if (s_feedSession && s_feedSession.isRunning) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_feedSessionQueue = dispatch_queue_create("com.instagram.cameracontrol.session", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(s_feedSessionQueue, ^{
        @try {
            if (s_feedSession && s_feedSession.isRunning) {
                return;
            }

            if (!s_feedSession) {
                // Port-Muted Spoofed Pipeline:
                // Attaches a real video device input and passive photo output so mediaserverd
                // and backboardd recognize an established capture pipeline and route Camera Control
                // hardware swipe events to AVCaptureSlider.
                //
                // IMMEDIATELY upon attaching:
                // 1. All video input ports are disabled (port.enabled = NO).
                // 2. All session connections are disabled (conn.enabled = NO).
                //
                // Result:
                // - Physical camera sensor enters standby (ZERO camera battery drain).
                // - mediaserverd reports 0 streaming video frames to SystemStatusServer (GREEN DOT IS 100% OFF).
                // - AVCaptureVideoPreviewLayer is completely omitted (ZERO GPU load, ZERO modal bleed).
                // - Hardware swipe gestures are delivered 100% to AVCaptureSlider.
                s_feedSession = [[AVCaptureSession alloc] init];
                if ([s_feedSession canSetSessionPreset:AVCaptureSessionPresetLow]) {
                    s_feedSession.sessionPreset = AVCaptureSessionPresetLow;
                }

                [s_feedSession beginConfiguration];

                AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
                if (device) {
                    NSError *err = nil;
                    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
                    if (input && [s_feedSession canAddInput:input]) {
                        [s_feedSession addInput:input];

                        // SPOOF: Disable all video input ports to cut sensor power & suppress green dot
                        for (AVCaptureInputPort *port in input.ports) {
                            if ([port.mediaType isEqualToString:AVMediaTypeVideo]) {
                                port.enabled = NO;
                            }
                        }
                    }
                }

                AVCapturePhotoOutput *photoOutput = [[AVCapturePhotoOutput alloc] init];
                if ([photoOutput respondsToSelector:@selector(setHighResolutionCaptureEnabled:)]) {
                    photoOutput.highResolutionCaptureEnabled = NO;
                }
                if ([s_feedSession canAddOutput:photoOutput]) {
                    [s_feedSession addOutput:photoOutput];
                }

                // Explicitly disable all connections so zero frames flow
                for (AVCaptureConnection *conn in s_feedSession.connections) {
                    conn.enabled = NO;
                }

                [s_feedSession commitConfiguration];
            }

            if (!s_feedSession.isRunning) {
                CC_LOG("Starting port-muted spoofed AVCaptureSession for Camera Control...");
                if (orig_AVCaptureSession_startRunning) {
                    orig_AVCaptureSession_startRunning(s_feedSession, @selector(startRunning));
                } else {
                    [s_feedSession startRunning];
                }
                CC_LOG("Port-muted spoofed AVCaptureSession running state: %d (Green Dot: OFF)", s_feedSession.isRunning);
            }

            if (@available(iOS 18.0, *)) {
                AddCameraControlScrollSlider(s_feedSession);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *keyWindow = GetActiveKeyWindow();
                if (keyWindow) {
                    AttachCaptureEventInteractionToWindow(keyWindow);
                }
            });
        } @catch (NSException *e) {
            CC_LOG("Exception starting port-muted spoofed feed session: %@", e);
        }
    });
}

static void Hook_AVCaptureSession_startRunning(AVCaptureSession *session, SEL selector) {
    // If our dedicated zero-camera feed session is running and Instagram starts its own real camera session,
    // yield our feed session so there is zero conflict.
    if (s_feedSession && s_feedSession != session && s_feedSession.isRunning) {
        CC_LOG("Instagram camera session starting; yielding zero-camera feed session %p", s_feedSession);
        if (orig_AVCaptureSession_stopRunning) {
            orig_AVCaptureSession_stopRunning(s_feedSession, @selector(stopRunning));
        } else {
            [s_feedSession stopRunning];
        }
    }

    s_persistedSession = session;

    if (orig_AVCaptureSession_startRunning) {
        orig_AVCaptureSession_startRunning(session, selector);
    }
    if (@available(iOS 18.0, *)) {
        AddCameraControlScrollSlider(session);
    }
}

static void Hook_AVCaptureSession_stopRunning(AVCaptureSession *session, SEL selector) {
    CC_LOG("AVCaptureSession -stopRunning called: session=%p, appState=%ld, inBackground=%d",
           session, (long)[UIApplication sharedApplication].applicationState, s_isInBackground.load());

    // When Instagram stops its own camera session (or when going to background), allow it to stop
    // so the real camera hardware powers down completely.
    if (orig_AVCaptureSession_stopRunning) {
        orig_AVCaptureSession_stopRunning(session, selector);
    }

    // In foreground: Resume our zero-camera feed session so Camera Control remains active in Feed without green dot!
    if (!s_isInBackground.load() && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EnsureFeedCaptureSessionRunning();
        });
    }
}

static void SetupAppLifecycleObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        CC_LOG("App entered background; stopping capture sessions to preserve battery");
        s_isInBackground.store(true);
        if (s_bezelDismissTimer) {
            [s_bezelDismissTimer invalidate];
            s_bezelDismissTimer = nil;
        }
        if (s_bezelPillContainer) {
            s_bezelPillContainer.alpha = 0.0f;
            s_bezelPillVisible = NO;
        }
        if (s_persistedSession && s_persistedSession.isRunning) {
            if (orig_AVCaptureSession_stopRunning) {
                orig_AVCaptureSession_stopRunning(s_persistedSession, @selector(stopRunning));
            } else {
                [s_persistedSession stopRunning];
            }
        }
        if (s_feedSession && s_feedSession.isRunning) {
            if (orig_AVCaptureSession_stopRunning) {
                orig_AVCaptureSession_stopRunning(s_feedSession, @selector(stopRunning));
            } else {
                [s_feedSession stopRunning];
            }
        }
    }];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        CC_LOG("App became active; ensuring zero-camera Camera Control session is active in Feed");
        s_isInBackground.store(false);
        UIWindow *win = GetActiveKeyWindow();
        if (win) {
            AttachCaptureEventInteractionToWindow(win);
        }
        EnsureFeedCaptureSessionRunning();
    }];

    [nc addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindow class]]) {
            AttachCaptureEventInteractionToWindow((UIWindow *)note.object);
        }
    }];
}

static void InstallCaptureSessionHook(void) {
    // Loading the framework first makes the iOS 18 capture-control classes and
    // AVCaptureSession implementation available before resolving the method.
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    Class sessionClass = NSClassFromString(@"AVCaptureSession");
    if (!sessionClass) {
        CC_LOG("Could not hook AVCaptureSession: class unavailable");
        return;
    }

    // 1. Hook -[AVCaptureSession startRunning]
    SEL startSel = @selector(startRunning);
    Method startMethod = class_getInstanceMethod(sessionClass, startSel);
    if (startMethod) {
        IMP currentStart = method_getImplementation(startMethod);
        if (currentStart != (IMP)Hook_AVCaptureSession_startRunning) {
            orig_AVCaptureSession_startRunning = (void (*)(AVCaptureSession *, SEL))currentStart;
            method_setImplementation(startMethod, (IMP)Hook_AVCaptureSession_startRunning);
            CC_LOG("Hooked AVCaptureSession -startRunning for Camera Control slider setup");
        }
    }

    // 2. Hook -[AVCaptureSession stopRunning]
    SEL stopSel = @selector(stopRunning);
    Method stopMethod = class_getInstanceMethod(sessionClass, stopSel);
    if (stopMethod) {
        IMP currentStop = method_getImplementation(stopMethod);
        if (currentStop != (IMP)Hook_AVCaptureSession_stopRunning) {
            orig_AVCaptureSession_stopRunning = (void (*)(AVCaptureSession *, SEL))currentStop;
            method_setImplementation(stopMethod, (IMP)Hook_AVCaptureSession_stopRunning);
            CC_LOG("Hooked AVCaptureSession -stopRunning for Feed persistence");
        }
    }

    // 3. Hook -[AVCaptureSession supportsControls] (iOS 18+)
    SEL supportsSel = sel_registerName("supportsControls");
    Method supportsMethod = class_getInstanceMethod(sessionClass, supportsSel);
    if (supportsMethod) {
        IMP currentSupports = method_getImplementation(supportsMethod);
        if (currentSupports != (IMP)Hook_AVCaptureSession_supportsControls) {
            orig_AVCaptureSession_supportsControls = (BOOL (*)(AVCaptureSession *, SEL))currentSupports;
            method_setImplementation(supportsMethod, (IMP)Hook_AVCaptureSession_supportsControls);
            CC_LOG("Hooked AVCaptureSession -supportsControls for zero-camera session compatibility");
        }
    }

    // 4. Hook -[AVCaptureSession canAddControl:] (iOS 18+)
    SEL canAddSel = sel_registerName("canAddControl:");
    Method canAddMethod = class_getInstanceMethod(sessionClass, canAddSel);
    if (canAddMethod) {
        IMP currentCanAdd = method_getImplementation(canAddMethod);
        if (currentCanAdd != (IMP)Hook_AVCaptureSession_canAddControl) {
            orig_AVCaptureSession_canAddControl = (BOOL (*)(AVCaptureSession *, SEL, id))currentCanAdd;
            method_setImplementation(canAddMethod, (IMP)Hook_AVCaptureSession_canAddControl);
            CC_LOG("Hooked AVCaptureSession -canAddControl: for zero-camera session compatibility");
        }
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
// Darwin Notification Relay: Fallback from SpringBoard System HID Monitor
// ============================================================================

static void RegisterFeedSwipeDarwinNotificationObserver(void) {
    typedef uint32_t (*NotifyRegisterDispatchFunc)(const char *, int *, dispatch_queue_t, void (^)(int));
    typedef uint32_t (*NotifyGetStateFunc)(int, uint64_t *);

    NotifyRegisterDispatchFunc regDispatch = (NotifyRegisterDispatchFunc)dlsym(RTLD_DEFAULT, "notify_register_dispatch");
    NotifyGetStateFunc getState = (NotifyGetStateFunc)dlsym(RTLD_DEFAULT, "notify_get_state");

    if (!regDispatch || !getState) {
        CC_LOG("Darwin notification symbols unavailable");
        return;
    }

    static int token = 0;
    uint32_t status = regDispatch("com.instagramscroll.cameracontrol.feed-swipe", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        if (getState(t, &state) == 0 && state != 0) {
            int32_t centipoints = (int32_t)(state & 0xFFFFFFFF);
            CGFloat deltaPoints = (CGFloat)centipoints / 100.0f;
            if (std::isfinite((double)deltaPoints) && fabs(deltaPoints) > 0.01f) {
                CGFloat viewportH = [UIScreen mainScreen].bounds.size.height;
                CGFloat scrollDelta = (CGFloat)deltaPoints * (viewportH * 0.05f);
                CC_LOG("Darwin relay feed swipe: centipoints=%d deltaPoints=%.2f scrollDelta=%.2f",
                       centipoints, (double)deltaPoints, (double)scrollDelta);
                HandleSwipeDeltaTriggered(scrollDelta);
                ShowCameraControlBezelOverlay(scrollDelta, @"Scroll", @"arrow.up.and.down");
            }
        }
    });
    CC_LOG("Registered Darwin notification listener for com.instagramscroll.cameracontrol.feed-swipe (status=%u, token=%d)",
           status, token);
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

        // 2. Register a documented swipe-value control on active camera sessions and manage session persistence.
        InstallCaptureSessionHook();

        // 3. Hook viewDidAppear to integrate active UI responder chain with Camera Control
        InstallViewControllerHook();

        // 4. Setup lifecycle observers for background/foreground session management
        SetupAppLifecycleObservers();

        // 5. Register Darwin notification listener for system HID monitor events
        RegisterFeedSwipeDarwinNotificationObserver();

        // Spin up feed capture session and attach interaction immediately if already active
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = GetActiveKeyWindow();
            if (win) {
                AttachCaptureEventInteractionToWindow(win);
            }
            EnsureFeedCaptureSessionRunning();
        });

        CC_LOG("InstagramCameraControlScroll initialized successfully!");
    });
}

__attribute__((constructor))
static void InstagramCameraControlScroll_Ctor(void) {
    InstagramCameraControlScroll_Init();
}
