ARCHS := arm64
TARGET := iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME := trollvncserver

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm

trollvncserver_CFLAGS += -fobjc-arc
trollvncserver_CFLAGS += -Iinclude
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_LDFLAGS += -Llib

trollvncserver_LIBRARIES += jpeg
trollvncserver_LIBRARIES += png
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z

trollvncserver_FRAMEWORKS += Foundation

trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
