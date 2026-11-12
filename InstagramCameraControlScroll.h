//
//  InstagramCameraControlScroll.h
//  InstagramCameraControlScroll
//
//  Hardware Camera Control (iPhone 16 Pro / iOS 18+) Scroll Engine for Instagram
//  Repurposes the capacitive swipe strip and multi-stage pressure sensor for:
//  - Light Press: Page down / Next Reel
//  - Double Light Press: Page up / Previous Reel
//  - Swipe / Slide: Tactile continuous scrolling or swipe-between-reels
//  - Hard Click: Scroll to top of feed / Toggle play-pause
//

#ifndef InstagramCameraControlScroll_h
#define InstagramCameraControlScroll_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Master toggle for Camera Control scrolling
void InstagramCameraControlScroll_SetEnabled(BOOL enabled);
BOOL InstagramCameraControlScroll_IsEnabled(void);

/// Sensitivity factor for capacitive swipe scrolling (default: 1.0f, range: 0.2f - 3.0f)
void InstagramCameraControlScroll_SetSensitivity(CGFloat sensitivity);
CGFloat InstagramCameraControlScroll_GetSensitivity(void);

/// Invert scroll direction (YES = swipe up scrolls down; NO = natural scroll)
void InstagramCameraControlScroll_SetInvertDirection(BOOL inverted);
BOOL InstagramCameraControlScroll_IsInvertDirection(void);

/// Enable/disable haptic feedback on page change (default: YES)
void InstagramCameraControlScroll_SetHapticsEnabled(BOOL enabled);
BOOL InstagramCameraControlScroll_IsHapticsEnabled(void);

/// Programmatic scroll triggers
BOOL InstagramCameraControlScroll_ScrollNextPage(void);
BOOL InstagramCameraControlScroll_ScrollPreviousPage(void);
BOOL InstagramCameraControlScroll_ScrollToTop(void);

/// Telemetry
NSUInteger InstagramCameraControlScroll_GetSwipeCount(void);
NSUInteger InstagramCameraControlScroll_GetLightPressCount(void);
NSUInteger InstagramCameraControlScroll_GetClickCount(void);

/// Master initialization entry point (thread-safe, dispatch_once guarded)
void InstagramCameraControlScroll_Init(void);

#ifdef __cplusplus
}
#endif

#endif /* InstagramCameraControlScroll_h */
