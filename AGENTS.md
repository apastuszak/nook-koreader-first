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

- `helper/`: the companion APK. A Gradle project (AGP 9.5.0, Gradle wrapper 9.8.2) in plain Java with no third-party dependencies. Package and authority: `dev.nookwifi.helper`. `minSdk` and `targetSdk` are 27, `compileSdk` is 35.
  - The plugin's single entry point is `HelperProvider.call()`. `SetupActivity` (the launcher icon) exists only to request the location permission.
  - `helper/gradle.properties` sets `android.builtInKotlin=false`. Otherwise AGP 9 adds `kotlin-stdlib` and the APK grows from about 17 KB to about 650 KB. Keep the helper free of dependencies.
- `plugin/nookwifi.koplugin/`: the KOReader plugin. `nookwifihelper.lua` is the JNI client, and `main.lua` adds the menu under Settings → Network. It is named `nookwifi`, not `wifi`, to avoid clashing with a future built-in plugin.
- `spikes/`: Stage 0 throwaway test apps. Kept as evidence for the verified results above. They are not part of the product.
- `scripts/nook-recon.fish`: read-only device diagnostics. Its output is gitignored because it contains network names and addresses.
- `make build` builds the debug APK. `make check` runs Android lint, luacheck (configured in `.luacheckrc`), and the offline plugin tests in `plugin/tests/run.lua`. It does not touch the device. Run it before every install.
- `plugin/tests/jni.lua` runs the real JNI client (`nookwifihelper.lua`) against a fake `JNIEnv` that models raw JNI functions. It makes every step throw in turn, including method lookups and `GetStringUTFChars` allocation failure, and fails if a JNI call not allowed while an exception is pending (anything except `ExceptionCheck/Occurred/Clear`, `DeleteLocalRef` and `ReleaseStringUTFChars`) happens. The fake has no `call*Method`/`to_string` bridge, so any use of KOReader's unchecked helpers fails.
- **Test stand-ins must model real KOReader behavior.** Check the KOReader source at the version in use. For example, stock Android `turnOffWifi` opens Settings and runs its callback *immediately*. Stand-ins that were simpler than the real behavior hid bugs twice.
- `plugin/tests/run.lua` runs the plugin's real code against stand-ins for KOReader modules and the helper. It covers menu rendering (it evaluates every `text_func`/`checked_func`/`sub_item_table_func`), the polling flows, and the NetworkMgr hooks. Add tests there for new menu items and flows.
- luacheck is installed for LuaJIT: `luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --local luacheck`. The Lua 5.5 build does not run.
- `make install` installs the helper and pushes the plugin. KOReader loads plugin code only at startup, and on Android it has **no Restart option**, so the user must **Exit** KOReader and reopen it. `make install-helper` and `make install-plugin` do one each.
- `make ping` calls the helper over ADB. `make logs` follows `NookWifi` log lines. `make grant-location` runs the one-time `pm grant`. `make uninstall` removes both.
- Debug builds of the helper also accept the ADB shell (UID 2000) as a caller, so `adb shell content call --uri content://dev.nookwifi.helper --method <m> [--arg <a>]` can test helper methods without KOReader. On API 27, `content call` sends no calling package, so this check matches the UID instead. Release builds accept only the allowlist.
- Release signing: the key is `~/.android/nookwifi-release.jks` (alias `nookwifi`, RSA 4096, valid until 2054, certificate SHA-256 `86:F2:C3:6F:…:BA:24:15`). It is deliberately kept outside the repo. `helper/keystore.properties` (gitignored, mode 600) holds its path and password. **Never regenerate the key.** Every helper update must be signed with it, and the user keeps a backup. Debug and release signatures differ, so switching from one to the other requires uninstalling the helper first, which drops the location grant.
- `make release` builds the signed APK, and `make install-release` installs it. `make dist` runs `make check`, checks that the helper `versionName`, the plugin's `PLUGIN_VERSION`, and `_meta.lua`'s `version` all agree, verifies the signature, and writes `dist/nookwifi-helper-<v>.apk`, `dist/nookwifi.koplugin-<v>.zip` and `dist/SHA256SUMS`. To release, bump all three versions together (plus `versionCode`).
- Release builds are not debuggable, so they accept only KOReader as a caller; `make ping` returns `caller_not_allowed` against them.
- `README.md` is for end users (install, setup, use, limitations, privacy, update, removal, troubleshooting). Keep it in sync with behavior changes. Developer detail belongs here.
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

### Progress

- **Stage 0: done, verified on device** (see Confirmed environment).
- **Stage 1: done, verified on device** (2026-10-30). The repo, build, Makefile and helper `ping` work. The plugin's "Helper info" reaches the helper from KOReader.
- **Stage 2: done, verified on device** (2026-10-30, helper 0.2.0):
  - Helper methods: `getState` and `setEnabled` (arg `"true"`/`"false"`).
  - The plugin menu (Settings → Network → Nook Wi-Fi) has a status line (tap for details), a Wi-Fi checkbox, a shortcut to Android Wi-Fi settings, and Helper info.
  - The toggle polls `getState` every 0.5 s. It reports success only once Wi-Fi reaches the target state, and when turning on, only once it connects (20 s timeout for each step).
  - Verified in KOReader: status and details without location permission (network name shown as "(name hidden)", plus grant instructions); Wi-Fi off; Wi-Fi on with automatic reconnect; network name shown after `make grant-location`; "not installed" message after uninstalling the helper, with no crash; correct state after restarting KOReader.
  - Uninstalling the helper drops the location grant, so run `make grant-location` again after reinstalling.
  - A way to grant location without ADB was added in Stage 6 (`SetupActivity`).

- **Stage 3: done, verified on device** (2026-10-30, KOReader nightly `b44e9b7`):
  - `nookwifinetwork.lua` replaces `NetworkMgr.isWifiOn`, `turnOnWifi`, `turnOffWifi`, `getCurrentNetwork` and `getWifiMenuTable` once per session. It also sets `Device.hasSeamlessWifiToggle` to true when the helper responds.
  - Every override falls back to KOReader's original method when the helper cannot be reached. This was verified only offline, with stubbed KOReader modules; the fallback is not yet tested on the device.
  - `turnOnWifi` runs NetworkMgr's callback immediately, and NetworkMgr's own connectivity check then waits for the connection and broadcasts `NetworkConnected`. `turnOffWifi` waits up to 10 s for "disabled" before running its callback.
  - The plugin's own Wi-Fi checkbox now broadcasts `NetworkConnecting`/`NetworkConnected` and `NetworkDisconnecting`/`NetworkDisconnected`, so sync and other plugins see the change.
  - Verified in KOReader: Settings → Network shows a "Wi-Fi connection" checkbox (instead of "Wi-Fi settings") that toggles without leaving KOReader. With "Action when Wi-Fi is off: turn on", opening an OPDS catalog while Wi-Fi was off turned Wi-Fi on, and connected and validated in about 2.5 s. The "Toggle Wi-Fi" gesture works.
  - One OPDS attempt failed with `HTTP 504 Gateway Time-out` from `m.gutenberg.org`, *after* Wi-Fi had connected and validated. That was a server-side failure, not a timeout on our side. Do not lengthen plugin timeouts because of it.
  - The reference KOReader source for these hooks is `frontend/ui/network/manager.lua` and `frontend/device/android/device.lua` at commit `b44e9b7`. Check them again when the user updates KOReader.

- **Stage 4: done, verified on device** (2026-10-30, helper 0.3.0):
  - New helper methods:
    - `listSaved` returns saved networks with networkId, ssid, status, security, and signalLevel from the last scan. It works with Wi-Fi off; `scanAvailable` is false then, or without location permission.
    - `connectSaved` (arg networkId) calls `enableNetwork(id, true)` and then `reconnect()`.
    - `reconnect`.
    - `getState` now also returns `networkId`.
  - New plugin menu items: Reconnect, and Saved networks (radio list: current network first, then by signal, labelled "signal N/4" or "not in range"). Choosing a network, or Reconnect, turns Wi-Fi on first if needed.
  - Verified on device:
    - `enableNetwork(id, true)` starts a connection to any saved network, with no root needed. *Correction found in Stage 5:* the framework actually refuses the underlying permission ("UID 10051 does not have permission to update configuration"). The connection goes ahead only through `connectToUserSelectNetwork`'s "Allowing uid … with insufficient permissions to connect" path, so Android does not record it as the user's connect choice.
    - It does **not** permanently disable other saved networks; they stay "enabled".
    - Asking for an out-of-range network makes Android drop the current connection and fall back to another saved network within about 3 s. The plugin reports this immediately ("Could not connect to X. Connected to Y instead.") rather than waiting out the 20 s timeout.
  - Lint flags `getConfiguredNetworks`/`getScanResults` as needing `ACCESS_FINE_LOCATION`. That rule comes from newer APIs, so it is suppressed with a comment; on API 27 the Stage 0 results apply.
  - **Lessons from a crash in this stage:**
    - Never name a variable `_` in plugin code. It shadows gettext's `_`, and the next `_("…")` raises an error that takes down all of KOReader. luacheck ignores `_`, so only the offline tests catch this.
    - KOReader on this device writes no Lua traceback to logcat or `crash.log`. Its crash screen (`CrashReportActivity`) is the only place the error appears.

- **Stage 5: done, verified on device** (2026-10-30, helper 0.4.1):
  - New helper methods:
    - `scan` and `scanResults`: one entry per SSID with signalLevel, security, current, savedNetworkId. `fresh` becomes true once results newer than the scan request arrive (about 1 s on the Nook). Both return `location_permission_needed` rather than Android's silent empty list.
    - `join`: extras ssid/security/password. Returns `createdNetworkId`. Refuses SSIDs that are already saved (`already_saved` with `savedNetworkId`), so a typo can never overwrite a working password.
    - `forget`: only removes networks `join` created in this helper process; anything else gets `not_created_here`.
    - `getState.authFailed`: set from the `SUPPLICANT_STATE_CHANGED` broadcast with `ERROR_AUTHENTICATING`, and reset when a connect starts.
  - Supported security: open and WPA/WPA2-PSK (WPA2/WPA3 transition networks join as WPA2). WPA3-only (SAE), OWE, Enterprise (EAP) and WEP get an explicit "not supported, use Android settings" message.
  - Plugin flows:
    - "Scan for networks…" opens a full-screen `Menu` list.
    - A saved network connects directly; an open one joins with no password; WPA networks get an `InputDialog` with `text_type = "password"`.
    - A wrong password shows "Wrong password for X." and the plugin forgets the network it just created.
    - The "hold to forget" item in Saved networks was removed: the firmware refuses deleting networks the helper did not create.
  - **Firmware Wi-Fi permissions on this Nook** (verified in logcat; the helper's UID is 10051):
    - Add a network: allowed.
    - Connect to any saved network: goes ahead through "insufficient permissions to connect".
    - Change any saved network (`enableNetwork`'s update, or `addNetwork` with an existing configKey): **refused**, even for networks the helper created.
    - Remove a network the helper created: **allowed**.
    - Remove a network saved by the Nook (`com.nook.partner`) or Android settings: **refused**.
    - Consequence: a saved network whose password stops working cannot be fixed by the helper. The plugin detects `authFailed` on `connectSaved` and offers a button to Android Wi-Fi settings.
  - **Password handling (verified):** the password is sent only in `join`'s extras and never logged, stored, or echoed by the helper. KOReader's on-screen keyboard logs every character (`logger.dbg("add char", key)`), and KOReader also logs each touch with its coordinates, so the password dialog sets the logger to info level while open and restores it in `onCloseWidget`. On the device, with debug logging on, there were zero `add char` lines and no KOReader debug output at all while typing.
  - Verified on device: scan list; joining a WPA2 phone hotspot with the right password (connected in about 0.5 s); wrong password reported and the created network removed. Saved networks no longer claims "not in range".
  - Not tested on device: joining an open network, the unsupported-security message, and the Android-settings prompt for a saved network whose password fails. These are covered only by offline tests.
  - **Bugs found and fixed in this stage:**
    - `join` put the new network's ID in `networkId`, which `putState` then overwrote with the *current* connection's ID. The plugin waited for the wrong network and asked to forget the user's home network; only the firmware's refusal prevented the deletion. Hence `createdNetworkId`/`savedNetworkId`, and the helper-side `forget` guard.
    - Saved networks labelled networks "not in range" from Android's last scan. While connected, Android's background scans cover only some channels and replace the cached results, so an absent network may still be in range. The list now shows the current network's signal from the live connection, and others only when seen.
  - **Testing lessons:**
    - The fake helper in `plugin/tests/run.lua` must return replies shaped like the real helper's, including `putState`'s current-connection fields and the Nook dropping the old connection on `join`. A fake that was too simple let the `networkId` bug pass.
    - luacheck exits non-zero on warnings, so do not chain an install after `make check` with `| grep`. Check `make check`'s own exit status.

- **Stage 6: done, verified on device** (2026-10-30, release 1.0.0):
  - The release key was created, and `make dist` produces the signed APK (v2 signature scheme, not debuggable, 17 KB), the plugin zip, and checksums.
  - `SetupActivity` is a launcher screen with an "Allow location access" button. The plugin's permission messages point to it first, with the `adb shell pm grant` command as an alternative.
  - Helper info shows both versions.
  - Verified on device by installing exactly the `dist/` files after uninstalling the debug helper:
    - status without permission
    - granting through the setup screen (readable on e-ink)
    - network name shown afterwards
    - Helper info shows 1.0.0 for both
    - Wi-Fi off/on and scanning
    - the release build rejects the ADB shell
- **Release 1.0.1: code review and security audit** (2026-10-30). Installed on the device as an update over 1.0.0; the location grant was kept.
  - Bugs fixed, each with a test that fails on 1.0.0:
    - `join`'s `already_saved` path passed `finish` as the failure callback, so `"auth"` was broadcast as an event name. Both paths now share `connectSavedStep`.
    - `awaitNetwork` treated any brief connection to another network after a drop as a failure. Right after Wi-Fi turns on, Android can autojoin another saved network before switching (`enableNetwork` does not record a user choice on this firmware). A connection elsewhere must now last `FALLBACK_GRACE_S` (4 s).
    - `authFailed` was not tied to a network. The helper now records `authFailedNetworkId` (from `WifiInfo` when the broadcast arrives), and the plugin ignores failures known to be for another network; -1 means unknown and still counts.
    - The `turnOffWifi` hook kept polling after a rejection and then reported Wi-Fi off. It now falls back to stock behavior.
    - `nookwifihelper.lua` skipped exception checks between `FindClass`, `NewObject`, `putString` and `getContentResolver`. It now checks after every JNI call (`tests/jni.lua`).
    - `HelperProvider.call` called `getCallingPackage()` outside its `try`, so a `SecurityException` could escape. It now maps to `caller_not_allowed`.
    - `SetupActivity` had no way out after "Don't ask again". The button now opens the app's Android settings page.
  - Declined from the review:
    - Routing the plugin's own toggle through NetworkMgr: the plugin's version reports real results, and the skipped bookkeeping (`wifi_was_on`) only matters for auto-restore, which Android does not have.
    - Avoiding the two helper calls at startup: about 16 ms warm, at most about 100 ms cold.
  - Security audit results:
    - The provider's allowlist relies on Android verifying `getCallingPackage()` against the UID; the other provider methods are no-ops; the shell exception exists only in debug builds.
    - `SUPPLICANT_STATE_CHANGED` is a protected broadcast. Passwords travel only in extras and are never logged.
    - Scanned SSIDs are displayed safely: KOReader's `T()` does not re-expand inserted text.
    - The helper has no dependencies, and the release key is outside the repo.
    - `gradle-wrapper.properties` now pins `distributionSha256Sum`, and the committed `gradle-wrapper.jar` matches Gradle's published checksum.
  - Fixed after Codex's review of the same tree:
    - The `turnOffWifi` hook still ran NetworkMgr's callback (broadcasting `NetworkDisconnected`) after a polling error or the 10 s timeout. It now runs it only once Wi-Fi reports disabled. A lost helper falls back to stock behavior, and a timeout just calls `queryNetworkState()`.
    - `awaitNetwork` sent polling errors to `finish`, bypassing `join`'s cleanup of the network it created. They now go to `fail`.
    - **Security:** scan results and saved networks were matched by SSID only. With an open and a WPA network of the same name nearby, choosing the WPA row could connect the saved *open* profile (an "evil twin" risk), and `join` could report `already_saved` for the wrong profile. The helper now keys both by SSID plus security (like Android's configKey). `current` compares network IDs. This is a helper-side Java fix, verified by reading the code only: no offline test, and no same-name networks were available on the device.
    - The scan list's "Already connected" check used the flag from scan time; it now checks the live connection. In real KOReader the list closes on selection, so this was mostly theoretical.
  - Accepted risks, documented in the README:
    - Anything running inside KOReader (other plugins, patches) can use the helper, including reading nearby SSIDs, which can reveal roughly where the user is.
    - If KOReader were uninstalled, another app could take its package name. Pinning KOReader's signature would block that but break nightly and F-Droid builds, which use different keys.
- **Release 1.0.2** (2026-10-30, verified on device: Helper info, status, Wi-Fi off/on through both the plugin and KOReader's toggle, switching saved networks, scanning). Fixes from Codex's review of 1.0.1:
  - The `turnOffWifi` fallback (after a rejection or losing the helper) passed NetworkMgr's callback to stock `turnOffWifi`, which runs it right after opening Settings and so broadcast `NetworkDisconnected` while Wi-Fi was still on. `openSettingsOnly` now opens Settings without the callback and refreshes `queryNetworkState()`. A helper that is not installed at all still gets exact stock behavior.
  - `awaitNetwork` checked the retained `authFailed` before checking for success, so a transient auth failure followed by a successful connection reported "Wrong password" and removed a working network. Success is now checked first, and an auth failure must persist for `AUTH_GRACE_S` (3 s) without the requested network connecting.
  - **`nookwifihelper.lua` no longer uses KOReader's `jni:call*Method` or `jni:to_string`.** Those chain `FindClass`/`GetObjectClass`, `Get*MethodID`, the call and `DeleteLocalRef` without checking for exceptions, and `to_string` does not check `GetStringUTFChars` for NULL. The client now uses raw JNI functions with a check after each call, inside a `pcall` within the JNI context so the thread is always detached. Keep it that way.
- **Release 1.0.3** (2026-10-30). Fix from Codex's review of 1.0.2: the `turnOffWifi` hook used stock behavior (which runs the callback at once) for *every* failed first call. **Rule: only `helper_not_installed` gets exact stock behavior.** Other helper failures (`jni_error`, `bad_reply`, `protocol_mismatch`, a rejection, losing the helper mid-way) go through `openSettingsOnly`, so KOReader is never told Wi-Fi is off while it may be on. The normal paths are unchanged; the fix is covered by offline tests that fail on 1.0.2.
- **Next (optional, user's choice):** the minimal Home launcher described under Scope boundaries. The user agreed to do it after Stage 6. It must be a separate APK, needs the user's explicit go-ahead before it is made the default launcher, a tested way back to Olauncher, and a guard against relaunch loops if KOReader crashes or is missing. It can be signed with the same release key.

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
