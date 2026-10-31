#!/bin/sh
# Installs KOReader-first Nook on a Nook GlowLight 4 Plus over USB (ADB), from the
# release files next to this script, and sets the permissions the apps need.
#
#   sh install.sh                     helper + plugin + permissions
#   sh install.sh --launcher          also the KOReader Home launcher and its KOReader patch
#   sh install.sh --launcher --set-home
#                                     ...and make the launcher the default Home app
#
# It also gives KOReader the permissions its frontlight (brightness and warmth) and file
# access need. Run it with only the Nook connected, with USB debugging allowed. It never
# uninstalls anything, and never changes the default Home app unless you pass --set-home.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

HELPER_PKG=dev.nookwifi.helper
LAUNCHER_PKG=dev.nookkoreader.launcher
KOREADER_PKG=org.koreader.launcher
NOOK_MODEL=BNRV1300
PLUGINS=/sdcard/koreader/plugins
PATCHES=/sdcard/koreader/patches
PATCH=2-koreader-home.lua

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

launcher=false
set_home=false
force=false
for arg in "$@"; do
    case "$arg" in
        --launcher) launcher=true ;;
        --set-home) set_home=true ;;
        --force) force=true ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $arg" >&2; usage 1 ;;
    esac
done
if $set_home && ! $launcher; then
    echo "--set-home needs --launcher." >&2
    exit 1
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")"

# Exactly one release file of each kind, next to this script.
one() {
    label=$2
    # shellcheck disable=SC2086 # the pattern is meant to expand
    set -- $1
    [ -e "$1" ] || die "$label not found next to this script."
    [ $# -eq 1 ] || die "More than one $label here: $*. Keep only one release in this folder."
    printf '%s\n' "$1"
}
helper_apk=$(one 'nookwifi-helper-*.apk' 'nookwifi-helper-<version>.apk')
plugin_zip=$(one 'nookwifi.koplugin-*.zip' 'nookwifi.koplugin-<version>.zip')
if $launcher; then
    launcher_apk=$(one 'koreader-home-*.apk' 'koreader-home-<version>.apk')
    [ -e "$PATCH" ] || die "$PATCH not found next to this script."
fi

step "Checking the release files"
command -v adb >/dev/null 2>&1 || die "adb not found. Install Android platform-tools and try again."
command -v unzip >/dev/null 2>&1 || die "unzip not found."
if [ -e SHA256SUMS ]; then
    if command -v shasum >/dev/null 2>&1; then sum="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"
    else die "No shasum or sha256sum to check SHA256SUMS."; fi
    # Only the files this run installs; SHA256SUMS may list more. No file name has spaces.
    files="$helper_apk $plugin_zip"
    if $launcher; then files="$files $launcher_apk $PATCH"; fi
    for f in $files; do
        grep -q "  $f\$" SHA256SUMS || die "$f is not listed in SHA256SUMS."
        grep "  $f\$" SHA256SUMS | $sum -c - >/dev/null 2>&1 || die "$f does not match SHA256SUMS. Download it again."
    done
    say "Checksums match."
else
    say "No SHA256SUMS here; skipping the checksum check."
fi

step "Checking the Nook"
devices=$(adb devices | sed '1d' | awk 'NF')
[ -n "$devices" ] || die "No device found. Connect the Nook by USB and allow USB debugging."
[ "$(printf '%s\n' "$devices" | wc -l | tr -d ' ')" -eq 1 ] \
    || die "More than one device is connected. Connect only the Nook."
case "$devices" in
    *unauthorized*) die "The Nook has not allowed this computer yet. Unlock it, accept the USB debugging prompt, and try again." ;;
    *offline*) die "The Nook is offline. Reconnect the cable and try again." ;;
esac
shell() { adb shell "$@" | tr -d '\r'; }
model=$(shell getprop ro.product.model)
sdk=$(shell getprop ro.build.version.sdk)
if [ "$model" != "$NOOK_MODEL" ] || [ "$sdk" != 27 ]; then
    $force || die "This is not a Nook GlowLight 4 Plus (model $model, Android API $sdk). Use --force to install anyway."
    say "Warning: model $model, API $sdk is untested. Continuing because of --force."
fi
installed() { shell pm list packages "$1" | grep -qx "package:$1"; }
koreader=false
if installed "$KOREADER_PKG"; then
    koreader=true
    say "Nook GlowLight 4 Plus with KOReader found."
else
    $launcher && die "KOReader ($KOREADER_PKG) is not installed. The launcher needs it; install KOReader first."
    say "Warning: KOReader ($KOREADER_PKG) is not installed. Install it before using the plugin."
fi

# adb install prints its own errors; explain the one people hit when switching builds.
install_apk() {
    out=$(adb install -r "$1" 2>&1) && { say "Installed $1."; return 0; }
    printf '%s\n' "$out" >&2
    case "$out" in
        *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
            die "The $2 already on the Nook is signed with a different key (for example a build from source).
Uninstall it first with: adb uninstall $3
That also removes its permissions; run this script again afterwards to restore them." ;;
    esac
    die "Could not install $1."
}

step "Installing Nook Wi-Fi Helper"
install_apk "$helper_apk" "Nook Wi-Fi Helper" "$HELPER_PKG"

step "Setting the helper's permissions"
# Location: Android only shows Wi-Fi network names and nearby Bluetooth devices to apps
# that have it. The helper never uses your location.
adb shell pm grant "$HELPER_PKG" android.permission.ACCESS_COARSE_LOCATION
say "Location access: allowed."
# Modify system settings: only for Nook power off after sleeping.
adb shell appops set "$HELPER_PKG" WRITE_SETTINGS allow
say "Modify system settings: allowed."

if $koreader; then
    step "Setting KOReader's permissions"
    # Modify system settings: KOReader changes the frontlight brightness and warmth (and
    # its own screen timeout) through Android's system settings. Without it, the light
    # controls do nothing.
    adb shell appops set "$KOREADER_PKG" WRITE_SETTINGS allow
    say "Modify system settings (frontlight): allowed."
    # Storage: KOReader asks for this on its first start; granting it here skips the prompt.
    adb shell pm grant "$KOREADER_PKG" android.permission.READ_EXTERNAL_STORAGE
    adb shell pm grant "$KOREADER_PKG" android.permission.WRITE_EXTERNAL_STORAGE
    say "Storage access: allowed."
fi

step "Installing the KOReader plugin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$plugin_zip" -d "$tmp"
[ -f "$tmp/nookwifi.koplugin/main.lua" ] || die "$plugin_zip does not contain nookwifi.koplugin."
adb shell mkdir -p "$PLUGINS"
# Replace the folder, so files removed in a newer version do not linger. It holds only
# the plugin's code; its settings live in KOReader's own settings file.
adb shell rm -rf "$PLUGINS/nookwifi.koplugin"
adb push "$tmp/nookwifi.koplugin" "$PLUGINS/" >/dev/null 2>&1 || die "Could not copy the plugin to the Nook."
say "Plugin copied to $PLUGINS/nookwifi.koplugin."

if $launcher; then
    step "Installing the KOReader Home launcher"
    install_apk "$launcher_apk" "KOReader Home launcher" "$LAUNCHER_PKG"
    adb shell mkdir -p "$PATCHES"
    adb push "$PATCH" "$PATCHES/" >/dev/null 2>&1 || die "Could not copy $PATCH to the Nook."
    say "Patch copied to $PATCHES/$PATCH."
    if $set_home; then
        adb shell cmd package set-home-activity "$LAUNCHER_PKG/.HomeActivity" >/dev/null
        home=$(shell cmd package resolve-activity --brief -a android.intent.action.MAIN \
            -c android.intent.category.HOME | tail -n 1)
        [ "$home" = "$LAUNCHER_PKG/.HomeActivity" ] || die "Could not make the launcher the default Home app (Home is $home)."
        say "Default Home app: KOReader Home."
    else
        say "Not changed: the default Home app. Android may ask which Home app to use the next time you press Home."
    fi
fi

step "Done"
say "Exit KOReader and open it again: it loads plugins and patches only when it starts."
say "Then look for Settings -> Network -> Nook Wi-Fi."
if $set_home; then
    say ""
    say "To make another launcher the default again, list them with"
    say "  adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    say "and set one, for example Olauncher:"
    say "  adb shell cmd package set-home-activity app.olauncher/.MainActivity"
fi
