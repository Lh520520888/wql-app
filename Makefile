ARCHS := arm64e arm64
# latest = 用当前 Xcode 自带的 iPhoneOS SDK（CI 上不用预装特定版本）
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WQLApp

WQLApp_FILES = \
	main.m \
	WQLAppDelegate.m \
	WQLViewController.m \
	WQLEscape.m \
	WQLLog.m \
	WQLPathLeak.m \
	WQLPathCache.m \
	WQLKeepAlive.m \
	WQLTargets.m \
	WQLScanner.m \
	WQLUploader.m \
	WQLZip.m

WQLApp_FRAMEWORKS = UIKit Foundation AVFoundation
WQLApp_RESOURCE_DIRS = Resources
WQLApp_CFLAGS = -fobjc-arc -O2 -Wall \
	-Wno-unused-parameter -Wno-deprecated-declarations -Wno-unused-function \
	-Wno-unused-variable
# ldid 只认 -S<entitlements>（不能写成 codesign 的 --entitlements）
WQLApp_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist
WQLApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

ipa: all
	@echo "==> 打包 IPA"
	rm -rf $(THEOS_PROJECT_DIR)/.ipa && mkdir -p $(THEOS_PROJECT_DIR)/.ipa/Payload
	cp -R $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app $(THEOS_PROJECT_DIR)/.ipa/Payload/
	cd $(THEOS_PROJECT_DIR)/.ipa && zip -qry $(THEOS_PROJECT_DIR)/$(APPLICATION_NAME).ipa Payload
	@echo "==> 产物: $(THEOS_PROJECT_DIR)/$(APPLICATION_NAME).ipa"

.PHONY: ipa
