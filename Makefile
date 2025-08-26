ARCHS := arm64
ifeq ($(THEOS_PACKAGE_SCHEME),)
TARGET := iphone:clang:14.5:14.0
else
TARGET := iphone:clang:16.5:15.0
endif

include $(THEOS)/makefiles/common.mk

TOOL_NAME := trollvncserver

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm
trollvncserver_FILES += src/ScreenCapturer.mm
trollvncserver_FILES += src/STHIDEventGenerator.mm
trollvncserver_FILES += src/ClipboardManager.mm

trollvncserver_CFLAGS += -fobjc-arc
trollvncserver_CFLAGS += -Iinclude
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_LDFLAGS += -Llib

trollvncserver_LIBRARIES += jpeg
trollvncserver_LIBRARIES += png16
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z

trollvncserver_FRAMEWORKS += Accelerate
trollvncserver_FRAMEWORKS += CoreGraphics
trollvncserver_FRAMEWORKS += CoreMedia
trollvncserver_FRAMEWORKS += CoreVideo
trollvncserver_FRAMEWORKS += Foundation
trollvncserver_FRAMEWORKS += IOKit
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += UIKit

trollvncserver_PRIVATE_FRAMEWORKS += IOMobileFramebuffer
trollvncserver_PRIVATE_FRAMEWORKS += IOSurface

trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
