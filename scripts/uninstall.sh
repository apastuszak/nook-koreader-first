#!/bin/sh
# Removes KOReader-first Nook from a Nook over USB (ADB).
#
#   sh uninstall.sh
#
# It looks at what is installed, asks what to remove, and shows a summary before
# changing anything: Nook Wi-Fi (the helper app and its KOReader plugin), the KOReader
# Home launcher (choosing another default Home app first, if it is the default), the
# page-button and frontlight setup, the reading fonts, and optionally KOReader itself
# with its koreader folder (books in that folder are moved to the NOOK folder first). Run
# it in a terminal, with only the Nook connected and USB debugging turned on.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

HELPER_PKG=dev.nookwifi.helper
LAUNCHER_PKG=dev.nookkoreader.launcher
LAUNCHER_HOME=$LAUNCHER_PKG/.HomeActivity
NOOK_HOME=com.nook.partner/.FacadeLauncherActivity
PLUGINS=/sdcard/koreader/plugins
PATCHES=/sdcard/koreader/patches
KOREADER_PKG=org.koreader.launcher
KOREADER_DIR=/sdcard/koreader
BOOKS_DIR=/sdcard/NOOK
# Where each book is going ("<path in koreader><TAB><path in NOOK>"), written before the
# move, so a retry after an interrupted run puts leftover highlights beside the right book.
# A top-level .log, so it is never moved, and it is deleted with the koreader folder.
JOURNAL=$KOREADER_DIR/uninstall-moves.log
TAB=$(printf '\t')
ZENFM_PKG=org.zenlabs.zenfm
SETTINGS=/sdcard/koreader/settings
PLUGIN=nookwifi.koplugin
HOME_PATCH=2-koreader-home.lua
NOOK_PATCHES="2-nook-frontlight-widget.lua"
EVENT_MAP=event_map.lua
FONTS=/sdcard/koreader/fonts
FONT_FAMILIES="AtkinsonHyperlegibleNext Lexend Literata Bitter"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage 0 ;;
        *) echo "This script takes no options: it asks what to remove. ($arg)" >&2; usage 1 ;;
    esac
done

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Removing things needs answers: unlike install.sh, there are no safe defaults to take
# without a terminal.
[ -t 0 ] || die "This script asks before removing anything; run it in a terminal."
# Asks a yes/no question; $2 is the default (y or n), taken on Enter.
ask() {
    if [ "$2" = y ]; then hint='[Y/n]'; else hint='[y/N]'; fi
    while :; do
        printf '%s %s ' "$1" "$hint"
        # End of input (Ctrl-D) is not an answer: stop rather than take the default.
        read -r answer || { say ""; die "No answer; stopping."; }
        case "$answer" in
            '') [ "$2" = y ]; return ;;
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) say "Please answer y or n." ;;
        esac
    done
}
# Asks for a number from 1 to $1 (1 on Enter) and sets $choice.
choose() {
    while :; do
        printf 'Choose 1-%s [1] ' "$1"
        read -r choice || { say ""; die "No answer; stopping."; }
        [ -n "$choice" ] || choice=1
        case "$choice" in
            *[!0-9]*) ;;
            *) [ "$choice" -ge 1 ] && [ "$choice" -le "$1" ] && return 0 ;;
        esac
        say "Please enter a number from 1 to $1."
    done
}

cd "$(dirname "$0")"
command -v adb >/dev/null 2>&1 || die "adb not found. Install Android platform-tools (see the README) and try again."

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
    *"no permissions"*) die "This computer may not open the Nook's USB connection (on Linux, add a udev rule: see the README)." ;;
esac
# Never lets adb read this script's input (it would swallow lists read in loops).
shell() { adb shell "$@" </dev/null | tr -d '\r'; }
model=$(shell getprop ro.product.model)
[ -n "$model" ] || die "Could not read the device's model over adb. Reconnect the Nook and try again."
installed() { shell pm list packages "$1" | grep -qx "package:$1"; }
exists() { [ -n "$(shell "[ -e $1 ] && echo yes")" ]; }
# The Home app Android opens now: a component, or Android's chooser if there is no default.
default_home() {
    shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n 1
}

helper=false; installed "$HELPER_PKG" && helper=true
plugin=false; exists "$PLUGINS/$PLUGIN" && plugin=true
launcher=false; installed "$LAUNCHER_PKG" && launcher=true
home_patch=false; exists "$PATCHES/$HOME_PATCH" && home_patch=true
nook_patches=
for f in $NOOK_PATCHES; do exists "$PATCHES/$f" && nook_patches="$nook_patches $f"; done
# The key map is a personal settings file: only one with the same mappings as this
# release's is ours to remove. Compared without comments and spacing.
event_map=none
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if adb pull "$SETTINGS/$EVENT_MAP" "$tmp/$EVENT_MAP.nook" >/dev/null 2>&1; then
    mappings() { sed -e 's/--.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"; }
    if [ -e "$EVENT_MAP" ] && [ "$(mappings "$EVENT_MAP")" = "$(mappings "$tmp/$EVENT_MAP.nook")" ]; then
        event_map=ours
    else
        event_map=theirs
    fi
fi
# Only font folders this project installed: they carry its SOURCE.txt.
fonts=
for f in $FONT_FAMILIES; do
    [ -z "$(shell "grep -q 'KOReader-first Nook' $FONTS/$f/SOURCE.txt 2>/dev/null && echo yes")" ] || fonts="$fonts $f"
done
home=$(default_home)
koreader=false; installed "$KOREADER_PKG" && koreader=true
koreader_dir=false; exists "$KOREADER_DIR" && koreader_dir=true
zenfm_app=false; installed "$ZENFM_PKG" && zenfm_app=true
case "$model" in
    BNRV1300) say "Found a Nook GlowLight 4 Plus." ;;
    BNRV1100) say "Found a Nook GlowLight 4." ;;
    *) say "Found a Nook ($model)." ;;
esac

if ! $helper && ! $plugin && ! $launcher && ! $home_patch && [ -z "$nook_patches" ] && [ "$event_map" != ours ] \
    && [ -z "$fonts" ] && ! $koreader && ! $koreader_dir; then
    say "Nothing from KOReader-first Nook is installed."
    exit 0
fi

# KOReader's own folders inside the koreader folder (datastorage.lua, plus the Android
# build's help, scripts and fonts): deleted with it, never moved. Screenshots are moved.
KOREADER_OWN='cache|clipboard|data|docsettings|fonts|hashdocsettings|help|history|ota|patches|plugins|scripts|settings|styletweaks'
# Lists paths in the koreader folder (one per line, relative to it) with find's tests $1,
# leaving out KOReader's own folders and anything inside a .sdr folder. Fails unless the
# listing completed: the Nook's shell must report find's success, or nothing could be
# told apart from an empty folder.
list_koreader() {
    out=$(shell "cd $KOREADER_DIR && find . $1; echo END:\$?") || return 1
    [ "$(printf '%s\n' "$out" | tail -n 1)" = END:0 ] || return 1
    printf '%s\n' "$out" | sed '$d' | sed 's|^\./||' | grep -v -E "^($KOREADER_OWN)/|\\.sdr/" || true
}
# The user's own files: every file except those in KOReader's own folders, its settings
# and logs at the top, and the .sdr folders (moved with their book, or on their own).
# Anything else is kept, whatever its type.
list_books() {
    files=$(list_koreader "-type f") || return 1
    printf '%s\n' "$files" | grep -v -E '^[^/]*\.(lua|lua\.old|log)$' || true
}
# The path without its file name's extension ("Books/Title.epub" -> "Books/Title"; a
# dot in a folder name, or a name with no extension, is left alone).
stem() {
    case "${1##*/}" in
        ?*.*) printf '%s\n' "${1%.*}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}
# Highlights folders (Title.sdr) whose book is not among $books: from books stored
# elsewhere, or left behind by an earlier run that stopped after moving the book. They
# are moved on their own, so a retry never deletes highlights.
list_orphan_sdrs() {
    sdrs=$(list_koreader "-type d -name '*.sdr'") || return 1
    with_book=$(printf '%s\n' "$books" | while IFS= read -r b; do
        [ -z "$b" ] || printf '%s.sdr\n' "$(stem "$b")"
    done)
    printf '%s\n' "$sdrs" | grep -v -x -F -e "$with_book" -e '' || true
}

step "Choosing what to remove"
remove_koreader=false
remove_wifi=false
remove_launcher=false
remove_setup=false
remove_fonts=false
new_home=
books=
orphans=
if $koreader || $koreader_dir; then
    say ""
    say "KOReader: the app and its $KOREADER_DIR folder, with KOReader's settings, reading"
    say "statistics, dictionaries, fonts and plugins (App Store, ZenFM). Your own files in that"
    say "folder (books and anything else not KOReader's) are moved to $BOOKS_DIR first, each book"
    say "with its highlights; books elsewhere stay where they are."
    if ask "Remove KOReader and its folder?" n; then
        remove_koreader=true
        # Everything else from this project lives in KOReader or its folder.
        if $helper || $plugin; then remove_wifi=true; fi
        if $launcher || $home_patch; then remove_launcher=true; fi
        if [ -n "$nook_patches" ] || [ "$event_map" != none ]; then remove_setup=true; fi
        if $koreader_dir; then
            books=$(list_books) || die "Could not list the files in $KOREADER_DIR. Nothing was changed."
            orphans=$(list_orphan_sdrs) || die "Could not list the files in $KOREADER_DIR. Nothing was changed."
            case "$books$orphans" in
                *"$TAB"*) die "A file or folder name in $KOREADER_DIR contains a tab. Rename or move it by hand first. Nothing was changed." ;;
            esac
        fi
    fi
fi
if ! $remove_koreader && { $helper || $plugin; }; then
    say ""
    say "Nook Wi-Fi: the helper app and its KOReader plugin. KOReader's Wi-Fi items go back to"
    say "opening Android settings, and Nook power off after sleeping goes back to never."
    ask "Remove Nook Wi-Fi?" y && remove_wifi=true
fi
if $launcher || $home_patch; then
    if ! $remove_koreader; then
        say ""
        say "KOReader Home: the launcher that opens KOReader when you press Home."
        ask "Remove KOReader Home?" y && remove_launcher=true
    fi
    if $remove_launcher; then
        if [ "$home" = "$LAUNCHER_HOME" ]; then
            # Every other Home app: skip this launcher, Android's fallback (negative
            # priority) and Settings' own fallback screen. The Nook's own home goes first.
            homes=$(shell cmd package query-activities --brief -a android.intent.action.MAIN \
                -c android.intent.category.HOME \
                | awk '$1 ~ /^priority=/ { split($1, a, "="); pri = a[2] + 0; next }
                       $1 ~ /\// { if (pri >= 0) print $1; pri = 0 }' \
                | grep -v -e "^$LAUNCHER_PKG/" -e '^com\.android\.settings/' || true)
            homes=$( { printf '%s\n' "$homes" | grep -x "$NOOK_HOME" || true
                       printf '%s\n' "$homes" | grep -vx "$NOOK_HOME" || true; } | sed '/^$/d')
            if [ -z "$homes" ]; then
                say "KOReader Home is the default Home app, and there is no other to switch to:"
                say "Android will ask which Home app to use the next time you press Home."
            else
                say "KOReader Home is the default Home app. Which Home app should take its place?"
                n=0
                for c in $homes; do
                    n=$((n + 1))
                    case "$c" in
                        "$NOOK_HOME") label="The Nook's own home screen" ;;
                        app.olauncher/*) label="Olauncher" ;;
                        *) label=${c%%/*} ;;
                    esac
                    say "  $n. $label ($c)"
                done
                choose "$n"
                new_home=$(printf '%s\n' "$homes" | sed -n "${choice}p")
            fi
        fi
    fi
fi
if ! $remove_koreader && { [ -n "$nook_patches" ] || [ "$event_map" = ours ]; }; then
    say ""
    say "Page buttons and frontlight: without them the Nook's page buttons stop turning pages in"
    say "KOReader, and Android's light dialog comes back."
    ask "Remove the page-button and frontlight setup?" n && remove_setup=true
fi
if ! $remove_koreader && [ -n "$fonts" ]; then
    say ""
    say "Reading fonts: Atkinson Hyperlegible Next, Lexend, Literata and Bitter. Books set to"
    say "use them go back to KOReader's default font."
    ask "Remove the reading fonts?" n && remove_fonts=true
fi
if ! $remove_koreader && ! $remove_wifi && ! $remove_launcher && ! $remove_setup && ! $remove_fonts; then
    say ""
    say "Nothing chosen; nothing was changed."
    exit 0
fi

step "Summary"
$remove_wifi && say "- Remove Nook Wi-Fi (helper app and plugin)"
if $remove_launcher; then
    if [ -n "$new_home" ]; then say "- Make $new_home the default Home app"; fi
    say "- Remove KOReader Home (launcher app and its KOReader patch)"
fi
$remove_setup && say "- Remove the page-button and frontlight setup"
$remove_fonts && say "- Remove the reading fonts"
if [ "$event_map" = theirs ] && $remove_setup && ! $remove_koreader; then
    say "  (your own $SETTINGS/$EVENT_MAP differs from this release's and is kept)"
fi
if $remove_koreader; then
    if [ -n "$books" ]; then
        say "- Move $(printf '%s\n' "$books" | wc -l | tr -d ' ') file(s) from $KOREADER_DIR to $BOOKS_DIR:"
        printf '%s\n' "$books" | sed 's/^/    /'
    fi
    if [ -n "$orphans" ]; then
        say "- Move $(printf '%s\n' "$orphans" | wc -l | tr -d ' ') highlights folder(s) whose book is not there to $BOOKS_DIR:"
        printf '%s\n' "$orphans" | sed 's/^/    /'
    fi
    if $koreader; then say "- Uninstall KOReader"; fi
    if $zenfm_app; then say "- Uninstall the ZenFM companion app"; fi
    if $koreader_dir; then say "- Delete $KOREADER_DIR (KOReader's settings, statistics, dictionaries, fonts and plugins)"; fi
    say "Kept: books outside $KOREADER_DIR, and the Nook's own apps."
else
    say "Kept: KOReader, your books and KOReader's settings, and any other plugins."
fi
ask "Go ahead?" n || { say "Stopped; nothing was changed."; exit 0; }

# adb uninstall reports a failure in its output, not always in its exit status.
uninstall_apk() {
    out=$(adb uninstall "$1" 2>&1) || true
    case "$out" in
        *Success*) say "Uninstalled $2." ;;
        *) printf '%s\n' "$out" >&2; die "Could not uninstall $2." ;;
    esac
}

# Quotes $1 for the Nook's shell.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
there() { [ -n "$(shell "[ -e $(q "$1") ] && echo yes")" ]; }
# Moves a file or folder on the Nook, never over an existing one; fails unless it moved.
try_move() {
    ! there "$2" || return 1
    shell "mkdir -p $(q "${2%/*}") && mv $(q "$1") $(q "$2")"
    there "$2" && ! there "$1"
}
move() {
    try_move "$1" "$2" || die "Could not move $1 to $2. Nothing was removed; files moved so far are in $BOOKS_DIR."
}

# Switch the default Home app first: Home never points at a removed app, and once
# KOReader Home is no longer the default it cannot reopen KOReader when KOReader is
# stopped below. A setting, not a removal: it can be switched back.
if $remove_launcher && [ -n "$new_home" ]; then
    adb shell cmd package set-home-activity "$new_home" >/dev/null
    now=$(default_home)
    [ "$now" = "$new_home" ] || die "Could not make $new_home the default Home app (Home is $now). Nothing was removed."
    say "Default Home app: $new_home."
fi

# Stop KOReader before moving anything, so it cannot write into its folder (a book's
# highlights or reading position when paused, a screenshot) after the files are moved.
# Then list again, so anything it wrote since the summary is moved too.
if $remove_koreader && $koreader_dir; then
    if $koreader; then adb shell am force-stop "$KOREADER_PKG"; fi
    books=$(list_books) || die "Could not list the files in $KOREADER_DIR. Nothing was removed."
    orphans=$(list_orphan_sdrs) || die "Could not list the files in $KOREADER_DIR. Nothing was removed."
fi

# Files first: if any move fails, nothing has been removed yet.
if [ -n "$books" ]; then
    step "Moving your files to $BOOKS_DIR"
    printf '%s\n' "$books" | while IFS= read -r b; do
        src=$KOREADER_DIR/$b
        dst=$BOOKS_DIR/$b
        ext=${b#"$(stem "$b")"}
        # Never overwrite: "Title.epub" becomes "Title (2).epub", and so on.
        n=1
        while there "$dst" || there "$(stem "$dst").sdr"; do
            n=$((n + 1))
            dst="$BOOKS_DIR/$(stem "$b") ($n)$ext"
        done
        # Record the destination first: if the connection drops after the move, a retry
        # still knows where the book went.
        [ "$(shell "printf '%s\\t%s\\n' $(q "$b") $(q "${dst#"$BOOKS_DIR"/}") >> $(q "$JOURNAL") && echo OK")" = OK ] \
            || die "Could not record the move of $b in $JOURNAL. Nothing was removed; files moved so far are in $BOOKS_DIR."
        move "$src" "$dst"
        # The book's highlights, notes and reading position (Title.epub -> Title.sdr). If
        # they cannot follow, move the book back: a retry then finds the pair together and
        # moves them to matching names (the book may have been renamed " (n)").
        if there "$(stem "$src").sdr" && ! try_move "$(stem "$src").sdr" "$(stem "$dst").sdr"; then
            try_move "$dst" "$src" || die "Could not move $(stem "$src").sdr to $(stem "$dst").sdr, nor move $dst back. Nothing was removed; the book is at $dst and its highlights at $(stem "$src").sdr."
            die "Could not move $(stem "$src").sdr to $(stem "$dst").sdr; the book was moved back. Nothing was removed; files moved so far are in $BOOKS_DIR."
        fi
        say "Moved $b."
    done || exit 1
fi
if [ -n "$orphans" ]; then
    step "Moving highlights folders to $BOOKS_DIR"
    # Earlier runs' records: fail unless the record could be read (or there is none).
    journal=$(shell "( [ ! -e $(q "$JOURNAL") ] || cat $(q "$JOURNAL") ) && echo END:OK")
    [ "$(printf '%s\n' "$journal" | tail -n 1)" = END:OK ] \
        || die "Could not read $JOURNAL. Nothing was removed; files moved so far are in $BOOKS_DIR."
    journal=$(printf '%s\n' "$journal" | sed '$d')
    printf '%s\n' "$orphans" | while IFS= read -r d; do
        # Beside the book it belongs to, if an earlier run recorded where that book went
        # (it may have been renamed " (n)"); otherwise at the same path.
        went=$(printf '%s\n' "$journal" | while IFS="$TAB" read -r from to; do
            if [ -n "$to" ] && [ "$(stem "$from").sdr" = "$d" ]; then printf '%s\n' "$to"; fi
        done | tail -n 1)
        if [ -n "$went" ]; then base=$(stem "$went"); else base=${d%.sdr}; fi
        dst="$BOOKS_DIR/$base.sdr"
        n=1
        while there "$dst"; do
            n=$((n + 1))
            dst="$BOOKS_DIR/$base ($n).sdr"
        done
        move "$KOREADER_DIR/$d" "$dst"
        say "Moved $d."
    done || exit 1
fi

if $remove_launcher; then
    step "Removing KOReader Home"
    if $launcher; then uninstall_apk "$LAUNCHER_PKG" "KOReader Home"; fi
    if $home_patch; then
        adb shell rm -f "$PATCHES/$HOME_PATCH"
        say "Removed $PATCHES/$HOME_PATCH."
    fi
fi

if $remove_wifi; then
    step "Removing Nook Wi-Fi"
    if $helper; then uninstall_apk "$HELPER_PKG" "Nook Wi-Fi Helper"; fi
    if $plugin; then
        adb shell rm -rf "$PLUGINS/$PLUGIN"
        say "Removed $PLUGINS/$PLUGIN."
    fi
fi

if $remove_setup; then
    step "Removing the page-button and frontlight setup"
    for f in $nook_patches; do
        adb shell rm -f "$PATCHES/$f"
        say "Removed $PATCHES/$f."
    done
    if [ "$event_map" = ours ]; then
        adb shell rm -f "$SETTINGS/$EVENT_MAP"
        say "Removed $SETTINGS/$EVENT_MAP."
    elif [ "$event_map" = theirs ] && ! $remove_koreader; then
        say "Kept your own $SETTINGS/$EVENT_MAP."
    fi
fi

if $remove_fonts; then
    step "Removing the reading fonts"
    for f in $fonts; do
        adb shell rm -rf "$FONTS/$f"
        say "Removed $FONTS/$f."
    done
fi

if $remove_koreader; then
    step "Removing KOReader"
    if $koreader; then uninstall_apk "$KOREADER_PKG" "KOReader"; fi
    if $zenfm_app; then uninstall_apk "$ZENFM_PKG" "the ZenFM companion app"; fi
    if $koreader_dir; then
        adb shell rm -rf "$KOREADER_DIR"
        ! there "$KOREADER_DIR" || die "Could not delete $KOREADER_DIR."
        say "Deleted $KOREADER_DIR."
    fi
fi

step "Done"
if $remove_koreader; then
    if [ -n "$books" ]; then say "Your files from $KOREADER_DIR are in $BOOKS_DIR."; fi
    say "Networks you joined and remotes you paired stay saved in Android."
    exit 0
fi
say "If KOReader is open, exit it and open it again: it loads plugins and patches only when it starts."
say "Networks you joined and remotes you paired stay saved in Android."
