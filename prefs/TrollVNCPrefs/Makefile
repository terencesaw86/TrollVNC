TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES := Preferences
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := TrollVNCPrefs

TrollVNCPrefs_FILES += TVNCRootListController.m
TrollVNCPrefs_CFLAGS += -fobjc-arc

TrollVNCPrefs_FRAMEWORKS += UIKit
TrollVNCPrefs_PRIVATE_FRAMEWORKS += Preferences
TrollVNCPrefs_INSTALL_PATH += /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
