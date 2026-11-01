#!/bin/sh
# Installs KOReader-first Nook on a Nook GlowLight 4 Plus over USB (ADB), from the
# release files next to this script, and sets the permissions the apps need.
#
#   sh install.sh
#
# It asks what to install, then shows a summary before changing anything: KOReader (the
# build this project is tested with, if KOReader is missing), the Nook page-button and
# frontlight setup, the KOReader Home launcher (and whether to make it the default Home
# app), and the App Store and ZenFM plugins (downloaded from their GitHub releases).
# Without a terminal to ask on, it takes the default answers and never changes the
# default Home app. Run it with only the Nook connected, with USB debugging turned on.
# It never uninstalls anything.
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
SETTINGS=/sdcard/koreader/settings
# Nook setup for KOReader: the page buttons (key map), and KOReader's own frontlight
# sliders instead of Android's dialog (patch).
NOOK_PATCHES="2-nook-frontlight-widget.lua"
EVENT_MAP=event_map.lua
# Third-party plugins, from their own GitHub releases (newest stable release). Neither
# project publishes checksums; the files come over HTTPS from their release pages. An
# installed copy is never replaced: both have their own updaters, and App Store keeps its
# settings (including an optional GitHub token) inside its plugin folder.
APPSTORE_REPO=omer-faruq/appstore.koplugin
ZENFM_REPO=xZenLabs/zen-fm
ZENFM_PKG=org.zenlabs.zenfm

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage 0 ;;
        *) echo "This script takes no options: it asks what to install. ($arg)" >&2; usage 1 ;;
    esac
done

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Asks a yes/no question; $2 is the default (y or n), taken on Enter or without a terminal.
interactive=false
[ -t 0 ] && interactive=true
ask() {
    if ! $interactive; then [ "$2" = y ]; return; fi
    if [ "$2" = y ]; then hint='[Y/n]'; else hint='[y/N]'; fi
    while :; do
        printf '%s %s ' "$1" "$hint"
        read -r answer || answer=
        case "$answer" in
            '') [ "$2" = y ]; return ;;
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) say "Please answer y or n." ;;
        esac
    done
}

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
# At most one: prints it, or nothing if there is none.
optional() {
    label=$2
    # shellcheck disable=SC2086 # the pattern is meant to expand
    set -- $1
    [ -e "$1" ] || return 0
    [ $# -eq 1 ] || die "More than one $label here: $*. Keep only one release in this folder."
    printf '%s\n' "$1"
}
helper_apk=$(one 'nookwifi-helper-*.apk' 'nookwifi-helper-<version>.apk')
plugin_zip=$(one 'nookwifi.koplugin-*.zip' 'nookwifi.koplugin-<version>.zip')
launcher_apk=$(optional 'koreader-home-*.apk' 'koreader-home-<version>.apk')
koreader_apk=$(optional 'koreader-android-*.apk' 'koreader-android-<version>.apk')
[ -e "$PATCH" ] || launcher_apk=
nook_files=true
for f in $NOOK_PATCHES $EVENT_MAP; do [ -e "$f" ] || nook_files=false; done

command -v adb >/dev/null 2>&1 || die "adb not found. Install Android platform-tools (see the README) and try again."
command -v unzip >/dev/null 2>&1 || die "unzip not found."
sum=
if [ -e SHA256SUMS ]; then
    if command -v shasum >/dev/null 2>&1; then sum="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"
    else die "No shasum or sha256sum to check SHA256SUMS."; fi
fi
# Checks one file against SHA256SUMS (if there is one). No file name has spaces.
verify() {
    [ -n "$sum" ] || return 0
    grep -q "  $1\$" SHA256SUMS || die "$1 is not listed in SHA256SUMS."
    grep "  $1\$" SHA256SUMS | $sum -c - >/dev/null 2>&1 || die "$1 does not match SHA256SUMS. Download it again."
}

step "Checking the Nook"
# Only device records ("serial<TAB>state"): when adb starts its server it also prints
# "* daemon not running; starting now..." lines, which some versions send to stdout.
devices=$(adb devices 2>/dev/null | awk -F '\t' 'NF >= 2 && $1 != ""')
[ -n "$devices" ] || die "No device found. Connect the Nook by USB and turn on USB debugging (see the README)."
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
    say "This is not a Nook GlowLight 4 Plus (model $model, Android API $sdk). Nothing here is tested on it."
    $interactive || die "Not a Nook GlowLight 4 Plus; stopping."
    ask "Continue anyway?" n || die "Stopped; nothing was changed."
fi
installed() { shell pm list packages "$1" | grep -qx "package:$1"; }
# Prints the installed plugin's version from its _meta.lua, or nothing if it is not there.
plugin_version() {
    shell "cat $PLUGINS/$1/_meta.lua 2>/dev/null" | sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' | head -n 1
}
koreader=false
installed "$KOREADER_PKG" && koreader=true
appstore_have=$(plugin_version appstore.koplugin)
zenfm_have=$(plugin_version zenfm.koplugin)
if [ -n "$zenfm_have" ] && ! installed "$ZENFM_PKG"; then zenfm_have=; fi
if $koreader; then say "Nook GlowLight 4 Plus with KOReader found."; else say "Nook GlowLight 4 Plus found; KOReader is not installed."; fi

step "Choosing what to install"
say "Always: Nook Wi-Fi Helper and the Nook Wi-Fi KOReader plugin, with their permissions."
install_koreader=false
nook_setup=false
launcher=false
set_home=false
appstore=false
zenfm=false
if ! $koreader; then
    if [ -n "$koreader_apk" ]; then
        version=${koreader_apk#koreader-android-*-}
        version=${version%.apk}
        say ""
        say "KOReader $version is in this folder: the build this project is tested with."
        ask "Install KOReader?" y && install_koreader=true
    else
        say "Warning: KOReader is not installed and its APK is not in this folder. Install KOReader before using the plugin."
    fi
fi
if $nook_files; then
    say ""
    say "Page buttons and frontlight: the Nook's page buttons turn pages in KOReader, and"
    say "KOReader's own brightness and warmth sliders replace Android's light dialog."
    ask "Set them up?" y && nook_setup=true
fi
if [ -n "$launcher_apk" ]; then
    say ""
    if $koreader || $install_koreader; then
        say "KOReader Home: a small launcher that opens KOReader whenever you press Home, so the"
        say "Nook starts in KOReader. KOReader's Exit becomes Restart KOReader."
        if ask "Install KOReader Home?" n; then
            launcher=true
            say "As the default Home app, it opens KOReader at start-up and on every Home press."
            say "You can switch back later (the README shows how)."
            ask "Make KOReader Home the default Home app now?" n && set_home=true
        fi
    else
        say "Skipping KOReader Home: it needs KOReader."
    fi
fi
say ""
if [ -n "$appstore_have" ]; then
    say "App Store $appstore_have is already installed (it updates itself)."
else
    say "App Store: browse and install community KOReader plugins and patches (from GitHub)."
    ask "Install App Store?" n && appstore=true
fi
say ""
if [ -n "$zenfm_have" ]; then
    say "ZenFM $zenfm_have is already installed (it updates itself)."
else
    say "ZenFM: manage the Nook's files from your computer's web browser (from GitHub)."
    ask "Install ZenFM?" n && zenfm=true
fi

step "Summary"
$install_koreader && say "- KOReader $version"
say "- Nook Wi-Fi Helper and the Nook Wi-Fi plugin, with their permissions"
if $koreader || $install_koreader; then say "- KOReader's permissions for the frontlight and its files"; fi
$nook_setup && say "- Page buttons and frontlight setup"
if $launcher; then
    if $set_home; then say "- KOReader Home, as the default Home app"; else say "- KOReader Home (not the default Home app)"; fi
fi
$appstore && say "- App Store (downloaded from github.com/$APPSTORE_REPO)"
$zenfm && say "- ZenFM and its companion app (downloaded from github.com/$ZENFM_REPO)"
if $interactive; then
    ask "Go ahead?" y || { say "Stopped; nothing was changed."; exit 0; }
fi

step "Checking the release files"
files="$helper_apk $plugin_zip"
$install_koreader && files="$files $koreader_apk"
$nook_setup && files="$files $NOOK_PATCHES $EVENT_MAP"
$launcher && files="$files $launcher_apk $PATCH"
if [ -n "$sum" ]; then
    for f in $files; do verify "$f"; done
    say "Checksums match."
else
    say "No SHA256SUMS here; skipping the checksum check."
fi
if $appstore || $zenfm; then
    command -v curl >/dev/null 2>&1 || die "curl not found; it is needed to download App Store and ZenFM."
fi

# adb install prints its own errors; explain the one people hit when switching builds.
install_apk() {
    out=$(adb install -r "$1" 2>&1) && { say "Installed ${1##*/}."; return 0; }
    printf '%s\n' "$out" >&2
    case "$out" in
        *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
            die "The $2 already on the Nook is signed with a different key (for example a build from source).
Uninstall it first with: adb uninstall $3
That also removes its permissions; run this script again afterwards to restore them." ;;
    esac
    die "Could not install $1."
}

if $install_koreader; then
    step "Installing KOReader"
    install_apk "$koreader_apk" "KOReader" "$KOREADER_PKG"
    koreader=true
fi

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

if $nook_setup; then
    step "Installing the Nook button and frontlight setup"
    adb shell mkdir -p "$PATCHES" "$SETTINGS"
    for f in $NOOK_PATCHES; do
        adb push "$f" "$PATCHES/" >/dev/null 2>&1 || die "Could not copy $f to the Nook."
        say "Patch copied to $PATCHES/$f."
    done
    # The key map is a personal settings file: never overwrite one that differs from ours.
    # Compared without comments and spacing, so only a different mapping counts.
    mappings() { sed -e 's/--.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"; }
    if adb pull "$SETTINGS/$EVENT_MAP" "$tmp/$EVENT_MAP.nook" >/dev/null 2>&1; then
        if [ "$(mappings "$EVENT_MAP")" = "$(mappings "$tmp/$EVENT_MAP.nook")" ]; then
            say "Key map already in place: $SETTINGS/$EVENT_MAP."
        else
            say "Kept your own $SETTINGS/$EVENT_MAP (it differs from this release's $EVENT_MAP)."
            say "To use the release's key map, copy $EVENT_MAP from this folder over it."
        fi
    else
        adb push "$EVENT_MAP" "$SETTINGS/" >/dev/null 2>&1 || die "Could not copy $EVENT_MAP to the Nook."
        say "Key map copied to $SETTINGS/$EVENT_MAP."
    fi
fi

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

# Prints the newest stable release's tag, then the download URL of its asset matching the
# shell pattern $2.
latest_asset() {
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1/releases/latest") \
        || die "Could not read the latest release of $1 from GitHub."
    tag=$(printf '%s\n' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    url=
    for u in $(printf '%s\n' "$json" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p'); do
        case "${u##*/}" in $2) url=$u; break ;; esac
    done
    [ -n "$tag" ] && [ -n "$url" ] || die "The latest release of $1 has no file matching $2."
    printf '%s\n%s\n' "$tag" "$url"
}
download() {
    curl -fsSL -o "$2" "$1" || die "Could not download $1."
}
# Unzips $1, checks it holds the folder $2 (with a main.lua), and copies it to the Nook.
push_plugin_zip() {
    rm -rf "$tmp/extra" && mkdir -p "$tmp/extra"
    unzip -q "$1" -d "$tmp/extra"
    [ -f "$tmp/extra/$2/main.lua" ] || die "$(basename "$1") does not contain $2."
    adb push "$tmp/extra/$2" "$PLUGINS/" >/dev/null 2>&1 || die "Could not copy $2 to the Nook."
}

if $appstore; then
    step "Installing App Store"
    # `set -- $(...)` would hide a failure inside the substitution, so capture it first.
    found=$(latest_asset "$APPSTORE_REPO" 'appstore.koplugin.zip') || exit 1
    set -- $found
    download "$2" "$tmp/appstore.koplugin.zip"
    push_plugin_zip "$tmp/appstore.koplugin.zip" appstore.koplugin
    say "App Store $1 copied to $PLUGINS/appstore.koplugin (from github.com/$APPSTORE_REPO)."
fi

if $zenfm; then
    step "Installing ZenFM"
    # On Android, ZenFM is a KOReader plugin plus a companion app that runs its server;
    # install both from the same release so they match.
    found=$(latest_asset "$ZENFM_REPO" 'ZenFM-koreader-android-*.zip') || exit 1
    set -- $found
    zen_tag=$1 zen_zip_url=$2
    found=$(latest_asset "$ZENFM_REPO" 'ZenFM-android-*.apk') || exit 1
    set -- $found
    zen_apk_url=$2
    download "$zen_apk_url" "$tmp/${zen_apk_url##*/}"
    install_apk "$tmp/${zen_apk_url##*/}" "ZenFM companion app" "$ZENFM_PKG"
    download "$zen_zip_url" "$tmp/zenfm.zip"
    push_plugin_zip "$tmp/zenfm.zip" zenfm.koplugin
    say "ZenFM $zen_tag copied to $PLUGINS/zenfm.koplugin (from github.com/$ZENFM_REPO)."
    say "The first time you start it, approve the \"Start ZenFM?\" prompt (see its README)."
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
