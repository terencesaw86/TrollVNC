ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell devkit/sim-root.sh)
else
ARCHS := arm64
ifeq ($(THEOS_PACKAGE_SCHEME),)
TARGET := iphone:clang:16.5:14.0
else
TARGET := iphone:clang:16.5:15.0
endif
endif

GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME := trollvncserver

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm
trollvncserver_FILES += src/ClipboardManager.mm
trollvncserver_FILES += src/ScreenCapturer.mm
trollvncserver_FILES += src/STHIDEventGenerator.mm
trollvncserver_FILES += src/OhMyJetsam.mm

trollvncserver_CFLAGS += -fobjc-arc
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_CFLAGS += -march=armv8-a+crc
endif
# trollvncserver_CFLAGS += -DFB_LOG=1
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_CFLAGS += -Iinclude-spi
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CFLAGS += -Iinclude-simulator
trollvncserver_LDFLAGS += -Llib-simulator
trollvncserver_LDFLAGS += -FPrivateFrameworks
else
trollvncserver_CFLAGS += -Iinclude
trollvncserver_LDFLAGS += -Llib
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
else
trollvncserver_LIBRARIES += crypto
trollvncserver_LIBRARIES += lzo2
trollvncserver_LIBRARIES += turbojpeg
trollvncserver_LIBRARIES += png16
trollvncserver_LIBRARIES += sasl2
trollvncserver_LIBRARIES += ssl
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
endif

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
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_PRIVATE_FRAMEWORKS += IOMobileFramebuffer
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncserver-simulator.entitlements
else
trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements
endif

include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += prefs/TrollVNCPrefs

include $(THEOS_MAKE_PATH)/aggregate.mk

export THEOS_PACKAGE_SCHEME
export THEOS_STAGING_DIR
before-package::
	@devkit/before-package.sh
