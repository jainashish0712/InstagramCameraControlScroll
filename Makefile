TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramCameraControlScroll

InstagramCameraControlScroll_FILES = InstagramCameraControlScroll.mm
InstagramCameraControlScroll_CFLAGS = -fobjc-arc -O3 -std=c++17
InstagramCameraControlScroll_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore
InstagramCameraControlScroll_LIBRARIES = c++

include $(THEOS_MAKE_PATH)/tweak.mk
