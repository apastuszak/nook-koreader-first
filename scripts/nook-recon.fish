#!/usr/bin/env fish
# Stage 0 device recon for the Nook GlowLight 4 Plus.
# Read-only, except the optional Wi-Fi toggle test, which restores the original
# Wi-Fi state. Never prints saved Wi-Fi passwords.
#
# Usage: scripts/nook-recon.fish [output-file]

set -l out $argv[1]
test -n "$out"; or set out nook-recon-(date +%Y%m%d-%H%M%S).txt

if not command -q adb
    echo "adb not found on PATH" >&2
    exit 1
end

set -l serials (adb devices | tail -n +2 | string match -rg '^(\S+)\tdevice$')
if test (count $serials) -ne 1
    echo "Expected exactly one connected device, found "(count $serials)":" >&2
    adb devices -l >&2
    exit 1
end
set -gx ANDROID_SERIAL $serials[1]

set -l toggle no
if string match -q '*:*' -- $ANDROID_SERIAL
    echo "Device is connected over the network ($ANDROID_SERIAL); skipping the Wi-Fi toggle test."
else
    read -l -P 'Run the Wi-Fi toggle test? It briefly changes Wi-Fi state and then restores it. [y/N] ' answer
    string match -qi 'y*' -- $answer; and set toggle yes
end

function section
    printf '\n===== %s =====\n' "$argv"
end

function run
    printf '\n$ %s\n' (string join ' ' -- $argv)
    $argv 2>&1
end

function wifi_state
    adb shell dumpsys wifi | head -n 1 | string trim
end

# Polls until dumpsys reports "Wi-Fi is <want>" or 20 s pass.
function wait_wifi --argument-names want
    set -l line
    for i in (seq 20)
        set line (wifi_state)
        if test "$line" = "Wi-Fi is $want"
            echo "Reached '$line' after ~$i s"
            return 0
        end
        sleep 1
    end
    echo "TIMED OUT after 20 s waiting for 'Wi-Fi is $want'; last seen: '$line'"
    return 1
end

begin
    section "Run info"
    echo "Date: "(date)
    echo "Serial: $ANDROID_SERIAL"
    run adb version

    section "1. Connection and root"
    run adb devices -l
    run adb shell id
    run adb shell 'which su; ls -l /system/xbin/su /system/bin/su'
    run adb shell getprop ro.debuggable
    run adb shell getprop ro.secure

    section "2. Firmware"
    for prop in ro.product.model ro.product.manufacturer ro.build.version.release \
            ro.build.version.sdk ro.build.display.id ro.build.version.incremental \
            ro.build.fingerprint
        printf '%s = %s\n' $prop (adb shell getprop $prop | string trim)
    end

    section "3. KOReader packages"
    set -l pkgs (adb shell pm list packages | string trim | string match -rg '^package:(.*koreader.*)$')
    if test (count $pkgs) -eq 0
        echo "No package containing 'koreader' found."
    end
    for pkg in $pkgs
        printf '\n--- %s ---\n' $pkg
        adb shell dumpsys package $pkg | string match -r '.*(?:versionName|versionCode|targetSdk|codePath|firstInstallTime|lastUpdateTime).*' | string trim
        echo "[requested permissions]"
        adb shell dumpsys package $pkg | sed -n '/requested permissions:/,/install permissions:/p' | string trim
        echo "[install permissions]"
        adb shell dumpsys package $pkg | sed -n '/install permissions:/,/User 0:/p' | string trim
        echo "[WIFI permission check]"
        adb shell dumpsys package $pkg | string match -q '*CHANGE_WIFI_STATE*'
        and echo "CHANGE_WIFI_STATE: declared"; or echo "CHANGE_WIFI_STATE: NOT declared"
        adb shell dumpsys package $pkg | string match -q '*ACCESS_WIFI_STATE*'
        and echo "ACCESS_WIFI_STATE: declared"; or echo "ACCESS_WIFI_STATE: NOT declared"
    end

    section "4. Launcher and Nook system apps"
    run adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
    echo
    echo '$ dumpsys activity activities | grep home/launcher'
    adb shell dumpsys activity activities | string match -ri '.*(?:home|launcher).*' | head -n 20
    echo
    echo '$ pm list packages | grep nook/bn/launcher'
    adb shell pm list packages | string trim | string match -ri '.*(?:nook|bn\.|barnes|launcher).*'

    section "5. Location services"
    run adb shell settings get secure location_mode
    run adb shell settings get secure location_providers_allowed
    echo
    echo '$ dumpsys location | head -30'
    adb shell dumpsys location | head -n 30
    echo
    echo '$ pm list packages | grep location/gms/nlp'
    adb shell pm list packages | string trim | string match -ri '.*(?:location|gms|nlp).*'

    section "6. Wi-Fi state"
    run adb shell settings get global wifi_on
    echo
    echo '$ dumpsys wifi | head -5'
    adb shell dumpsys wifi | head -n 5
    echo
    echo '$ dumpsys connectivity | grep NetworkAgentInfo/WIFI'
    adb shell dumpsys connectivity | string match -ri '.*(?:NetworkAgentInfo|WIFI).*' | head -n 5

    section "6b. Wi-Fi toggle test (svc wifi, ADB shell privileges)"
    if test $toggle = yes
        set -l initial (wifi_state)
        echo "Initial: $initial"
        if test "$initial" = "Wi-Fi is enabled"
            run adb shell svc wifi disable
            wait_wifi disabled
            run adb shell svc wifi enable
            wait_wifi enabled
        else
            run adb shell svc wifi enable
            wait_wifi enabled
            run adb shell svc wifi disable
            wait_wifi disabled
        end
        sleep 5
        echo "Final (5 s later, checks firmware didn't flip it back): "(wifi_state)
    else
        echo "Skipped."
    end

    section "7. KOReader data directory"
    run adb shell ls -la /sdcard/koreader/
    run adb shell ls -la /sdcard/koreader/plugins /sdcard/koreader/patches
end 2>&1 | tee $out

echo
echo "Saved to $out"
