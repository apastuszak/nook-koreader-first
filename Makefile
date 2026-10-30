# Build, install, and debug the Nook Wi-Fi helper APK and KOReader plugin.
# Device targets expect exactly one device connected over USB.

JAVA_HOME ?= /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
ANDROID_HOME ?= /opt/homebrew/share/android-commandlinetools
export JAVA_HOME ANDROID_HOME

HELPER_PKG := dev.nookwifi.helper
APK := helper/app/build/outputs/apk/debug/app-debug.apk
PLUGIN := plugin/nookwifi.koplugin
DEVICE_PLUGINS := /sdcard/koreader/plugins

.PHONY: build check install install-helper install-plugin grant-location ping logs uninstall clean

build:
	cd helper && ./gradlew --console=plain assembleDebug

# Static checks only; nothing here touches the device.
check:
	cd helper && ./gradlew --console=plain lint
	@for f in $(PLUGIN)/*.lua; do luajit -bl $$f >/dev/null && echo "syntax ok: $$f"; done

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
