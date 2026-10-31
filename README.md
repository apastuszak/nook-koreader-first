# Nook Wi-Fi for KOReader

Turn Wi-Fi on and off, switch between saved networks, and join new networks from inside KOReader on a **Barnes & Noble Nook GlowLight 4 Plus**, without going back to the Nook home screen or Android settings.

It has two parts:

- **Nook Wi-Fi Helper** (`nookwifi-helper-<version>.apk`): a small Android app that holds the Wi-Fi permissions KOReader does not have. You open it once during setup.
- **Nook Wi-Fi plugin** (`nookwifi.koplugin-<version>.zip`): the KOReader plugin you actually use.

No root is needed.

## Requirements

- Nook GlowLight 4 Plus (Android 8.1). It has only been tested on firmware 8.1.7.120.
- KOReader for Android, installed as `org.koreader.launcher`. It has been tested with the nightly build from 3 October 2026.

## Install

1. **Install the helper app.** Copy `nookwifi-helper-<version>.apk` to the Nook and open it with a file manager, or install it over USB:
   ```sh
   adb install nookwifi-helper-<version>.apk
   ```
2. **Install the plugin.** Unzip `nookwifi.koplugin-<version>.zip` and copy the `nookwifi.koplugin` folder into `koreader/plugins/` on the Nook's storage. Over USB:
   ```sh
   unzip nookwifi.koplugin-<version>.zip
   adb push nookwifi.koplugin /sdcard/koreader/plugins/
   ```
3. **Allow location access (once).** Open **Nook Wi-Fi Helper** from your launcher's app list and tap **Allow location access**, then **Allow**. Android only shows Wi-Fi network names to apps with location access; the helper never uses your location. Over USB instead:
   ```sh
   adb shell pm grant dev.nookwifi.helper android.permission.ACCESS_COARSE_LOCATION
   ```
4. **Exit KOReader and open it again.** On Android, KOReader has no Restart option, and it only loads plugins when it starts.

## Use

Everything is under **Settings → Network**.

- **Wi-Fi connection** is KOReader's own toggle. It now turns Wi-Fi on and off directly instead of opening Android settings. Gestures such as **Toggle Wi-Fi** and the **Action when Wi-Fi is off → turn on** setting, which sync, OPDS and news downloads use, also work without leaving KOReader.
- **Nook Wi-Fi** opens the plugin's menu:
  - **Status**: tap it for the network name, signal, IP address and link speed.
  - **Wi-Fi**: on/off. It reports success only once Wi-Fi has actually turned on and connected, or turned off.
  - **Reconnect**: reconnects to the best saved network, turning Wi-Fi on first if needed.
  - **Scan for networks…**: lists nearby networks. Tap one to join it:
    - saved networks connect straight away
    - open networks join with no password
    - WPA/WPA2 networks ask for a password
  - **Saved networks**: switch to another saved network.
  - **Open Android Wi-Fi settings**: the stock settings screen, for anything the plugin cannot do.
  - **Helper info**: shows the helper and plugin versions.

If a new network's password is wrong, the plugin says so and removes the network again, so you can simply try again.

## Limitations

- **Supported security:** open networks and WPA/WPA2 Personal. WPA2/WPA3 mixed networks join as WPA2. **Not supported:** WPA3-only, Enterprise (802.1X), WEP, and hidden networks. Use Android Wi-Fi settings for those.
- **Changing a saved password:** the plugin cannot change the password of a network that is already saved, because the Nook's firmware does not allow it. If a saved network's password stops working, the plugin offers to open Android Wi-Fi settings: forget the network there, then join it again from **Scan for networks…**.
- **Removing saved networks:** the plugin cannot remove networks that were saved by the Nook or in Android settings. Use Android Wi-Fi settings.
- **After a KOReader update:** the plugin adjusts KOReader's internal Wi-Fi handling. If **Settings → Network → Wi-Fi connection** opens Android settings again after updating KOReader, the update changed that code. The **Nook Wi-Fi** menu still works; please report the problem.

## Privacy

- **Passwords:** a Wi-Fi password goes from KOReader straight to Android. The helper never logs or stores it, or sends it anywhere. The plugin does not save it in KOReader's settings.
- **Debug logging:** KOReader's on-screen keyboard writes every key press to the system log when debug logging is on. The password dialog switches debug logging off while it is open and restores it afterwards.
- **Who can use the helper:** the helper only accepts requests from KOReader. Anything running inside KOReader can use it, including other plugins and patches you install, so it can control Wi-Fi and read nearby network names (which can reveal roughly where you are). Only install KOReader plugins you trust.

## Update

Install the new helper APK over the old one, and replace the `nookwifi.koplugin` folder with the new one. Then exit KOReader and open it again. Your location permission is kept.

Always update the helper and the plugin together; **Helper info** shows both versions so you can check. If the two cannot work together, the plugin says to update both, or that the helper is out of date.

## Remove

1. Delete the `koreader/plugins/nookwifi.koplugin` folder.
2. Uninstall **Nook Wi-Fi Helper** in Android Settings → Apps, or over USB with `adb uninstall dev.nookwifi.helper`.
3. Exit KOReader and open it again. KOReader's Wi-Fi items go back to opening Android settings.

Networks you joined stay saved in Android.

## Troubleshooting

| You see | What to do |
|---|---|
| No **Nook Wi-Fi** item under Settings → Network | Check the folder is `koreader/plugins/nookwifi.koplugin` (not nested inside another folder). Then exit KOReader and open it again. |
| "Nook Wi-Fi Helper is not installed." | Install the helper APK. |
| Network names show as "(name hidden)", or scanning asks for permission | Do install step 3 (allow location access). |
| "…different versions. Update both." | Install the helper and plugin from the same release. |
| "Wrong password for …" on a saved network | Forget the network in Android Wi-Fi settings, then join it again from **Scan for networks…**. |
| "Could not connect to X. Connected to Y instead." | Android could not reach X (out of range or rejected) and went back to another saved network. |

## Optional: KOReader Home launcher

**Requires KOReader** (`org.koreader.launcher`) to be installed. It is meant only for Nooks that use KOReader. If KOReader is ever missing (for example mid-update), Home shows the recovery screen instead of opening it.

**KOReader Home** is a separate app (`dev.nookkoreader.launcher`), independent of
the Wi-Fi helper and plugin. When selected as the default Home app, it opens
KOReader whenever Home is invoked. It requests no permissions and uses no
network access. It has been tested as the default launcher on a GlowLight 4 Plus:
Home, the recovery screen, recovering from a KOReader crash, and rebooting.

Install `koreader-home-<version>.apk` from `dist/`, or use:

```sh
make install-launcher
```

Installing does not select KOReader Home as your default. Android may clear the
previous Home preference when a new Home app is installed; if prompted, pick the
launcher you were using before. Keep at least one other launcher installed (for
example the Nook's own launcher or Olauncher) as a way back.

Open **KOReader Home** from your other launcher to reach its recovery screen. It offers:

- **Open KOReader and resume Home**: opens KOReader and enables automatic opening.
- **Open another launcher**: opens any other installed launcher (if there are several,
  you pick one) without changing the default Home app.
- **Choose default Home app**: opens Android's default-app settings (on this Nook,
  select **Home app** on that screen). This is where you can switch back to your
  other launcher permanently.
- **Android Settings** and **All apps**.

Once KOReader Home is the default, press **Home 3 times, about 2 seconds apart**,
to open recovery. Touch the button for about a second each time: the Home button is
capacitive, and a very quick tap may not register at all. Quick repeated taps do
not work either: the button only registers again 1–2 seconds after each press, so
fast taps count as one. Any three Home
presses within 10 seconds open recovery, which also protects against a KOReader
that keeps closing: the third return opens recovery instead of KOReader. Recovery
stays active across process restarts and reboots until you choose **Open KOReader
and resume Home**. KOReader missing or unable to open also leads to recovery.
Opening the app icon always goes directly to recovery.

To open recovery over USB:

```sh
adb shell am start -n dev.nookkoreader.launcher/.RecoveryActivity
```

To switch the default back to another launcher over USB, list the Home apps and set
one (for example Olauncher, or the Nook's own launcher):

```sh
adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME
adb shell cmd package set-home-activity app.olauncher/.MainActivity
# Use a component exactly as the first command lists it. The Nook's own launcher is
# listed as com.nook.partner/.FacadeLauncherActivity, but setting it as the default
# has not been tested.
adb shell input keyevent KEYCODE_HOME
```

To remove only the launcher, first switch the default to another launcher, then run:

```sh
adb uninstall dev.nookkoreader.launcher
```

Updates use `adb install -r koreader-home-<version>.apk`; the signing key must
match. The launcher's version is independent of the Wi-Fi helper/plugin version.
`make build-launcher` builds a debug APK; `make check-launcher` runs its lint and
unit tests; `make release-launcher` signs it using the existing release key.
`make dist` includes the launcher APK and its checksum alongside the Wi-Fi files.

## Building from source

On macOS with Homebrew you need JDK 21, the Android command-line tools (SDK platforms 27 and 35), LuaJIT, and luacheck. `AGENTS.md` lists the exact setup, the verified device behavior, and the design.

```sh
make check     # Android lint, luacheck, offline plugin tests
make install   # debug build of the helper + plugin, onto a USB-connected Nook
make dist      # signed release APK, plugin zip, and SHA256SUMS in dist/
```

`make dist` needs `helper/keystore.properties`, which points at the release signing key. Neither the key nor that file is committed to the repository.

## License

Copyright © 2026 Andy Pastuszak.

Nook Wi-Fi (the helper app and the KOReader plugin) is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, version 3 or (at your option) any later version. That is the same license KOReader uses. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE) for the full text.
