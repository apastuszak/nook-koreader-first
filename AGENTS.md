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

- License: **AGPL-3.0-or-later**, the same as KOReader (`LICENSE`, plus a section in the README). New code in this repo, including the launcher, is under the same license. Do not copy code from projects with incompatible or missing licenses (e.g. AnyLauncher, which has none).

- `helper/`: the companion APK. A Gradle project (AGP 9.5.0, Gradle wrapper 9.8.2) in plain Java with no third-party dependencies. Package and authority: `dev.nookwifi.helper`. `minSdk` and `targetSdk` are 27, `compileSdk` is 35.
  - The plugin's single entry point is `HelperProvider.call()`. `SetupActivity` (the launcher icon) exists only to request the location permission.
  - `helper/gradle.properties` sets `android.builtInKotlin=false`. Otherwise AGP 9 adds `kotlin-stdlib` and the APK grows from about 17 KB to about 650 KB. Keep the helper free of dependencies.
- `plugin/nookwifi.koplugin/`: the KOReader plugin. `nookwifihelper.lua` is the JNI client, and `main.lua` adds the menu under Settings → Network. It is named `nookwifi`, not `wifi`, to avoid clashing with a future built-in plugin.
- `spikes/`: Stage 0 throwaway test apps. Kept as evidence for the verified results above. They are not part of the product.
- `scripts/nook-recon.fish`: read-only device diagnostics. Its output is gitignored because it contains network names and addresses.
- `make build` builds the debug APK. `make check` runs Android lint, the helper's JVM unit tests (`helper/app/src/test`, JUnit as a test-only dependency), luacheck (configured in `.luacheckrc`), and the offline plugin tests in `plugin/tests/run.lua` and `plugin/tests/jni.lua`.
- Helper logic with no Android dependencies lives in `NetworkRules` (network keys, security parsing, password rules, SSID quoting) and `CreatedNetworks` (forget's ownership records), so it can be unit-tested on the JVM. Put new pure logic there rather than in `WifiOps`. It does not touch the device. Run it before every install.
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
  - `nookwifinetwork.lua` replaces `NetworkMgr.isWifiOn`, `turnOnWifi`, `turnOffWifi` and `getWifiMenuTable` once per session, and makes `Device.hasSeamlessWifiToggle` check the helper live. (Until 1.0.4 it also replaced `getCurrentNetwork` and set seamless once; see 1.0.4.)
  - Every override falls back to KOReader's original method when the helper cannot be reached. This was verified only offline, with stubbed KOReader modules; the fallback is not yet tested on the device.
  - `turnOnWifi` runs NetworkMgr's callback immediately, and NetworkMgr's own connectivity check then waits for the connection and broadcasts `NetworkConnected`. `turnOffWifi` waits up to 10 s for "disabled" before running its callback.
  - The plugin's own Wi-Fi checkbox now broadcasts `NetworkConnecting`/`NetworkConnected` and `NetworkDisconnecting`/`NetworkDisconnected`, so sync and other plugins see the change.
  - Verified in KOReader: Settings → Network shows a "Wi-Fi connection" checkbox (instead of "Wi-Fi settings") that toggles without leaving KOReader. With "Action when Wi-Fi is off: turn on", opening an OPDS catalog while Wi-Fi was off turned Wi-Fi on, and connected and validated in about 2.5 s. The "Toggle Wi-Fi" gesture works.
  - One OPDS attempt failed with `HTTP 504 Gateway Time-out` from `m.gutenberg.org`, *after* Wi-Fi had connected and validated. That was a server-side failure, not a timeout on our side. Do not lengthen plugin timeouts because of it.
  - The reference KOReader source for these hooks is `frontend/ui/network/manager.lua` and `frontend/device/android/device.lua` at commit `b44e9b7`. Check them again when the user updates KOReader.

- **Stage 4: done, verified on device** (2026-10-30, helper 0.3.0):
  - New helper methods:
    - `listSaved` returns saved networks with networkId, ssid, status, security, and signalLevel from the last scan. It works with Wi-Fi off; `scanAvailable` is false then, or without location permission.
    - `connectSaved` (arg networkId) calls `enableNetwork(id, true)`, which starts the connection by itself. Until 1.0.4 it also called `reconnect()`; see 1.0.4.
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
    - `forget`: only removes a network whose SSID and security match one `join` created in the last 10 minutes (recorded on disk since 1.0.4); anything else gets `not_created_here`.
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
- **Release 1.0.4** (2026-10-30). Verified on device:
  - wrong password, after which the created network was removed through the on-disk record
  - right password, connecting without `reconnect()`
  - switching home → hotspot → home, each a single `connectSaved` with no fallback
  - Wi-Fi off/on through KOReader's toggle, with the message kept up until connected
  - no stale-lease reconnects in logcat

  Fixes from Claude's review of 1.0.3:
  - **`getCurrentNetwork` is no longer overridden.** Returning an SSID armed KOReader's `hasLeaseForCurrentNetwork`, which compares it with `lease_ssid`. That field is set only by NetworkMgr's own connectivity checks, so connections made at startup, by Android or by the plugin looked like stale leases and forced reconnects. Stock Android returns nil, which means "unknown, do not disrupt".
  - **Helper state survives process death.** The scan request time and the networks `join` created are kept in SharedPreferences (written with `commit()`, synchronously). Created networks are recorded as `<time>|<networkKey>`, never by networkId, because IDs are reassigned when Android loads saved networks at boot; a stored ID could later name another network. `authFailed` still lives only in memory: if the process dies mid-join, the plugin reports a timeout instead of a wrong password.
  - **No `reconnect()` after `enableNetwork(id, true)`** in `connectSaved` and `join`. It forced a scan and a fresh network selection, which could pick another saved network because no user choice is recorded. This is a likely cause of the earlier "brief autojoin"; `FALLBACK_GRACE_S` stays as a safety net.
  - **`NetworkConnected` is broadcast** when a flow that announced `NetworkConnecting` ends connected to any network, including after a fallback.
  - **`hasSeamlessWifiToggle` checks the helper live,** and a background `turnOffWifi` (NetworkMgr's `_abortWifiConnection` passes no callback) never opens Android Settings.
  - A null check on `getConnectionInfo()` in `scanResults`.
  - `SetupActivity` treats an interrupted request (empty results) as "not denied".
  - **`make dist` checks the APK's signing certificate** against `RELEASE_CERT_SHA256`. Tested: a wrong fingerprint fails the build.
  - `networkKey` is now `security + "|" + ssid`. *Correction (found writing 1.0.5's unit tests):* this was described as a security fix, but the old `ssid + NUL + security` key could not collide either. Security comes from a fixed set with no NUL, so the part after the last NUL always identified it. The change is cosmetic.
  - **UX:** KOReader's toggle closes its "Turning on Wi-Fi…" message as soon as `turnOnWifi` returns (elsewhere that call blocks). For interactive calls (menu toggle and Wi-Fi gestures only), the hook keeps the same message up until connected, then shows "Wi-Fi on. Connected to X." for 3 s.

  Declined from that review:
  - Keeping a newly joined network after a non-password failure: unverified credentials should not stay saved.
  - Telling KOReader when Wi-Fi turns off after the 10 s timeout: turning off takes about 0.6 s, and KOReader rechecks the state live.
- **Release 1.0.5** (2026-10-30). Fixes from Codex's review of 1.0.4:
  - The "Turning on Wi-Fi…" progress claimed "Wi-Fi is on but not connected" at its 20 s timeout without checking, and kept running if Wi-Fi was turned off mid-way. It now stops quietly once Wi-Fi goes off after having started coming on (it can still read "disabled" for about 1 s after the request), and at the timeout says either "on but not connected" or "did not turn on" from the latest state.
  - **The forget window no longer uses wall-clock time.** Changing the clock could leave a failed join's bad credentials saved. `CreatedNetworks` records `<boot count>|<elapsed ms>|<networkKey>` using `SystemClock.elapsedRealtime()` and `Settings.Global.BOOT_COUNT`; `boot_count` is present on the Nook. Entries from another boot, or with negative or expired age, are dropped. The prefs key moved to `createdNetworksV2`, and old-format entries are ignored.
  - **The helper's Java logic now has unit tests** (15 JUnit tests, run by `make check`): network-key uniqueness for real security values with tricky SSIDs, capability parsing, password rules, SSID quoting, and the CreatedNetworks window, reboot, clock and parsing cases. Two invalid tests were caught while writing them (they assumed a security value containing `|`, which cannot happen); they led to the correction in the 1.0.4 notes above. JUnit is test-only; no test classes end up in the APK.
- **Release 1.0.6** (2026-10-30). Fixes from Claude's review of 1.0.5 (that review covered only the 1.0.5 commit; earlier rounds were full-codebase):
  - The "Turning on Wi-Fi…" progress now ends only on `disabled`/`disabling` after Wi-Fi started coming on, and then says "Wi-Fi is off." (true whether the user switched it off or turning on failed). A passing `unknown` state no longer ends it silently.
  - `CreatedNetworks` treats a negative (unknown) boot count as "nothing is recent" and records nothing. Without a boot count a reboot cannot be detected, so `forget` refuses and the plugin falls back to the Android-settings prompt. `boot_count` is present on the Nook.
  - The boot count is read once in `WifiOps`'s constructor. 1.0.4's unused `createdNetworks` prefs key is deleted at startup.
  - The fake helper in `plugin/tests/run.lua` can replay scripted `wifiState` sequences (`wifi.state_script`), e.g. the Nook's stale `disabled` for about 1 s after a turn-on request. Progress tests assert that the progress widget is closed.
  - Test cleanups: a redundant `testOptions` block was removed; `String.repeat` replaces a hand-written helper.
  - Security pass over the whole codebase: nothing new. The only changes since the 1.0.4 audit add no exposed surface: private SharedPreferences records of network keys and times (no passwords, backups off), the boot-count read, and the progress message.
- **Wi-Fi fix in 1.1.0 (from Codex's review on 2026-10-31):** the plugin's own `waitForConnection` (used by its Wi-Fi toggle after Wi-Fi reports enabled, and by Reconnect) kept waiting if Wi-Fi went off and then claimed "Wi-Fi is on but not connected" at the timeout. It now stops on `disabled`/`disabling` with "Wi-Fi is off." and broadcasts `NetworkDisconnected`, and the timeout says "on but not connected" only when the latest `wifiState` is "enabled", otherwise "did not connect within 20 seconds" (Codex's follow-up: the reply's `enabled` is false for "enabling" and "unknown" too, so the first version wrongly said "Wi-Fi is off." for those). The NetworkMgr progress (`nookwifinetwork.lua`) already did this since 1.0.6. Both callers enter with Wi-Fi already reported enabled, so the Nook's stale "disabled" right after a turn-on request cannot end it early. Three offline tests fail on the old code. **Verified on device (2026-10-31):** Wi-Fi turned on from the plugin's checkbox, then switched off over ADB (`svc wifi disable`) 2.8 s later, before it connected. The plugin's next poll (0.3 s later) ended the wait: no further polling, and "Turning Wi-Fi on…" was replaced by "Wi-Fi is off." (per the user). Normal on/off through the checkbox also still worked. Ships in 1.1.0.
- **Same fix for `awaitNetwork` (Claude's review, 2026-10-31, in 1.1.0):** choosing a saved network or joining a new one had the same blind spot: if Wi-Fi went off mid-connect, it waited 20 s and then said "Could not connect to X. It may be out of range." It now stops on `disabled`/`disabling` with "Wi-Fi is off.", through `fail`, so join still removes the network it created (`forget` does not need Wi-Fi on; a refusal still shows the Android-settings prompt). `beginOperation`'s finish now also broadcasts `NetworkDisconnected` when an operation that announced `NetworkConnecting` ends with Wi-Fi off. Three offline tests fail on the old code. Not tested on the device.
  - Checked and left alone: `ensureEnabled` still waits its full 20 s if Wi-Fi comes on and then fails back to off, but its message ("did not turn on within 20 seconds") is accurate; stopping early would need the stale-"disabled" handling from `nookwifinetwork.lua`. Scanning already stops at once, because the helper's `scanResults` returns `wifi_disabled`.
- **Minimal KOReader Home launcher** (implementation started 2026-10-30). Decisions so far:
  - **Write our own; do not fork AnyLauncher** (github.com/tumuyan/AnyLauncher). It has no license, so its code may not be modified or redistributed. Its build is also obsolete (AGP 3.2, support-v4 25, Glide 3.8), and it requests internet and storage permissions we do not need. Borrowing ideas is fine.
  - Build it as a **separate APK** in a new `launcher/` Gradle project, set up like `helper/`: plain Java, no runtime dependencies, minSdk/targetSdk 27, `android.builtInKotlin=false`, JUnit for pure logic. Package `dev.nookkoreader.launcher` (confirmed by the user, superseding the earlier scaffold name `dev.nook.koreaderlauncher`). Sign it with the **same release key** and add `make` targets alongside the helper's.
  - Behavior:
    - A HOME activity that, when Home is pressed, launches KOReader (`org.koreader.launcher`) and finishes.
    - **Escape route:** pressing Home 3 times within about 1.5 s opens a fallback screen (idea borrowed from AnyLauncher) with buttons for Olauncher/Android's launcher chooser, Android Settings, and an app list. A launcher icon (LAUNCHER category activity) also opens this screen.
    - **Loop guard:** if KOReader is missing, or the launcher has relaunched it several times within a short window (e.g. 3 times in 10 s, meaning KOReader keeps crashing), show the fallback screen instead of relaunching. Put the counting logic in a pure class with JUnit tests.
    - E-ink friendly: plain black-on-white layout like `SetupActivity`, no animations.
  - **Safety, required before changing the default launcher:** the user's explicit go-ahead at that moment, plus a tested way back to Olauncher.
    - Over ADB: `adb shell cmd package set-home-activity app.olauncher/.MainActivity`, or `adb uninstall` of the launcher.
    - On the device: the triple-Home fallback screen.
    - Test both before relying on it. Never disable or remove the stock Nook launcher or Olauncher.
  - Suggested order:
    1. Scaffold `launcher/` and build it.
    2. Install it without making it the default, and test it by launching its activity over ADB.
    3. Test the loop guard and fallback screen.
    4. With the user's go-ahead, set it as the default and test Home, triple-Home, and the way back.
    5. Package it in `make dist`; document it in the README.

- **Launcher 0.1.0 implementation:** `launcher/` is a separate plain-Java Gradle project, AGPL-3.0-or-later, no runtime dependencies or manifest permissions. Uses the existing wrapper/AGP and signing properties from `helper/keystore.properties`; it never regenerates a key. Its version is independent of the Wi-Fi release.
  - `HomeActivity` redirects once per HOME intent and finishes. It never relaunches from `onResume`. `RecoveryActivity` is the separate launcher-icon entry point and stays paused until its explicit resume button is used. Back does not dismiss recovery into another Home launch.
  - `LaunchGuard` is pure Java with JUnit tests. History is persisted synchronously before launching, keyed by boot count and elapsed time: the third entry within 1.5 s opens escape; the third within 10 s opens loop recovery. A manual resume resets history and records its own launch. Unknown boot count, malformed history, or a failed guard write stops automatic launch. Recovery's pause flag survives reboot. A rapid series of deliberate Home presses can also trigger the loop guard.
  - `make check` includes launcher lint/tests. `make install-launcher` runs the full check and installs the signed launcher only. `make launcher-recovery` opens its icon screen; `make uninstall-launcher` removes only it. `make dist` also verifies its release certificate and packages its APK.
  - Device installation of a *new* HOME-capable package cleared Android's existing preferred Home selection. Restore Olauncher after test installs using the documented ADB command; do not select this launcher as default without approval. No build/install target sets a default launcher.
  - Verified on the Nook on 2026-10-30 with the signed `dev.nookkoreader.launcher` APK: explicit Home activity opens KOReader; three entries spaced 2 s apart stop at loop recovery; three explicit Home entries sent in 1.09 s show the escape message; recovery pause survives force-stopping/restarting the launcher; its Olauncher button opens Olauncher. The recovery layout was visually checked on a device screenshot. Android Home settings and All apps were also exercised (initial scaffold, before the package-only rename).
  - The ADB restore command was executed successfully and resolution confirmed `app.olauncher/.MainActivity` as default. The earlier scaffold package `dev.nook.koreaderlauncher` was uninstalled. Current launcher version: 0.1.0, signed with the pinned release certificate; `make dist` passed, with 7 launcher JVM tests plus the existing 96 tests.
  - **Default Home testing approved by the user on 2026-10-30.** Set `dev.nookkoreader.launcher/.HomeActivity` as the default and verified resolution. An injected system HOME key opens KOReader. Three separately injected HOME keys (~3.6 s total) reach loop recovery. Fast injected keys are coalesced by Android and do not establish the physical triple-Home behavior; the user has been asked to test the physical button. KOReader crash/exit and reboot behavior remain untested. Missing KOReader is handled in code but was not tested by removing or disabling the user's KOReader. Do not describe explicit-intent or injected-key tests as physical-button or crash tests.

- **Launcher 0.1.2: physical Home button findings (2026-10-30, verified on device with logcat and the launcher's new `KOReaderHome` log tag).**
  - The Home button is **capacitive** (per the user), not mechanical; that likely explains the delayed release and swallowed taps, which come from the touch controller. Stray touches are possible: one just reopens KOReader, three within 10 s open recovery.
  - The Nook's physical Home button sends `KEYCODE_HOME`, but Android only sees the press on *release*, which the Nook reports 1.3–2 s after the press even for a quick tap. Taps during that time are swallowed, so a fast triple tap arrives as **one** HOME entry. The 1.5 s "triple-Home escape" in the original plan and in 0.1.0 can never trigger physically; ADB-injected keys had hidden this.
  - Three physical presses about 2 s apart produced three HOME entries within about 5 s, and the third opened recovery (`loop`), verified in logcat.
  - 0.1.2 removes the separate fast escape: any 3 HOME entries within 10 s open recovery (`LaunchGuard.Decision` is now `LAUNCH`/`LOOP`). The recovery text was reworded to cover both cases ("Home was pressed 3 times, or KOReader closed repeatedly…"), and the README and tip say "press Home 3 times, about 2 seconds apart". Earlier notes above about a 1.5 s escape or "triple-Home" describe the superseded design.
  - `HomeActivity` logs each HOME entry and the guard's decision under the tag `KOReaderHome` (no user data); `make logs-launcher` follows it.
  - **Crash and reboot tests (2026-10-30, over ADB, verified with the `KOReaderHome` log and the focused window):**
    - Single crash (`am force-stop org.koreader.launcher`) with KOReader opened *by the launcher*: Android returned to Home by itself, and the launcher reopened KOReader.
    - If KOReader was opened as an ordinary app (e.g. from Olauncher), Android instead returns to whatever task was behind it (an old Settings screen in one test). That is standard Android behavior, not a launcher bug.
    - Three crashes about 3 s apart: launch, launch, then `loop` → recovery screen. Crash-loop guard verified.
    - Reboot with the launcher paused: the default Home survived, Android started HomeActivity at boot (`paused`), and recovery was shown. `boot_count` went from 9 to 10.
    - After resuming from recovery, a physical Home press logged `launch KOReader`, so the pause was cleared. A very quick tap on the capacitive button did **not** register at all (no `KEYCODE_HOME` in logcat); a touch of about 1 s did. The README tells users to hold each touch about a second.
    - Reboot while *not* paused: Android started HomeActivity at boot (`launch KOReader`, about 23 s after the kernel started), and KOReader was in front. `boot_count` went from 10 to 11.
    - Not yet tested: exiting KOReader from its own menu; KOReader missing: **not tested by decision** (the user, 2026-10-30): the launcher is only for Nooks with KOReader installed, and testing would mean removing the user's KOReader. The missing-KOReader code path stays as a safety net for KOReader updates/reinstalls or accidental removal: it shows recovery (with Olauncher) instead of leaving Home dead.
  - **Remote testing pitfalls on this Nook:**
    - After an ADB wake-up (`KEYCODE_WAKEUP`), the Nook shows B&N's own **"Slide to unlock" lock screen**, even though `lockscreen.disabled=1`. It goes back to sleep within seconds despite `screen_off_timeout=300000`; ADB input apparently does not count as user activity.
    - Home keys do nothing while the lock screen is up. This, not the launcher, explains the injected Home keys that "did nothing" during this session. An earlier claim that Home is swallowed while Olauncher is in front was made under these conditions and is **unconfirmed (probably wrong)**.
    - `screencap` returns a black image while asleep. `uiautomator dump` fails ("null root node").
    - Trust `dumpsys window` (`mCurrentFocus`), `dumpsys power` (`mWakefulness`) and logcat. Check wakefulness and the lock screen before interpreting any injected-key result. Physical presses with the Nook unlocked always reached the launcher.

- **Launcher 0.1.3: code review and security pass (2026-10-30).**
  - Fixed:
    - `make logs-launcher` had an unclosed quote (introduced in 0.1.1).
    - Fail-closed guard cases (unreadable history, unknown boot count or clock) now return `Decision.UNAVAILABLE` and show "guard unavailable" instead of the loop message.
    - `HomeActivity` uses `@android:style/Theme.NoDisplay`, so a Home press no longer draws a white starting window and forces an extra e-ink refresh. Every path finishes in `onCreate`, which NoDisplay requires; verified on device with no crash, and the user confirmed the white flash is gone.
    - `LaunchState.pause()` now reports a failed write, and screens say "storage" instead of claiming to be paused. The pause flag is written only where it is not already saved.
    - Back on the recovery screen no longer overwrites the reason message.
    - `make clean` also cleans `launcher/`, and `check` depends on `check-launcher` instead of duplicating it.
  - Declined: moving the shared signing properties out of `helper/`. It is the same release key on purpose, and the 1Password restore steps point there.
  - Security:
    - No manifest permissions and no data beyond the guard's own timestamps. The app list only opens apps the user picks.
    - Accepted nuisance: HomeActivity and RecoveryActivity must be exported (for Home and the app drawer), so another installed app could start them to pause the launcher. That is the same effect as pressing Home 3 times; it grants no data or privileges, and one tap resumes.

- **Launcher 0.1.4: launcher-agnostic (the user asked, 2026-10-30).**
  - The recovery screen's "Open Olauncher" button is now **Open another launcher**. It lists every exported HOME activity of other apps, skipping negative-priority entries (Android's FallbackHome) and `com.android.settings`. With one match it opens directly; with several it asks. The default Home app is never changed.
  - It opens each launcher through its app-drawer entry (`getLaunchIntentForPackage`), the path verified for Olauncher in 0.1.0, and falls back to an explicit start of its HOME component. For a third-party caller that is an ordinary activity start, not a Home-type one.
  - The app list and the launcher picker share one `pickAndOpen` helper, so filtering (including `exported`) cannot drift apart again. Later messages keep the "could not save the restart guard" warning.
  - Messages and the README no longer assume Olauncher; the README shows how to list Home apps and set one as the default over ADB. Olauncher remains this user's fallback, but nothing depends on it.
  - On this Nook the picker lists `com.nook.partner/.FacadeLauncherActivity` and `app.olauncher/.MainActivity`. Over ADB, Olauncher opened. The Nook's facade did not come to the front (Olauncher stayed), possibly because it only forwards elsewhere; unknown.
  - **Not yet verified on device:** the button itself, picking the Nook's launcher, and whether a physical Home press from another launcher returns to KOReader Home. The 0.1.0 note above that "its Olauncher button opens Olauncher" describes the replaced button.

- **Launcher 0.1.6: exiting KOReader returns to Home (the user decided, 2026-10-31).**
  - Device checks of 0.1.5 (2026-10-31, from logcat):
    - "Open another launcher" → the Nook's launcher: `com.nook.partner/.FacadeLauncherActivity` started `bn.ereader/com.nook.lib.ynt3.EpdHomeActivity` (the Nook's home screen). Whether it was visibly in front was not confirmed. Olauncher opened when picked.
    - A physical Home press from the Nook's home screen and from Olauncher reached HomeActivity (it showed recovery because the launcher was paused, which is correct; after resuming, Home opened KOReader).
    - KOReader's own Exit landed in Olauncher.
  - **Why Exit does not return to Home on its own:** KOReader's Android exit calls `ANativeActivity_finish` and then `os.exit` (`reader.lua`), so the process dies while the finish is still in progress. Android handles it like a dying app and resumes the next task in the fullscreen stack, ignoring return-to-Home. Tasks opened from recovery (Olauncher, the Nook's home) stay in that stack, and a normal app cannot remove them. This happened even when KOReader was opened from Home. `FLAG_ACTIVITY_TASK_ON_HOME` (tried first) did not help.
  - **Fix: the KOReader patch `launcher/patch/2-koreader-home.lua`.** It wraps `Device.exit`: after KOReader's own exit (`Generic.exit` plus `ANativeActivity_finish`), just before `os.exit`, it starts an implicit HOME intent (HOME as the only category, `FLAG_ACTIVITY_NEW_TASK`). Starting Home *before* the finish request would hand Home a KOReader still in front. It acts only if `resolveActivity(…, MATCH_DEFAULT_ONLY)` names `dev.nookkoreader.launcher`, so it does nothing when another launcher, or the chooser, is the default. It uses raw JNI with a check after every call, like `nookwifihelper.lua`.
    - It also relabels the Exit menu item **Restart KOReader** (KOReader's own translated msgid, used on devices that can restart) while the launcher is the default. On Android `canRestart` and `hasExitOptions` are false, so `common_exit_menu_table.lua` makes `exit_menu` a plain "Exit" leaf; the patch wraps `MenuSorter.mergeAndSort` and, for the "filemanager" and "reader" prefixes (its only callers at KOReader `b44e9b7`), changes `item_table.exit_menu.text` *before* sorting. **`MenuSorter:sort` removes each item from `menu_items` as it places it**, so a first version that relabelled after `setUpdateItemTable` found nothing and the device still showed "Exit"; the test stand-in had not modelled that removal. It does now, and relabelling after sorting fails the tests. Verified on device (2026-10-31): the menu shows **Restart KOReader**, and it restarts KOReader. Not relabelled: the "Exit KOReader?" prompt on Back in the file manager (a literal inside `FileChooser:onBack`) and the gesture action name.
    - The first version (`9-koreader-home.lua`, KOReader's `on_exit` stage) did only the Home part and was verified on device below. The `2-` version (user asked for the label, 2026-10-31) moved the same call into a `Device.exit` wrapper, which runs at the same point, so one file does both.
    - Offline tests: `launcher/patch/test.lua` (stand-ins for Device and both menus; fake JNIEnv; every step made to throw in turn, for exit and for the menu). Mutations confirmed to fail it: relabelling without the default-Home check, starting Home before KOReader's exit, and a missing exception check. `make check-launcher` runs luacheck and the tests; `make install-launcher` also pushes the patch; `make install-launcher-patch` pushes only the patch; `make uninstall-launcher` removes it; `make dist` ships it and its checksum.
  - **Verified on device (2026-10-31):** six exits in a row, each followed by KOReader reopening through HomeActivity (patch start → old process died ~0.25 s later → HomeActivity → KOReader displayed ~0.4 s after that). It worked even when KOReader had been opened from Olauncher. No crash; restarting KOReader while the old process is dying was not a problem.
  - **Guard window widened from 10 s to 30 s** (`LaunchGuard.LOOP_MS`, the user's choice): one exit-and-reopen cycle took about 7 s, so three exits never fitted in 10 s. 30 s also catches crashes a few seconds after opening. Cost: three Home presses within 30 s during normal use open recovery (one tap to resume). Verified on device (2026-10-31): three exits about 7 s apart gave launch, launch, then `loop` → recovery (14.5 s from first to third).
  - The recovery screen's resume button now clears the pause and history (`LaunchState.resume()`) and starts the implicit HOME intent when this launcher is the default, so HomeActivity opens KOReader and records the launch. A third-party implicit HOME start with HOME as the only category runs as a Home start (seen in logcat: HomeActivity started from uid 10054 and opened KOReader). Otherwise it falls back to opening KOReader directly. `AppLaunch.openReader` still adds `FLAG_ACTIVITY_TASK_ON_HOME`; harmless, but not what fixed Exit.

- **Launcher review after 0.1.6 (2026-10-31): bugs and security.**
  - Fixed:
    - `adb push` does **not** create a missing destination folder (verified on the Nook: "remote couldn't create file: Is a directory"), and KOReader creates no `patches/` folder by itself. `install-launcher`, `install-launcher-patch` and `install-plugin` now run `mkdir -p` first; the README's manual steps say the same.
    - `uninstall-launcher` stopped before removing the patch if the APK was already gone; the uninstall is now allowed to fail.
  - Accepted:
    - While recovery is paused, the menu still says **Restart KOReader**, but Home then shows recovery instead of KOReader. KOReader cannot read the launcher's private pause flag, and recovery is the right place to land.
    - If a future KOReader moves `ui/menusorter`, the patch fails to load after already wrapping `Device.exit`: Exit keeps working, the label stays "Exit", and KOReader shows its usual "Error applying patch" message.
  - Security: no change in exposed surface. The patch passes no data, starts only the implicit HOME intent, and only when `resolveActivity` names this launcher; it logs nothing user-specific. The launcher still has no permissions; exported HomeActivity/RecoveryActivity remain the accepted nuisance from 0.1.3 (another app can pause the launcher or count toward the guard, nothing more).

- **Bluetooth page-turner support from KOReader** (the user asked on 2026-10-30; Stage 0 and release 1.1.0 done 2026-10-31). **Scope: page-turner remotes only.** Headphones and audio are explicitly out of scope. The goal: turn Bluetooth on, pair or reconnect a remote (KOReader treats it as a keyboard), then turn it off to save battery.
  - Verified first: the Nook reports `android.hardware.bluetooth` and `bluetooth_le`, `bluetooth_manager` runs, and `bluetooth_on` was 1 (on).
  - The user's remote is an **8BitDo Micro**, paired in Classic (BR/EDR) mode as "8BitDo Micro gamepad", device class 0x540 (peripheral, keyboard). Their own patch `2-nook-micro-keys.lua` maps its keys in KOReader, so key handling is out of scope.
  - **Bluetooth Stage 0, verified on device 2026-10-31** (`spikes/bt-test`: a normal app, `targetSdk=27`, permissions `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_COARSE_LOCATION` via `pm grant`; an exported ContentProvider driven by `adb shell content call`, accepting only the shell/root UID):
    - `isEnabled`/`getState`, `getBondedDevices` (name, class, bond state) work.
    - `getProfileProxy(…, 4)` (`INPUT_DEVICE`, hidden constant) returns `android.bluetooth.BluetoothInputDevice`; its public `getConnectionState(device)` gives the remote's HID state (0 disconnected, 1 connecting, 2 connected).
    - `enable()`/`disable()`: accepted, no popup; off in about 1 s, on in under 1 s. **Turning Bluetooth off kills the HID proxy, and the Bluetooth process restarts with a new PID on enable**; the proxy reconnects through its listener. The real helper must handle the proxy coming and going.
    - `startDiscovery`: about 14 s; found 19 devices nearby, mostly BLE (type 2) with class 0x1f00 (uncategorized). Some BLE page turners also report no class, so a picker must not filter on class alone: show named devices, likely remotes first.
    - Hidden `BluetoothInputDevice.disconnect(device)` by reflection: **works** (returns true, the remote disconnects). Hidden `connect(device)`: **accepted** (returns true, state went 0→1), but the 8BitDo did not answer and it fell back to 0 after about 12 s. The 8BitDo only reconnects when a button is pressed (it initiates). So no privileged-permission block; host-initiated connect depends on the remote.
    - After Bluetooth off/on, the 8BitDo did not reconnect by itself within 10 s (asleep) but did on the next button press.
    - Hidden `BluetoothDevice.removeBond()` by reflection: **works** (bond 12→10, remote disconnected, no popup).
    - Pairing: with the 8BitDo in pairing mode, discovery found it within about 0.5 s; `createBond()` bonded it in about 3 s (bond 10→11→12) and **Android connected HID automatically** about 0.3 s later. **No pairing popup** (the user confirmed; KOReader stayed focused). Page turns worked afterwards. Remotes that use a PIN or passkey would show Android's pairing dialog over KOReader; not tested (the 8BitDo uses "just works" pairing).
    - Conclusion: **everything can be done from KOReader through the helper; no Android settings screen is needed** for this remote. The stock-settings fallback stays for remotes that misbehave.
  - Approach: extend the existing helper and plugin; no separate app.
    - New helper methods: Bluetooth state, `setEnabled`, paired devices (marking likely remotes), scan (start, then poll results), pair, forget, and possibly disconnect. Discovery uses coarse location, which the helper already holds.
    - Plugin: a "Bluetooth" menu next to Nook Wi-Fi. KOReader has no Bluetooth manager to hook.
  - **Release 1.1.0 (helper and plugin), built 2026-10-31.**
    - Helper: `BluetoothOps` (methods `btState`, `btSetEnabled`, `btPaired`, `btDevice`, `btScan`, `btScanStop`, `btScanResults`, `btPair`, `btForget`, `btOpenSettings`), pure logic in `BluetoothRules` (JUnit). Manifest adds `BLUETOOTH` and `BLUETOOTH_ADMIN` (install-time). Lint's `MissingPermission` is suppressed for `BluetoothOps`: all 22 findings were API 31's `BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN`. Device addresses are never logged (the provider logs method names only). `btOpenSettings` opens the stock screen from the helper, so the plugin needs no extra JNI.
    - Plugin: `nookbluetooth.lua`, mixed into `NookWifi` by `main.lua` (reuses `beginOperation`/`pollState`). Menu "Nook Bluetooth", option "On while reading" (`nookbluetooth_while_reading` in `G_reader_settings`), Dispatcher action `nookbluetooth_toggle`. Events: `onReaderReady` on; `onCloseDocument` off after 5 s (cancelled if the next book opens; the timer lives in module-level state because the book's plugin instance is gone by then); `onRequestSuspend` off (KOReader on Android sends it on `APP_CMD_PAUSE`) and `onResume` on again, only if it was turned off for sleep. RequestSuspend is ignored while the plugin's own Android settings screen is open or an operation (e.g. pairing, which may show Android's PIN dialog) is running.
    - Offline tests: 27 in `plugin/tests/run.lua`, against a simulated Bluetooth device modelled on Stage 0. Six deliberate mutations (settings guard, cancel on next book, busy guard, sleep flag, reporting before the state changes, early list) each failed their test.
    - **Verified on device (2026-10-31):** menu, status and paired list; Bluetooth off/on; "On while reading": on when a book opened, off 5 s after it closed; forget; scan and pair (connected 2.3 s after the request). Sleep (over ADB, `KEYCODE_SLEEP` with a book open): KOReader paused and Bluetooth went off within 0.1 s; wake (`KEYCODE_WAKEUP`): KOReader resumed with no lock screen and Bluetooth came back on. The user could not put the Nook to sleep by *holding* the power button; a short press is the usual sleep action (not yet confirmed by the user).
    - Bug found on device and fixed: a second scan reported "finished" on its first poll. `startScan` cancels any running discovery, and that cancellation's `DISCOVERY_FINISHED` broadcast arrived after the new request. "Finished" now counts only after this scan's `DISCOVERY_STARTED`. The fix is installed but its effect was not re-tested on the device. Also seen: one scan ran into the plugin's 20 s timeout instead of finishing in about 14 s; the list then showed what had been found, which is the intended fallback.
  - **Review after 1.1.0 (2026-10-31), fixed and verified on device:**
    - RequestSuspend comes on *any* `APP_CMD_PAUSE`, so opening Android Wi-Fi settings, a dictionary or a link while reading turned Bluetooth off. `btState` now reports `screenOn` (`PowerManager.isInteractive`, no permission), and the plugin turns Bluetooth off for sleep only when it is false; this replaced the "away" flag for the plugin's own settings shortcut. Verified over ADB: `KEYCODE_SLEEP` with a book open → off (the screen already reads off when KOReader is paused); wake → on; `am start -a android.settings.WIFI_SETTINGS` while reading → the plugin checked and left Bluetooth on. The user's short press of the power button also triggered off/on (log entries at 11:03 under the previous build).
    - The 5 s turn-off after closing a book could cut into a pairing or toggle started right after; `setBluetooth`, `findRemotes` and `pairRemote` now cancel it.
    - Scan results are described when asked, not when found, so a name Android learns after first finding a device is picked up.
    - The menu's status line never updated when a remote connected later (in one test, 35 s after Bluetooth came on). After turning Bluetooth on, `watchForRemote` polls `btPaired` every second for up to 60 s, announces "<name> connected." and refreshes the open menu. Verified on device: the message appeared and the status line updated without leaving the menu.
    - Verified: a helper process started while Bluetooth is off still binds the HID proxy once Bluetooth comes on (force-stopped the helper with Bluetooth off; after turning it on and pressing a remote button, the paired list showed it connected). `svc bluetooth` and `service call bluetooth_manager` do nothing or fail on this Nook (the shell lacks `BLUETOOTH_ADMIN`), so Bluetooth cannot be switched over ADB here; use the plugin.
  - **Second review (2026-10-31), fixed, offline tests only:**
    - `watchForRemote` refreshed the TouchMenu even after the user had closed it; refreshing a closed TouchMenu makes KOReader repaint the whole screen (`setDirty("all")`, an e-ink flash). It now refreshes only if `UIManager:isWidgetShown(touchmenu_instance.show_parent)`; both ReaderMenu and FileManagerMenu show that `menu_container` (checked at `b44e9b7`). The first version of its test captured its baseline one step late and passed without the guard; fixed, and it now fails without it.
    - `btScanResults` described every device found (about four Bluetooth-service calls each, 19 devices nearby in Stage 0) on every 0.5 s poll, while holding the lock the discovery receiver needs. It now copies the list, then describes only devices that have a name.
  - **Codex's review of b5f2cfe (2026-10-31), fixed, offline tests only:**
    - The automatic controls compared only `enabled`, which is false while turning on. Sleeping (or closing a book) during `turning_on` skipped the turn-off, and Bluetooth finished turning on while the Nook slept. `headingTo(state, on)` now treats `turning_on` as on and `turning_off` as off, in `switchQuietly` and `onRequestSuspend`.
    - "Forget" said "Forgot X." as soon as `removeBond` was accepted, but Android 8.1 queues the removal and it can still fail. `forgetRemote` now polls `btDevice` until `bond` is `none` (10 s timeout), and on timeout says it could not forget and offers Android Bluetooth settings.
    - The fake device now models both: a switch request during a transition is queued and applied after it, and a forget is applied on a later poll (or never, with `forget_never`). The previous fake removed bonds at once and ignored requests mid-transition, which hid both bugs; one new test passed only by timing until the fake queued requests. All four new tests fail on b5f2cfe.
  - **Review of 73ff6f1 (2026-10-31), fixed:**
    - The gesture and the menu checkbox chose their target from `enabled`, so during `turning_on` a toggle turned Bluetooth on again instead of off. Both now use `headingTo`; the checkbox shows checked while turning on.
    - The forget timeout said "Not supported on this device", which is wrong for a removal that did not complete; it now says "Could not forget X. Try again, or use Android Bluetooth settings."
    - After a successful forget the paired-remotes submenu (built once, when opened) still listed the remote; the plugin now goes back up to the Bluetooth menu (`TouchMenu:backToUpperMenu`, only while the menu is shown).
    - Not changed, by decision: the user said the sleep-while-turning-on case does not arise on the Nook in practice, so that fix stays verified offline only.
    - Real Android 8.1 behaviour for a switch request during a transition (`BluetoothManagerService` waits for the transition, then applies it) is from reading the framework's design, not verified on the device; the fake queues it the same way.
  - **Settings fallback must be stock Android's Bluetooth screen, never the Nook's.** The Nook's own Bluetooth settings cannot pair HID devices (per the user). Open the component explicitly: `com.android.settings/.Settings$BluetoothSettingsActivity`. Fall back to the `android.settings.BLUETOOTH_SETTINGS` action only if that component is missing. Checked 2026-10-30: on this firmware that action resolves only to that stock activity; the Nook's screen is not registered for it. The user paired the 8BitDo in the stock screen before Stage 0, so that path works for it.
  - Rules carried over: report results only once the state really changes, never log device secrets or PINs, keep the fake helper faithful, add JUnit tests for any pure logic, and keep the README and AGENTS.md in sync.

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
