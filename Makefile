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
LAUNCHER_PKG := dev.nookkoreader.launcher
LAUNCHER_APK := launcher/app/build/outputs/apk/release/app-release.apk
LAUNCHER_VERSION := $(shell sed -n 's/.*versionName = "\(.*\)"/\1/p' launcher/app/build.gradle.kts)
PLUGIN := plugin/nookwifi.koplugin
DEVICE_PLUGINS := /sdcard/koreader/plugins
# KOReader patch that returns to Home when KOReader exits (part of the launcher).
HOME_PATCH := launcher/patch/2-koreader-home.lua
DEVICE_PATCHES := /sdcard/koreader/patches
# Helper and plugin share one version number; dist checks they agree.
VERSION := $(shell sed -n 's/.*versionName = "\(.*\)"/\1/p' helper/app/build.gradle.kts)
PLUGIN_VERSION := $(shell sed -n 's/^local PLUGIN_VERSION = "\(.*\)"/\1/p' $(PLUGIN)/main.lua)
APKSIGNER = $(ANDROID_HOME)/build-tools/$(shell ls $(ANDROID_HOME)/build-tools | sort -V | tail -1)/apksigner
DIST := dist
# SHA-256 of the release signing certificate (~/.android/nookwifi-release.jks).
# Every release must be signed with this key, or updates fail to install.
RELEASE_CERT_SHA256 := 86f2c36fd0268087a23c5cd8b748720e97d476697fca0cc75eca0f2127ba2415

.PHONY: build check install install-helper install-plugin grant-location ping logs uninstall clean \
	release install-release dist

build:
	cd helper && ./gradlew --console=plain assembleDebug

# Lint plus offline tests; nothing here touches the device.
check: check-launcher
	cd helper && ./gradlew --console=plain lint testDebugUnitTest
	$(LUACHECK) --no-color $(PLUGIN) plugin/tests
	luajit plugin/tests/run.lua
	luajit plugin/tests/jni.lua

install: install-helper install-plugin

install-helper: build
	adb install -r $(APK)

# Restart KOReader afterwards to load the new plugin code.
# adb push does not create a missing destination folder, and KOReader creates
# neither plugins/ nor patches/ until something is put there.
install-plugin:
	adb shell rm -rf $(DEVICE_PLUGINS)/nookwifi.koplugin
	adb shell mkdir -p $(DEVICE_PLUGINS)
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
	cd launcher && ./gradlew --console=plain clean

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
dist: check release release-launcher
	@test "$(VERSION)" = "$(PLUGIN_VERSION)" || { echo "Version mismatch: helper $(VERSION), plugin $(PLUGIN_VERSION)"; exit 1; }
	grep -q 'version = "$(VERSION)"' $(PLUGIN)/_meta.lua || { echo "_meta.lua version is not $(VERSION)"; exit 1; }
	$(APKSIGNER) verify $(RELEASE_APK)
	@$(APKSIGNER) verify --print-certs $(RELEASE_APK) 2>/dev/null | grep -q 'certificate SHA-256 digest: $(RELEASE_CERT_SHA256)' \
		|| { echo "APK is not signed with the release key ($(RELEASE_CERT_SHA256))"; exit 1; }
	$(APKSIGNER) verify $(LAUNCHER_APK)
	@$(APKSIGNER) verify --print-certs $(LAUNCHER_APK) 2>/dev/null | grep -q 'certificate SHA-256 digest: $(RELEASE_CERT_SHA256)' \
		|| { echo "Launcher APK is not signed with the release key"; exit 1; }
	rm -rf $(DIST) && mkdir -p $(DIST)
	cp $(RELEASE_APK) $(DIST)/nookwifi-helper-$(VERSION).apk
	cp $(LAUNCHER_APK) $(DIST)/koreader-home-$(LAUNCHER_VERSION).apk
	cp $(HOME_PATCH) $(DIST)/
	cd plugin && zip -qrX ../$(DIST)/nookwifi.koplugin-$(VERSION).zip nookwifi.koplugin -x '*.DS_Store'
	cd $(DIST) && shasum -a 256 *.apk *.zip *.lua > SHA256SUMS
	@ls -la $(DIST)

# Separate optional launcher. None of these targets changes the default Home app.
.PHONY: build-launcher check-launcher release-launcher install-launcher install-launcher-patch launcher-recovery \
	uninstall-launcher logs-launcher
build-launcher:
	cd launcher && ./gradlew --console=plain assembleDebug

check-launcher:
	cd launcher && ./gradlew --console=plain lint testDebugUnitTest
	$(LUACHECK) --no-color launcher/patch
	luajit launcher/patch/test.lua

release-launcher:
	@test -f helper/keystore.properties || { echo "helper/keystore.properties is missing"; exit 1; }
	cd launcher && ./gradlew --console=plain assembleRelease

install-launcher: check release-launcher
	adb install -r $(LAUNCHER_APK)
	adb shell mkdir -p $(DEVICE_PATCHES)
	adb push $(HOME_PATCH) $(DEVICE_PATCHES)/

# Only the KOReader patch; KOReader loads it at its next start.
install-launcher-patch:
	adb shell mkdir -p $(DEVICE_PATCHES)
	adb push $(HOME_PATCH) $(DEVICE_PATCHES)/

launcher-recovery:
	adb shell am start -n $(LAUNCHER_PKG)/.RecoveryActivity

uninstall-launcher:
	-adb uninstall $(LAUNCHER_PKG)
	adb shell rm -f $(DEVICE_PATCHES)/$(notdir $(HOME_PATCH))

logs-launcher:
	adb logcat -v time | grep --line-buffered -E 'KOReaderHome|KEYCODE_HOME'
