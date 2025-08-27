ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
else
ARCHS := arm64
ifeq ($(THEOS_PACKAGE_SCHEME),)
TARGET := iphone:clang:14.5:14.0
else
TARGET := iphone:clang:16.5:15.0
endif
endif

GO_EASY_ON_ME := 1

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
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_LDFLAGS += -FPrivateFrameworks
endif

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
trollvncserver_FRAMEWORKS += IOSurface
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += UIKit

trollvncserver_PRIVATE_FRAMEWORKS += FrontBoardServices
trollvncserver_PRIVATE_FRAMEWORKS += IOMobileFramebuffer
trollvncserver_PRIVATE_FRAMEWORKS += IOSurfaceAccelerator

trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
