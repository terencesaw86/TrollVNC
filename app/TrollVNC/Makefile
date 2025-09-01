ARCHS := arm64
TARGET := iphone:clang:latest:14.0

INSTALL_TARGET_PROCESSES += TrollVNC

include $(THEOS)/makefiles/common.mk

XCODEPROJ_NAME := TrollVNC
TrollVNC_XCODE_SCHEME = TrollVNC

include $(THEOS_MAKE_PATH)/xcodeproj.mk
