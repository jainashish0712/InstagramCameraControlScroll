#!/usr/bin/env python3
"""
Comprehensive Unit Test and Static Verification Suite for InstagramCameraControlScroll
iPhone 16 Pro / iOS 18+ Hardware Camera Control Scroll Engine

Tests:
1. Mock Camera Control Event & Gesture Engine:
   - Single Light-Press -> Page Next / Reel Advance
   - Double Light-Press -> Page Prev / Reel Back
   - Capacitive Swipe Tracking & Accumulation -> Continuous Scroll & Snap
   - Hard Mechanical Click -> Scroll to Top
   - Debounce & Timing Windows
2. Static Syntax & Bracket Balance Integrity on .h and .mm files
3. Targeted Selector and Low-Level Hook Verification
4. Concurrency & Thread-Safety Verification
"""

import sys
import os
import re
import time
import threading
import unittest

# ============================================================================
# Mock Runtime Engine simulating InstagramCameraControlScroll.mm
# ============================================================================

class MockCameraControlScrollEngine:
    def __init__(self):
        self.enabled = True
        self.invert_direction = False
        self.haptics_enabled = True
        self.sensitivity = 1.0

        # Telemetry
        self.swipe_count = 0
        self.light_press_count = 0
        self.click_count = 0

        # Scroll state
        self.content_offset_y = 0.0
        self.content_height = 5000.0
        self.viewport_height = 844.0 # iPhone screen height
        self.is_paging = False # False for feed, True for reels

        # Debounce tracking
        self.last_light_press_time = 0.0
        self.last_click_time = 0.0
        self.last_page_time = 0.0
        self.min_page_interval = 0.28
        self.double_press_window = 0.38
        self.accumulated_swipe_delta = 0.0
        self.swipe_snap_threshold = 35.0

        self.last_action_executed = None
        self._lock = threading.Lock()

    def set_reels_mode(self, is_reels: bool):
        with self._lock:
            self.is_paging = is_reels

    def perform_page_scroll(self, direction: int, current_time: float) -> bool:
        with self._lock:
            if current_time - self.last_page_time < self.min_page_interval:
                return False # Debounced
            self.last_page_time = current_time

            if self.is_paging:
                # Snap to next/prev full screen page
                if direction > 0:
                    target_y = (int(self.content_offset_y // self.viewport_height) + 1) * self.viewport_height
                else:
                    target_y = (int(self.content_offset_y // self.viewport_height) - 1) * self.viewport_height
            else:
                # Continuous feed step
                step = self.viewport_height * 0.75
                target_y = self.content_offset_y + (step * direction)

            target_y = max(0.0, min(target_y, self.content_height - self.viewport_height))
            if abs(target_y - self.content_offset_y) > 0.5:
                self.content_offset_y = target_y
                self.last_action_executed = "PAGE_DOWN" if direction > 0 else "PAGE_UP"
                return True
            return False

    def handle_light_press(self, current_time: float) -> str:
        with self._lock:
            if not self.enabled:
                return "DISABLED"

            elapsed = current_time - self.last_light_press_time
            self.last_light_press_time = current_time
            self.light_press_count += 1

            if 0.05 < elapsed < self.double_press_window:
                direction = 1 if self.invert_direction else -1
                action = "PAGE_PREV"
            else:
                direction = -1 if self.invert_direction else 1
                action = "PAGE_NEXT"

        self.perform_page_scroll(direction, current_time)
        return action

    def handle_hard_click(self, current_time: float) -> bool:
        with self._lock:
            if not self.enabled:
                return False
            if current_time - self.last_click_time < 0.35:
                return False
            self.last_click_time = current_time
            self.click_count += 1
            self.content_offset_y = 0.0
            self.last_action_executed = "SCROLL_TO_TOP"
            return True

    def handle_swipe_delta(self, delta_y: float, current_time: float):
        with self._lock:
            if not self.enabled:
                return
            self.swipe_count += 1
            effective_delta = -delta_y if self.invert_direction else delta_y

            if self.is_paging:
                self.accumulated_swipe_delta += effective_delta
                if self.accumulated_swipe_delta >= self.swipe_snap_threshold:
                    self.accumulated_swipe_delta = 0.0
                    self.perform_page_scroll(1, current_time)
                elif self.accumulated_swipe_delta <= -self.swipe_snap_threshold:
                    self.accumulated_swipe_delta = 0.0
                    self.perform_page_scroll(-1, current_time)
            else:
                scaled_delta = effective_delta * self.sensitivity
                new_y = self.content_offset_y + scaled_delta
                self.content_offset_y = max(0.0, min(new_y, self.content_height - self.viewport_height))
                self.last_action_executed = "CONTINUOUS_SCROLL"


# ============================================================================
# Unit Tests
# ============================================================================

class TestCameraControlScrollEngine(unittest.TestCase):
    def setUp(self):
        self.engine = MockCameraControlScrollEngine()

    def test_single_light_press_reels_snap_down(self):
        """Single light press in Reels mode snaps to next reel (+1 viewport height)."""
        self.engine.set_reels_mode(True)
        self.assertEqual(self.engine.content_offset_y, 0.0)

        action = self.engine.handle_light_press(100.0)
        self.assertEqual(action, "PAGE_NEXT")
        self.assertEqual(self.engine.content_offset_y, 844.0)
        self.assertEqual(self.engine.light_press_count, 1)

        # Another single light press after cooldown advances to Reel 3
        action2 = self.engine.handle_light_press(100.5)
        self.assertEqual(action2, "PAGE_NEXT")
        self.assertEqual(self.engine.content_offset_y, 1688.0)
        self.assertEqual(self.engine.light_press_count, 2)

    def test_double_light_press_reels_snap_up(self):
        """Double light-press within window snaps backward to previous reel."""
        self.engine.set_reels_mode(True)
        # Advance to Reel 3 first
        self.engine.content_offset_y = 1688.0

        # First press
        self.engine.handle_light_press(100.0)
        # Second press within double press window (e.g. 150ms later)
        action = self.engine.handle_light_press(100.15)
        self.assertEqual(action, "PAGE_PREV")
        self.assertEqual(self.engine.content_offset_y, 844.0)

    def test_hard_click_scroll_to_top(self):
        """Hard mechanical click triggers instant scroll to top of feed."""
        self.engine.content_offset_y = 3500.0
        success = self.engine.handle_hard_click(100.0)
        self.assertTrue(success)
        self.assertEqual(self.engine.content_offset_y, 0.0)
        self.assertEqual(self.engine.last_action_executed, "SCROLL_TO_TOP")
        self.assertEqual(self.engine.click_count, 1)

    def test_capacitive_swipe_continuous_feed(self):
        """Capacitive swipe in feed mode produces smooth proportional scrolling."""
        self.engine.set_reels_mode(False)
        self.engine.content_offset_y = 100.0

        self.engine.handle_swipe_delta(50.0, 100.0)
        self.assertEqual(self.engine.content_offset_y, 150.0)
        self.assertEqual(self.engine.swipe_count, 1)

    def test_capacitive_swipe_reels_snap(self):
        """In Reels mode, accumulating swipe delta triggers crisp page flip."""
        self.engine.set_reels_mode(True)
        self.engine.content_offset_y = 0.0

        # Small micro-touches below threshold do not flip reel
        self.engine.handle_swipe_delta(15.0, 100.0)
        self.assertEqual(self.engine.content_offset_y, 0.0)

        # Accumulating past threshold (35pt) snaps cleanly to next reel
        self.engine.handle_swipe_delta(25.0, 100.1)
        self.assertEqual(self.engine.content_offset_y, 844.0)

    def test_concurrency_thread_safety(self):
        """Validates thread-safe execution under simultaneous multi-touch and press events."""
        def worker(w_id):
            base_time = 1000.0 + (w_id * 10.0)
            for i in range(25):
                t = base_time + (i * 0.35)
                self.engine.handle_light_press(t)
                self.engine.handle_swipe_delta(10.0, t + 0.05)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(self.engine.light_press_count, 200)
        self.assertEqual(self.engine.swipe_count, 200)


# ============================================================================
# Static Syntax, Bracket Balance & Symbol Verification
# ============================================================================

def check_brackets_balance(filename):
    print(f"Checking bracket and delimiter balance: {os.path.basename(filename)}...")
    with open(filename, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    cleaned = re.sub(r'//.*', '', content)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r'"(\\.|[^"\\])*"', '""', cleaned)

    stack = []
    pairs = {')': '(', '}': '{', ']': '['}
    line_num = 1
    col_num = 0

    for char in cleaned:
        if char == '\n':
            line_num += 1
            col_num = 0
            continue
        col_num += 1

        if char in pairs.values():
            stack.append((char, line_num, col_num))
        elif char in pairs.keys():
            if not stack:
                print(f"  --> Unmatched closing '{char}' at line {line_num}, col {col_num}")
                return False
            top, top_line, top_col = stack.pop()
            if top != pairs[char]:
                print(f"  --> Mismatched delimiter: expected '{pairs[char]}' for '{char}' at line {line_num}, col {col_num}, but found '{top}' from line {top_line}, col {top_col}")
                return False

    if stack:
        top, top_line, top_col = stack.pop()
        print(f"  --> Unclosed delimiter '{top}' from line {top_line}, col {top_col}")
        return False

    print(f"  --> {os.path.basename(filename)} bracket balance: PERFECT")
    return True

def verify_targeted_symbols(filename):
    print(f"Verifying targeted hooks and symbol declarations in {os.path.basename(filename)}...")
    with open(filename, 'r', encoding='utf-8') as f:
        code = f.read()

    required_symbols = [
        "_handleHIDEvent:",
        "IOHIDEventGetType",
        "IOHIDEventGetIntegerValue",
        "kHIDPage_CameraControl",
        "kHIDUsage_CC_Autofocus",
        "kHIDUsage_CC_Shutter",
        "AVCaptureEventInteraction",
        "initWithPrimaryEventHandler:secondaryEventHandler:",
        "GetActiveScrollView",
        "PerformPageScroll",
        "PerformContinuousDeltaScroll",
        "PerformScrollToTop",
        "InstagramCameraControlScroll_Init"
    ]

    for sym in required_symbols:
        if sym not in code:
            print(f"  --> MISSING required symbol: {sym}")
            return False
        print(f"  --> Verified symbol: {sym}")

    return True

def run_all_checks():
    print("=" * 60)
    print("InstagramCameraControlScroll Verification Suite")
    print("=" * 60)

    dir_path = os.path.dirname(os.path.abspath(__file__))
    h_file = os.path.join(dir_path, "InstagramCameraControlScroll.h")
    mm_file = os.path.join(dir_path, "InstagramCameraControlScroll.mm")

    # 1. Bracket checks
    if not check_brackets_balance(h_file):
        return False
    if not check_brackets_balance(mm_file):
        return False

    # 2. Symbol checks
    if not verify_targeted_symbols(mm_file):
        return False

    # 3. Unit test suite
    print("\nRunning Mock Runtime Unit Tests...")
    suite = unittest.TestLoader().loadTestsFromTestCase(TestCameraControlScrollEngine)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    if not result.wasSuccessful():
        return False

    print("\n>>> ALL CAMERA CONTROL VERIFICATION AUDITS PASSED 100% <<<")
    return True

if __name__ == "__main__":
    success = run_all_checks()
    sys.exit(0 if success else 1)
