# Build, install, and debug the Nook Wi-Fi helper APK and KOReader plugin.
# Device targets expect exactly one device connected over USB.

JAVA_HOME ?= /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
ANDROID_HOME ?= /opt/homebrew/share/android-commandlinetools
export JAVA_HOME ANDROID_HOME
# Installed with: luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --local luacheck
LUACHECK ?= $(HOME)/.luarocks/bin/luacheck

HELPER_PKG := dev.nookwifi.helper
APK := helper/app/build/outputs/apk/debug/app-debug.apk
RELEASE_APK := helper/app/build/outputs/apk/release/app-release.apk
PLUGIN := plugin/nookwifi.koplugin
DEVICE_PLUGINS := /sdcard/koreader/plugins
# Helper and plugin share one version number; dist checks they agree.
VERSION := $(shell sed -n 's/.*versionName = "\(.*\)"/\1/p' helper/app/build.gradle.kts)
PLUGIN_VERSION := $(shell sed -n 's/^local PLUGIN_VERSION = "\(.*\)"/\1/p' $(PLUGIN)/main.lua)
APKSIGNER = $(ANDROID_HOME)/build-tools/$(shell ls $(ANDROID_HOME)/build-tools | sort -V | tail -1)/apksigner
DIST := dist

.PHONY: build check install install-helper install-plugin grant-location ping logs uninstall clean \
	release install-release dist

build:
	cd helper && ./gradlew --console=plain assembleDebug

# Lint plus offline tests; nothing here touches the device.
check:
	cd helper && ./gradlew --console=plain lint
	$(LUACHECK) --no-color $(PLUGIN) plugin/tests
	luajit plugin/tests/run.lua

install: install-helper install-plugin

install-helper: build
	adb install -r $(APK)

# Restart KOReader afterwards to load the new plugin code.
install-plugin:
	adb shell rm -rf $(DEVICE_PLUGINS)/nookwifi.koplugin
	adb push $(PLUGIN) $(DEVICE_PLUGINS)/

# One-time grant needed for scan results and the current SSID.
grant-location:
	adb shell pm grant $(HELPER_PKG) android.permission.ACCESS_COARSE_LOCATION

# Calls the helper directly; debug builds accept the adb shell as a caller.
ping:
	adb shell content call --uri content://$(HELPER_PKG) --method ping

logs:
	adb logcat -v time | grep --line-buffered NookWifi

uninstall:
	-adb uninstall $(HELPER_PKG)
	adb shell rm -rf $(DEVICE_PLUGINS)/nookwifi.koplugin

clean:
	cd helper && ./gradlew --console=plain clean

# Signed release APK. Needs helper/keystore.properties (never committed) pointing
# at the release key. Release builds accept only KOReader as a caller, so
# `make ping` does not work against them.
release:
	@test -f helper/keystore.properties || { echo "helper/keystore.properties is missing (see AGENTS.md)"; exit 1; }
	cd helper && ./gradlew --console=plain assembleRelease

# Debug and release are signed with different keys, so switching between them
# needs `make uninstall` first (which also drops the location grant).
install-release: release
	adb install -r $(RELEASE_APK)

# Everything a user needs: signed APK, plugin zip, checksums.
dist: check release
	@test "$(VERSION)" = "$(PLUGIN_VERSION)" || { echo "Version mismatch: helper $(VERSION), plugin $(PLUGIN_VERSION)"; exit 1; }
	grep -q 'version = "$(VERSION)"' $(PLUGIN)/_meta.lua || { echo "_meta.lua version is not $(VERSION)"; exit 1; }
	$(APKSIGNER) verify $(RELEASE_APK)
	rm -rf $(DIST) && mkdir -p $(DIST)
	cp $(RELEASE_APK) $(DIST)/nookwifi-helper-$(VERSION).apk
	cd plugin && zip -qrX ../$(DIST)/nookwifi.koplugin-$(VERSION).zip nookwifi.koplugin -x '*.DS_Store'
	cd $(DIST) && shasum -a 256 *.apk *.zip > SHA256SUMS
	@ls -la $(DIST)
