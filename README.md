# KOReader-first Nook

Make a **Barnes & Noble Nook GlowLight 4 Plus** a KOReader-first e-reader: everything you need day to day, from inside KOReader, without going back to the Nook's own software or Android settings. No root is needed.

What you get:

- **Wi-Fi**: turn it on and off, switch between saved networks, and join new ones.
- **Bluetooth page-turner remotes**: Bluetooth on/off, pairing, and keeping Bluetooth on only while you read.
- **Nook power off after sleeping**: let the Nook switch itself off after sleeping for a while.
- **Open Nook home**: jump to the Nook's own home screen when you do need it (the B&N store, the Nook's settings), and press Home to come back.
- **Page buttons and frontlight**: the Nook's four page buttons turn pages in KOReader, and KOReader's own brightness and warmth sliders replace Android's light dialog.
- **KOReader as the Home app** (optional): the Home button opens KOReader, and KOReader's Exit becomes **Restart KOReader**.

The parts:

- **Nook Wi-Fi Helper** (`nookwifi-helper-<version>.apk`): a small Android app that holds the Wi-Fi, Bluetooth and system-settings permissions KOReader does not have.
- **Nook Wi-Fi plugin** (`nookwifi.koplugin-<version>.zip`): the KOReader plugin you actually use: the Wi-Fi, Bluetooth, power-off and Open Nook home menus come from it.
- **KOReader Home** (`koreader-home-<version>.apk`, optional) and its KOReader patch (`2-koreader-home.lua`): see [Optional: KOReader Home launcher](#optional-koreader-home-launcher).
- **Nook setup files** (`event_map.lua`, `2-nook-frontlight-widget.lua`): a KOReader key map and patch; see [Page buttons and frontlight](#page-buttons-and-frontlight).
- **`install.sh`**: installs everything over USB and sets the permissions in one step (see [Quick install over USB](#quick-install-over-usb)).

The helper and plugin keep the names they started with ("Nook Wi-Fi"), because renaming them would break updates of existing installs.

## Requirements

- Nook GlowLight 4 Plus (Android 8.1). It has only been tested on firmware 8.1.7.120.
- KOReader for Android, installed as `org.koreader.launcher`. It has been tested with the nightly build from 3 October 2026 (`v2026.07.2-217-gb44e9b7`). KOReader no longer offers that nightly for download, so each release includes it (`koreader-android-arm-v2026.07.2-217-gb44e9b7.apk`), and the install script can install it for you.
- **For frontlight brightness and warmth, use a KOReader nightly build** for Android. With the stable release, KOReader's brightness and warmth controls do not work on the Nook. Nightly builds are on [KOReader's nightly download page](https://build.koreader.rocks/download/nightly/).

## Install

### Get adb

Installing over USB uses **adb**, from Google's Android platform-tools. Pick your system:

- **Mac**, with [Homebrew](https://brew.sh):
  ```sh
  brew install --cask android-platform-tools
  ```
- **Windows**: nothing to do in advance. If `install.cmd` does not find adb, it offers to download Google's platform-tools into its own folder. To set it up yourself instead, download **SDK Platform-Tools for Windows** from [Google's platform-tools page](https://developer.android.com/tools/releases/platform-tools) and unzip it next to `install.cmd`, so there is a `platform-tools` folder beside it.
- **Linux**, from your distribution:
  ```sh
  sudo apt install adb              # Debian, Ubuntu
  sudo dnf install android-tools    # Fedora
  sudo pacman -S android-tools      # Arch
  ```
  If `adb devices` later shows the Nook as `no permissions`, your system needs udev rules for Android devices: on Debian and Ubuntu, `sudo apt install android-sdk-platform-tools-common`, then unplug and reconnect the Nook.
- **Any system**: [Google's platform-tools page](https://developer.android.com/tools/releases/platform-tools) has downloads for Mac, Windows and Linux. Unzip it and run `adb` from the `platform-tools` folder, or add that folder to your PATH.

### Turn on USB debugging on the Nook

Barnes & Noble hides Android's developer options behind a password-protected screen. On firmware 8.1.7:

1. Tap the **top-right corner** of the screen, then **See All Settings**.
2. Go to **page 2** (the arrow at the lower right), then **About**.
3. Tap the **NOOK logo** five or more times, quickly.
4. When it asks for a password, enter `NOOK-` followed by the Nook's model number:

   | Nook | Password |
   | --- | --- |
   | GlowLight 4 Plus | **`NOOK-BNRV1300`** |
   | GlowLight 4 | `NOOK-BNRV1100` |
   | GlowLight 4e | `NOOK-BNRV1000` (not tested) |

5. Open **Android Development Settings** and turn on **USB debugging**.
6. Connect the Nook to your computer. When the Nook asks **Allow USB debugging?**, allow it (tick "Always allow from this computer" to skip the question next time).

The GlowLight 4 Plus and GlowLight 4 passwords have been tested on those Nooks; other owners report the same ([MobileRead](https://www.mobileread.com/forums/showthread.php?p=4410111)). Older firmware asks for no password. This project is built for the GlowLight 4 Plus and has also been tried on a GlowLight 4, where everything worked. On any Nook other than the 4 Plus, the installer warns and asks before going on.

**Check that adb sees the Nook.** With USB debugging turned on, connect the Nook and run `adb devices` (on Windows, `platform-tools\adb devices` if you unzipped it there). The first time, the Nook asks whether to allow this computer: allow it. The Nook should then be listed as `device`. If it shows `unauthorized`, unlock the Nook and accept the prompt; if it is not listed at all, try another USB cable or port (some cables only charge).

### Quick install over USB

The release's install script does every step below for you, and asks about the optional parts. Put all the release files in one folder and connect the Nook with [USB debugging turned on](#turn-on-usb-debugging-on-the-nook). Then:

- **Mac or Linux** (needs [adb](#get-adb)): `sh install.sh`
- **Windows**: double-click `install.cmd`, or run `install.cmd` in a Command Prompt in that folder. If `adb` is not installed, it offers to download Google's platform-tools for you. Windows may also need a USB driver before it can see the Nook over ADB. The Windows script has not yet been tried on a Windows PC.

It always installs the helper and the plugin, gives them their permissions, and gives KOReader the permissions it needs for the frontlight (brightness and warmth) and for its files. Then it asks, one question at a time (press Enter for the answer in capitals, as in `[Y/n]`):

| Question | Asked when | Default |
|---|---|---|
| Install KOReader? (the [exact build](#requirements) this project is tested with) | KOReader is not installed | Yes |
| Set up the [page buttons and frontlight](#page-buttons-and-frontlight)? | always | Yes |
| Install the reading fonts? ([Atkinson Hyperlegible Next](https://github.com/googlefonts/atkinson-hyperlegible-next), [Lexend](https://github.com/googlefonts/lexend), [Literata](https://github.com/googlefonts/literata) and [Bitter](https://github.com/solmatas/BitterPro), all with italics) | KOReader is, or will be, installed | Yes |
| Install [KOReader Home](#optional-koreader-home-launcher)? | KOReader is, or will be, installed | No |
| Make KOReader Home the default Home app now? | you said yes to KOReader Home | No |
| Install [App Store](https://github.com/omer-faruq/appstore.koplugin)? (browse and install community KOReader plugins and patches) | it is not installed | No |
| Install [ZenFM](https://github.com/xZenLabs/zen-fm)? (manage the Nook's files from your computer's web browser) | it is not installed | No |
| Install the ZenFM companion app? / Install the ZenFM plugin? | only one of ZenFM's two parts is installed (the missing part comes from the same ZenFM release as the installed one) | No |

It then shows a summary and asks **Go ahead?** before changing anything; answer `n` to stop with nothing changed. Run without a terminal (for example from another program), it takes the defaults and never changes the default Home app.

Good to know:

- It never uninstalls anything, and never replaces a KOReader you already have.
- It never overwrites a key map (`koreader/settings/event_map.lua`) you already have, unless it is the same.
- **Reading fonts** go into `koreader/fonts/AtkinsonHyperlegibleNext`, `Lexend`, `Literata` and `Bitter`, each with its license. In KOReader, open a book and pick them under the font menu (the **Aa** tab, then **Font**); Lexend is listed as **Lexend-aalt** (the version with a single-storey "a"). Other fonts in `koreader/fonts` are not touched, and a font folder of the same name that this script did not install is kept as it is.
- **App Store and ZenFM** are separate projects with their own licenses (GPL-3.0 and AGPL-3.0) and support. The script downloads the newest stable release of each from its own GitHub page (for ZenFM, its KOReader plugin and its small companion app). If one is already installed, the script leaves it alone: both can update themselves. If only one of ZenFM's two parts is on the Nook, the script offers just the missing part, from the same ZenFM release, and never replaces the part that is there. Neither publishes checksums, so the downloads are trusted because they come over HTTPS from the projects' own release pages.
- Afterwards, exit KOReader and open it again.

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
5. **Page buttons and frontlight (optional, recommended).** Copy `event_map.lua` to `koreader/settings/` (if you already have an `event_map.lua` there, add its four lines to yours instead), and `2-nook-frontlight-widget.lua` to `koreader/patches/`. Over USB:
   ```sh
   adb shell mkdir -p /sdcard/koreader/patches /sdcard/koreader/settings
   adb push 2-nook-frontlight-widget.lua /sdcard/koreader/patches/
   adb push event_map.lua /sdcard/koreader/settings/
   ```
6. **Exit KOReader and open it again.** On Android, KOReader has no Restart option, and it only loads plugins and patches when it starts.

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

### Page buttons and frontlight

Two small KOReader files; the install script offers to set them up. KOReader reads them when it starts.

- **`event_map.lua`** (in `koreader/settings/`): KOReader's custom key map. It makes the Nook's four **page buttons** turn pages: the upper buttons on both sides go forward, the lower ones back. Bluetooth page turners need no key map.
- **`2-nook-frontlight-widget.lua`** (a patch in `koreader/patches/`): KOReader's own frontlight sliders (brightness and warmth, as on Kindle and Kobo) instead of Android's light dialog. It needs a KOReader nightly build and the "Modify system settings" permission for KOReader (see [Requirements](#requirements); the install script grants it).

To remove them, delete `event_map.lua` from `koreader/settings/` and the patch from `koreader/patches/`, then restart KOReader.

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

### Uninstall script

The release folder has an uninstall script that works like the installer: connect the Nook by USB (with USB debugging on), then run `sh uninstall.sh` on a Mac or Linux, or double-click `uninstall.cmd` on Windows. It looks at what is on the Nook and asks before removing anything:

| Question | Asked when | Default |
|---|---|---|
| Remove KOReader and its folder? (removes everything below too) | KOReader or its `koreader` folder is there | No |
| Remove Nook Wi-Fi? (the helper app and its KOReader plugin) | either is installed, and KOReader stays | Yes |
| Remove KOReader Home? | the launcher or its patch is installed, and KOReader stays | Yes |
| Which Home app should take its place? (a numbered list; the Nook's own home screen first) | KOReader Home is the default Home app | 1 |
| Remove the page-button and frontlight setup? | it is installed, and KOReader stays | No |
| Remove the reading fonts? | they are installed, and KOReader stays | No |
| Go ahead? (after a summary) | always | No |

It switches the default Home app before removing KOReader Home, so Home never points at a removed app. It removes the key map (`koreader/settings/event_map.lua`) only if it is the one this project installed; your own is kept.

**Removing KOReader** also deletes the `koreader` folder: KOReader's settings, reading statistics, dictionaries, your own key map, and its plugins (including App Store and ZenFM; the ZenFM companion app is uninstalled too). Before that, your own files inside the `koreader` folder (everything except KOReader's own folders, settings and logs: books of any format, and anything else you put there) are moved to the `NOOK` folder, keeping their subfolders, each book with its `.sdr` folder (highlights, notes and reading position); a name that is already taken gets " (2)". If the script cannot list the folder completely, or a move fails, it stops before removing anything. Books outside the `koreader` folder stay where they are. Highlights that KOReader keeps inside its own folder (if you changed **Book metadata location** away from the default) are deleted with it.

If you keep KOReader, exit it and open it again afterwards.

### By hand

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

**KOReader** (`koreader-android-arm-<version>.apk` in the releases) is a separate program by the KOReader developers, also under the GNU AGPL v3.0, included unchanged so the install script can install a tested build. Its source code for the included build is KOReader commit [`b44e9b7`](https://github.com/koreader/koreader/tree/b44e9b7); see [third_party/koreader/README.md](third_party/koreader/README.md).

The reading fonts are included in `fonts.zip` in the releases and in [third_party/fonts/](third_party/fonts/). They are licensed under the [SIL Open Font License 1.1](https://openfontlicense.org), not the AGPL; each font's folder holds its `OFL.txt` and a `SOURCE.txt` naming the upstream commit and any changes. **Atkinson Hyperlegible Next** (Copyright 2020-2024 The Atkinson Hyperlegible Next Project Authors) is unchanged. **Lexend** (Copyright 2018 The Lexend Project Authors, Reserved Font Name "RevReading Lexend", which is not used) is the alternate-"a" version from [Octavio Pardo's fork](https://github.com/octaviopardo/lexend/tree/Lexend-a): its upright fonts are unchanged, and its italics are modified versions of the fork's slanted fonts, with only their names and style flags changed (by [scripts/make-lexend-italics.py](scripts/make-lexend-italics.py)) so that KOReader uses them as italics. **Literata** (Copyright 2017 The Literata Project Authors) is unchanged, at its default optical size. **Bitter** (Copyright 2011 The Bitter Project Authors, Reserved Font Name "Bitter Pro", which is not used) is published only as variable fonts, which KOReader shows at their default weight (Thin); the static fonts here are its named weights, cut from Bitter 3.021 by [scripts/make-bitter-static.py](scripts/make-bitter-static.py).
