# KOReader Wi-Fi controls for Nook GlowLight 4 Plus

This file is the single source of project guidance for all coding agents (Codex, Claude Code, and others). CLAUDE.md only imports it. When project decisions or verified device details change, update this file; do not add guidance to agent-specific files.

## Objective

Build a KOReader plugin that lets the user turn Wi-Fi on and off on demand and join Wi-Fi networks from within KOReader on a Barnes & Noble Nook GlowLight 4 Plus.

The desired experience is to manage connectivity without returning to the stock Nook home screen. Start with Wi-Fi on/off and reconnecting to saved networks, then add scanning, network selection, and password entry.

## Confirmed environment

- Device: Nook GlowLight 4 Plus.
- Android version: **8.1.0**.
- Android SDK/API level: **27**.
- Both values were verified by the user through ADB:
  - `adb shell getprop ro.build.version.release` → `8.1.0`
  - `adb shell getprop ro.build.version.sdk` → `27`
- ADB is enabled and works from the user's Mac over USB.
- The details below were collected on 2026-10-30 with `scripts/nook-recon.fish`:
  - Model `BNRV1300`, firmware `8.1.7.120_user`, fingerprint `NOOK/E70P74_android/E70P74_android:8.1.0/b3b5739/8.1.7.120_user:user/release-keys`.
  - Not rooted: user build, `ro.debuggable=0`, `ro.secure=1`, no `su` binary. Do not require root.
  - KOReader: package `org.koreader.launcher`, nightly `v2026.07.2-217-gb44e9b7_2026-10-03`, `targetSdk=30`. It does **not** declare `CHANGE_WIFI_STATE` or `ACCESS_WIFI_STATE`, so a helper APK is required for Wi-Fi control.
  - Default launcher: Olauncher (`app.olauncher`). Stock Nook packages such as `bn.ereader` and `com.bn.nook.hub` are still installed.
  - Location: `location_providers_allowed=network`, but there is no network location provider (no GMS/NLP). Only `fused` and `passive` exist, and `fused` reports disabled. Do not rely on working location services.
  - `adb shell svc wifi disable/enable` toggles Wi-Fi in about 1–2 s, and the firmware does not revert it. This uses ADB shell privileges and does not prove a normal app can toggle Wi-Fi.
  - **Stage 0 Test 1, verified on device on 2026-10-30** (`spikes/wifi-toggle`, a normal app with `targetSdk=27`):
    - Installing grants `CHANGE_WIFI_STATE` and `ACCESS_WIFI_STATE` automatically. No root or ADB privileges are needed.
    - `setWifiEnabled(false)` reached DISABLED in about 0.6 s. `setWifiEnabled(true)` reached ENABLED in about 1 s and reconnected to the saved network automatically after about 3.6 s. The firmware did not interfere and showed no popup.
    - `getConfiguredNetworks()` returns saved networks (SSID, networkId, status) without location permission.
    - Without `ACCESS_COARSE_LOCATION`, `startScan()` returns true but `getScanResults()` returns an **empty list** with no exception, and `getConnectionInfo().getSSID()` returns `<unknown ssid>`. Holding `CHANGE_WIFI_STATE` alone is not enough, despite what Android's docs say about 8.0/8.1.
    - With `ACCESS_COARSE_LOCATION` granted through the runtime dialog, the scan returned 11 networks and the current SSID was visible. The missing location provider does not matter. Untested: behavior if the user switches location off in Settings.
  - **Stage 0 Test 2, verified on device on 2026-10-30** (`spikes/helper-call`: stub helper APK plus `wifispike.koplugin`):
    - A KOReader plugin can call another app's exported `ContentProvider` through `ContentResolver.call()` over JNI (`android.jni:context(android.app.activity.vm, ...)`, using `android.app.activity.clazz` as the Context).
    - This works even when the helper was never launched (installed, `stopped=true`, no activity). The first call took 84 ms including a cold process start; warm calls take about 7–9 ms.
    - The helper sees `getCallingPackage() = org.koreader.launcher` (uid 10046), so a caller allowlist is feasible.
    - Strings round-trip correctly in both `arg` and a JNI-built `Bundle` of extras, including non-ASCII BMP text and emoji (non-BMP).
    - Exceptions thrown in the helper (`IllegalStateException`) and a missing helper (`IllegalArgumentException: Unknown URI`) arrive as pending JNI exceptions. The plugin checks for them, clears them, and reports them, and KOReader keeps working. **KOReader's JNI helpers never check for exceptions, so the plugin must do this after every call that can throw.**
  - User plugins live in `/sdcard/koreader/plugins/` and user patches in `/sdcard/koreader/patches/`. The user already runs several third-party plugins and `2-*.lua` patches.

## Build environment (user's Mac)

Installed with Homebrew on 2026-10-30:

- JDK 21 for Android builds: `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`. The default `java` on PATH is Corretto 27, which is too new for the Android Gradle Plugin. Do not use it for builds. JDK 11 is also installed and is too old.
- Gradle 9.8.2 (`gradle` on PATH). Use it only to generate a Gradle wrapper, then build with `./gradlew`.
- Android SDK root: `/opt/homebrew/share/android-commandlinetools` (installed from the `android-commandlinetools` cask). The user has accepted the SDK licenses. Installed packages: `platforms;android-27`, `platforms;android-35`, `build-tools;35.0.0`.
- `adb` comes from the `android-platform-tools` cask.
- `ANDROID_HOME` and `JAVA_HOME` are not set in the user's shell. The `Makefile` sets both (override either from the environment if needed), so build through `make`. To run `./gradlew` directly, export them first.

## Repository layout and commands

- `helper/`: the companion APK. A Gradle project (AGP 9.5.0, Gradle wrapper 9.8.2) in plain Java with no third-party dependencies. Package and authority: `dev.nookwifi.helper`. `minSdk` and `targetSdk` are 27, `compileSdk` is 35. The single entry point is `HelperProvider.call()`.
- `plugin/nookwifi.koplugin/`: the KOReader plugin. `nookwifihelper.lua` is the JNI client, and `main.lua` adds the menu under Settings → Network. It is named `nookwifi`, not `wifi`, to avoid clashing with a future built-in plugin.
- `spikes/`: Stage 0 throwaway test apps. Kept as evidence for the verified results above. They are not part of the product.
- `scripts/nook-recon.fish`: read-only device diagnostics. Its output is gitignored because it contains network names and addresses.
- `make build` builds the debug APK. `make check` runs lint and Lua syntax checks and does not touch the device.
- `make install` installs the helper and pushes the plugin (restart KOReader to load it). `make install-helper` and `make install-plugin` do one each.
- `make ping` calls the helper over ADB. `make logs` follows `NookWifi` log lines. `make grant-location` runs the one-time `pm grant`. `make uninstall` removes both.
- Debug builds of the helper also accept the ADB shell (UID 2000) as a caller, so `adb shell content call --uri content://dev.nookwifi.helper --method <m> [--arg <a>]` can test helper methods without KOReader. On API 27, `content call` sends no calling package, so this check matches the UID instead. Release builds accept only the allowlist.
- Release signing reads `helper/keystore.properties` (gitignored). No release key exists yet; create it in Stage 6. Debug and release signatures differ, so switching from one to the other requires uninstalling the helper first.
- `sdkmanager` prints a deprecation notice that recommends the new `android sdk` CLI. `sdkmanager` still works.

## Proposed architecture

Use a Lua KOReader plugin for the user interface and, if needed, a small Android companion APK for privileged Android API access.

Android 8.1 exposes Wi-Fi APIs for toggling Wi-Fi and configuring networks. A companion app declaring the appropriate permissions should be able to use these without root, but this has **not been tested on this Nook**. Verify behavior rather than assuming standard Android behavior applies unchanged.

A Lua plugin cannot add manifest permissions to the installed KOReader APK. Inspect KOReader's existing Android bridge and permissions before deciding whether a helper is necessary. Avoid requiring a custom KOReader build if a separate helper can provide the required capabilities.

Plugin ↔ helper communication (decided after Stage 0 Test 2): the helper exposes an exported `ContentProvider`, and the plugin uses only `ContentResolver.call(uri, method, arg, extras)` over JNI. Each reply is a `Bundle` holding a single `json` string, which the plugin decodes with KOReader's `require("json")`. The helper accepts a fixed set of method names, rejects anything else with `{"ok":false,"error":"unknown_method"}`, and checks `getCallingPackage()` against an allowlist of KOReader package names. Do not assume shell commands executed by KOReader have ADB shell privileges.

## Implementation stages

1. Inspect the current KOReader Android integration, plugin APIs, manifest permissions, and device firmware details. Establish how a plugin can invoke the companion and receive results.
2. Build a minimal helper and plugin to query Wi-Fi state and enable/disable Wi-Fi. Test on the actual device.
3. Support reconnecting to saved networks and display connection state.
4. Add scanning, network selection, and password entry for joining networks. Implement common personal networks first; explicitly handle unsupported security types.
5. Package the plugin and a signed, installable helper APK with concise setup, update, and removal instructions.

Complete useful implementation work autonomously. Ask the user for device checks or decisions only when needed. Do not claim device behavior is verified until it has actually been tested.

## Android considerations

- Investigate `WifiManager` APIs appropriate for API 27, including `isWifiEnabled`, `setWifiEnabled`, configured networks, scans, and network configuration/connection.
- Declare only the permissions required, likely including `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, and location permission for scanning. Verify exact requirements against Android documentation.
- Scanning on Android 8.1 may require runtime location permission and enabled location services. Handle denials and disabled services with actionable messages.
- Handle Wi-Fi state transitions asynchronously, using actual state and connection results rather than reporting success immediately after a request is accepted.
- Include timeouts and useful error reporting for Nook firmware restrictions.
- Wi-Fi network configuration APIs contain deprecated methods that remain relevant to API 27. Do not replace them with APIs available only on newer Android versions.
- Keep the helper interface restricted to the intended Wi-Fi operations; do not expose arbitrary command execution. Avoid logging passwords or retaining them in plugin settings. Account for the fact that separate Android apps cannot simply share private files.

## User interface

- Use KOReader-native menus/dialogs where practical.
- Favor simple text controls suitable for an e-ink screen.
- Show current Wi-Fi state and connection information.
- Provide an on/off control, reconnect action, and eventually a network picker and password dialog.
- Keep error and permission messages short and understandable.
- A shortcut to Android Wi-Fi settings is a useful fallback. Existing KOReader Android behavior reportedly opens system Wi-Fi settings instead of directly toggling Wi-Fi; verify this in the installed/current version.

## Scope boundaries

- Primary scope is Wi-Fi management from KOReader.
- Earlier discussion considered a minimal Android Home launcher that immediately opens KOReader whenever Home is invoked, with a hidden route to settings/recovery. The user already has a launcher; building a replacement launcher is **optional future work**, not a requirement for this Wi-Fi project.
- A helper could eventually be combined with such a launcher, but do not couple the initial implementation to that idea.
- Do not disable or uninstall the stock Nook software, change the default launcher, root the device, flash firmware, or reset network settings as part of routine development.

## Validation and deliverables

- Provide source code, reproducible build instructions, a plugin installation directory/archive, and an installable signed helper APK when the build environment permits.
- Document required permissions and any one-time device setup.
- Verify on-device: state query; Wi-Fi off; Wi-Fi on; saved-network reconnection; plugin behavior after reopening KOReader; permission denial; and helper unavailable.
- For network joining, verify scan results, successful connection, incorrect password, and timeout behavior.
- Distinguish local build/static verification from actual hardware testing in progress reports and final instructions.
- Use ADB for installation and diagnostics with user cooperation. Never record Wi-Fi passwords in repository files or diagnostic output.

## Starting references

Read current primary sources before choosing APIs or integration details:

- Android `WifiManager`: https://developer.android.com/reference/android/net/wifi/WifiManager
- KOReader source: https://github.com/koreader/koreader
- KOReader Android launcher/bridge: https://github.com/koreader/android-luajit-launcher
- KOReader Android Wi-Fi feature discussion: https://github.com/koreader/koreader/issues/16184

The issue above was identified during preliminary research. Treat its contents and status as something to inspect, not as proof that the installed KOReader has or lacks a particular feature.
