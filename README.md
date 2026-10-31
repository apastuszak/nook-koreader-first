# KOReader-first Nook

Make a **Barnes & Noble Nook GlowLight 4 Plus** a KOReader-first e-reader: everything you need day to day, from inside KOReader, without going back to the Nook's own software or Android settings. No root is needed.

What you get:

- **Wi-Fi**: turn it on and off, switch between saved networks, and join new ones.
- **Bluetooth page-turner remotes**: Bluetooth on/off, pairing, and keeping Bluetooth on only while you read.
- **Nook power off after sleeping**: let the Nook switch itself off after sleeping for a while.
- **Open Nook home**: jump to the Nook's own home screen when you do need it (the B&N store, the Nook's settings), and press Home to come back.
- **KOReader as the Home app** (optional): the Home button opens KOReader, and KOReader's Exit becomes **Restart KOReader**.

The parts:

- **Nook Wi-Fi Helper** (`nookwifi-helper-<version>.apk`): a small Android app that holds the Wi-Fi, Bluetooth and system-settings permissions KOReader does not have.
- **Nook Wi-Fi plugin** (`nookwifi.koplugin-<version>.zip`): the KOReader plugin you actually use: the Wi-Fi, Bluetooth, power-off and Open Nook home menus come from it.
- **KOReader Home** (`koreader-home-<version>.apk`, optional) and its KOReader patch (`2-koreader-home.lua`): see [Optional: KOReader Home launcher](#optional-koreader-home-launcher).
- **`install.sh`**: installs everything over USB and sets the permissions in one step (see [Quick install over USB](#quick-install-over-usb)).

The helper and plugin keep the names they started with ("Nook Wi-Fi"), because renaming them would break updates of existing installs.

## Requirements

- Nook GlowLight 4 Plus (Android 8.1). It has only been tested on firmware 8.1.7.120.
- KOReader for Android, installed as `org.koreader.launcher`. It has been tested with the nightly build from 3 October 2026.
- **For frontlight brightness and warmth, use a KOReader nightly build** for Android. With the stable release, KOReader's brightness and warmth controls do not work on the Nook. Nightly builds are on [KOReader's nightly download page](https://build.koreader.rocks/download/nightly/).

## Install

### Quick install over USB

If you have `adb` (Android platform-tools) on a Mac or Linux computer, the release's `install.sh` does every step below in one go: it checks the files against `SHA256SUMS`, installs the helper, gives it its permissions, and copies the plugin. It also gives KOReader the permissions it needs for the frontlight (brightness and warmth) and for its files, which you would otherwise allow by hand. Put all the release files in one folder, connect the Nook with USB debugging allowed, and run:

```sh
sh install.sh
```

To also install the optional [KOReader Home launcher](#optional-koreader-home-launcher) and its KOReader patch, add `--launcher`; add `--set-home` as well to make it the default Home app. The script never uninstalls anything and changes the default Home app only with `--set-home`. Afterwards, exit KOReader and open it again.

### Manual install

1. **Install the helper app.** Copy `nookwifi-helper-<version>.apk` to the Nook and open it with a file manager, or install it over USB:
   ```sh
   adb install nookwifi-helper-<version>.apk
   ```
2. **Install the plugin.** Unzip `nookwifi.koplugin-<version>.zip` and copy the `nookwifi.koplugin` folder into `koreader/plugins/` on the Nook's storage. Over USB:
   ```sh
   unzip nookwifi.koplugin-<version>.zip
   adb shell mkdir -p /sdcard/koreader/plugins
   adb push nookwifi.koplugin /sdcard/koreader/plugins/
   ```
3. **Allow location access (once).** Open **Nook Wi-Fi Helper** from your launcher's app list and tap **Allow location access**, then **Allow**. Android only shows Wi-Fi network names, and nearby Bluetooth remotes, to apps with location access; the helper never uses your location. Over USB instead:
   ```sh
   adb shell pm grant dev.nookwifi.helper android.permission.ACCESS_COARSE_LOCATION
   ```
   **Nook power off after sleeping** also needs "Modify system settings"; the plugin asks for it the first time you use it. Over USB instead:
   ```sh
   adb shell appops set dev.nookwifi.helper WRITE_SETTINGS allow
   ```
4. **Frontlight (if KOReader's brightness or warmth controls do nothing).** First make sure you use a KOReader nightly build (see [Requirements](#requirements)). KOReader changes the light through Android's system settings, so it also needs **Modify system settings**: in Android Settings → Apps → KOReader → Advanced → Modify system settings, turn it on. Over USB instead:
   ```sh
   adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
   ```
5. **Exit KOReader and open it again.** On Android, KOReader has no Restart option, and it only loads plugins when it starts.

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

### Bluetooth page turners

**Nook Bluetooth**, also under **Settings → Network**, is for page-turner remotes (KOReader sees them as a keyboard). Headphones and audio are not supported.

- **Status**: on or off, and which remote is connected. Tap it to refresh.
- **Bluetooth**: on/off.
- **On while reading**: turns Bluetooth on when you open a book, and off when you close it (after 5 seconds, so opening the next book does not switch it off) or when the Nook goes to sleep. When the Nook wakes up with a book open, Bluetooth comes back on.
- **Paired remotes**: lists your paired remotes. Hold one to forget it.
- **Pair a new remote…**: put the remote in pairing mode first, then choose it from the list. Likely remotes are listed first.
- **Open Android Bluetooth settings**: the stock Android screen (not the Nook's own, which cannot pair remotes).
- The **Toggle Bluetooth** action can be assigned to a gesture or a key.

After Bluetooth turns on, a remote usually reconnects only when you **press one of its buttons**; that first press may not turn a page. For a minute after you turn Bluetooth on, the plugin tells you when a remote connects.

### Nook power off after sleeping

**Settings → Device → Nook power off after sleeping** sets how long the Nook may sleep before it powers itself off: never (the Nook's default), 1 hour, 6 hours, 1 day, 3 days or 1 week. Powering off saves battery when the Nook is not used for a while; turning it on again takes a long press of the power button and a full start-up.

The first time you choose a value, the plugin asks you to allow **Nook Wi-Fi Helper** to modify system settings and opens Android's screen for it: turn the switch on, go back to KOReader, and choose again.

For the screen timeout (how long until the Nook sleeps), use KOReader's own **Settings → Screen → Screen timeout**.

### Open Nook home

**Tools → Open Nook home** opens the stock Nook home screen (your library, the B&N store and the Nook's own settings) without changing your default Home app. Press **Home** to come back: with the optional KOReader Home launcher that returns to KOReader; otherwise it goes to your default launcher. The **Open Nook home** action can also be assigned to a gesture or a key.

## Limitations

- **Supported security:** open networks and WPA/WPA2 Personal. WPA2/WPA3 mixed networks join as WPA2. **Not supported:** WPA3-only, Enterprise (802.1X), WEP, and hidden networks. Use Android Wi-Fi settings for those.
- **Changing a saved password:** the plugin cannot change the password of a network that is already saved, because the Nook's firmware does not allow it. If a saved network's password stops working, the plugin offers to open Android Wi-Fi settings: forget the network there, then join it again from **Scan for networks…**.
- **Removing saved networks:** the plugin cannot remove networks that were saved by the Nook or in Android settings. Use Android Wi-Fi settings.
- **Nook power off after sleeping:** this is a hidden setting of the Nook's firmware. It works on the Nook GlowLight 4 Plus (firmware 8.1.7); other firmware may ignore it or refuse the change.
- **Bluetooth:** tested with an 8BitDo Micro, which pairs without a PIN. A remote that needs a PIN shows Android's own pairing dialog. If pairing or forgetting does not work for your remote, use **Open Android Bluetooth settings**.
- **After a KOReader update:** the plugin adjusts KOReader's internal Wi-Fi handling. If **Settings → Network → Wi-Fi connection** opens Android settings again after updating KOReader, the update changed that code. The **Nook Wi-Fi** menu still works; please report the problem.

## Privacy

- **Passwords:** a Wi-Fi password goes from KOReader straight to Android. The helper never logs or stores it, or sends it anywhere. The plugin does not save it in KOReader's settings.
- **Debug logging:** KOReader's on-screen keyboard writes every key press to the system log when debug logging is on. The password dialog switches debug logging off while it is open and restores it afterwards.
- **Who can use the helper:** the helper only accepts requests from KOReader. Anything running inside KOReader can use it, including other plugins and patches you install, so it can control Wi-Fi and Bluetooth, pair Bluetooth devices, open the Nook home screen, set when the Nook powers off (only to one of the menu's choices), and read nearby network and device names (which can reveal roughly where you are). Only install KOReader plugins you trust.

## Update

Install the new helper APK over the old one, and replace the `nookwifi.koplugin` folder with the new one. Then exit KOReader and open it again. Your location permission is kept.

Always update the helper and the plugin together; **Helper info** shows both versions so you can check. If the two cannot work together, the plugin says to update both, or that the helper is out of date.

## Remove

1. Delete the `koreader/plugins/nookwifi.koplugin` folder.
2. Uninstall **Nook Wi-Fi Helper** in Android Settings → Apps, or over USB with `adb uninstall dev.nookwifi.helper`.
3. Exit KOReader and open it again. KOReader's Wi-Fi items go back to opening Android settings.

Networks you joined, and remotes you paired, stay saved in Android. If you set **Nook power off after sleeping**, uninstalling the helper turns it back to never (Android removes the setting, and the Nook treats a missing setting as never).

## Troubleshooting

| You see | What to do |
|---|---|
| No **Nook Wi-Fi** item under Settings → Network | Check the folder is `koreader/plugins/nookwifi.koplugin` (not nested inside another folder). Then exit KOReader and open it again. |
| "Nook Wi-Fi Helper is not installed." | Install the helper APK. |
| Network names show as "(name hidden)", or scanning asks for permission | Do install step 3 (allow location access). |
| "…different versions. Update both." | Install the helper and plugin from the same release. |
| "Wrong password for …" on a saved network | Forget the network in Android Wi-Fi settings, then join it again from **Scan for networks…**. |
| "allow Nook Wi-Fi Helper to modify system settings" | Tap **Open**, turn the switch on, go back to KOReader, and choose again. Or over USB: `adb shell appops set dev.nookwifi.helper WRITE_SETTINGS allow`. |
| "Could not connect to X. Connected to Y instead." | Android could not reach X (out of range or rejected) and went back to another saved network. |

## Optional: KOReader Home launcher

**Requires KOReader** (`org.koreader.launcher`) to be installed. It is meant only for Nooks that use KOReader. If KOReader is ever missing (for example mid-update), Home shows the recovery screen instead of opening it.

**KOReader Home** is a separate app (`dev.nookkoreader.launcher`), independent of
the Wi-Fi helper and plugin. When selected as the default Home app, it opens
KOReader whenever Home is invoked. It requests no permissions and uses no
network access. It has been tested as the default launcher on a GlowLight 4 Plus:
Home, the recovery screen, recovering from a KOReader crash, rebooting, and **Restart
KOReader** with the patch.

Install `koreader-home-<version>.apk` from `dist/`, and copy
`2-koreader-home.lua` from `dist/` to `koreader/patches/` on the Nook (create the
`patches` folder if it does not exist). Or use:

```sh
make install-launcher
```

The patch turns KOReader's **Exit** into **Restart KOReader**: it returns to Home,
so KOReader reopens. Without it, Android shows whatever app happens to be open
behind KOReader (for example a launcher you opened from the recovery screen). It
does nothing unless KOReader Home is the default Home app; then the menu item keeps
its usual name, **Exit**, and works as before. KOReader loads patches at startup, so
exit and reopen KOReader once after copying it.

Installing does not select KOReader Home as your default. Android may clear the
previous Home preference when a new Home app is installed; if prompted, pick the
launcher you were using before. Keep at least one other launcher installed (for
example the Nook's own launcher or Olauncher) as a way back.

Open **KOReader Home** from your other launcher to reach its recovery screen. It offers:

- **Open KOReader and resume Home**: enables automatic opening again and opens KOReader
  through Home.
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
presses within 30 seconds open recovery, which also protects against a KOReader
that keeps closing: the third return opens recovery instead of KOReader. With the
patch installed, **Restart KOReader** counts as a Home press too, so using it 3 times
within 30 seconds also opens recovery. Recovery
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
adb shell rm /sdcard/koreader/patches/2-koreader-home.lua
```

The patch is harmless if left behind: it does nothing unless KOReader Home is the default.

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
