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
- **Who can use the helper:** the helper only accepts requests from KOReader.

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

## Building from source

On macOS with Homebrew you need JDK 21, the Android command-line tools (SDK platforms 27 and 35), LuaJIT, and luacheck. `AGENTS.md` lists the exact setup, the verified device behavior, and the design.

```sh
make check     # Android lint, luacheck, offline plugin tests
make install   # debug build of the helper + plugin, onto a USB-connected Nook
make dist      # signed release APK, plugin zip, and SHA256SUMS in dist/
```

`make dist` needs `helper/keystore.properties`, which points at the release signing key. Neither the key nor that file is committed to the repository.
