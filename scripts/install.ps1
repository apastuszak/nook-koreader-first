# Installs KOReader-first Nook on a Nook GlowLight 4 or GlowLight 4 Plus over USB (ADB), from
# the release files next to this script, and sets the permissions the apps need.
#
#   install.cmd      (double-click it, or run it in a Command Prompt)
#
# It asks what to install, then shows a summary before changing anything: KOReader (the
# build this project is tested with, if KOReader is missing), the Nook page-button and
# frontlight setup, four reading fonts, an English dictionary (downloaded from
# reader-dict.com), the user guide (an EPUB), the KOReader Home launcher (and whether to
# make it the default Home app), and the App Store and ZenFM plugins (downloaded from their
# GitHub releases).
# Without a terminal to ask on, it takes the default answers and never changes the
# default Home app. Run it with only the Nook connected, with USB debugging turned on.
# It never uninstalls anything.
#
# Windows version of install.sh: keep the two in step (same questions, checks, steps and
# messages). Runs on Windows PowerShell 5.1 (built into Windows 10 and 11) and PowerShell 7.
# Keep this file ASCII: PowerShell 5.1 misreads other characters in files without a
# byte-order mark.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

$ErrorActionPreference = 'Stop'

$HelperPkg = 'dev.nookwifi.helper'
$LauncherPkg = 'dev.nookkoreader.launcher'
$KoreaderPkg = 'org.koreader.launcher'
# Tested models: GlowLight 4 Plus (BNRV1300) and GlowLight 4 (BNRV1100).
$NookModels = @('BNRV1300', 'BNRV1100')
$Plugins = '/sdcard/koreader/plugins'
$Patches = '/sdcard/koreader/patches'
$Patch = '2-koreader-home.lua'
$Settings = '/sdcard/koreader/settings'
# Nook setup for KOReader: the page buttons (key map), and KOReader's own frontlight
# sliders instead of Android's dialog (patch).
$NookPatches = @('2-nook-frontlight-widget.lua')
$EventMap = 'event_map.lua'
# Reading fonts (SIL Open Font License 1.1), one folder per family with its license, copied
# into KOReader's user font folder.
$Fonts = '/sdcard/koreader/fonts'
$FontsZip = 'fonts.zip'
$FontFamilies = @('AtkinsonHyperlegibleNext', 'Lexend', 'Literata', 'Bitter')
# The user guide as an e-book, copied to the folder the Nook shows over USB, where both
# KOReader's file browser and the Nook's own library find it.
$GuideEpub = 'KOReader-first-Nook-Guide.epub'
$Books = '/sdcard/NOOK'
# English dictionary for KOReader's word lookup: reader.dict, made from Wiktionary (CC BY-SA
# 4.0), the edition with etymologies. Always downloaded from reader-dict.com at install
# time, never shipped with this project (a new edition comes out about once a month, with
# no checksums). KOReader's own "Download dictionaries" uses the same URL and folder name,
# so an update from either place replaces the same copy.
$Dict = '/sdcard/koreader/data/dict'
$DictUrl = 'https://www.reader-dict.com/file/en/dict-en-en.zip'
$DictName = 'reader.dict English'
$DictIfo = 'reader.dict-en.ifo'
# Outside the dictionary folder, so KOReader never sees a half-copied dictionary.
$DictStage = '/sdcard/koreader/data/.reader.dict-download'
# Third-party plugins, from their own GitHub releases (newest stable release). Neither
# project publishes checksums; the files come over HTTPS from their release pages. An
# installed copy is never replaced: both have their own updaters, and App Store keeps its
# settings (including an optional GitHub token) inside its plugin folder.
$AppstoreRepo = 'omer-faruq/appstore.koplugin'
$ZenfmRepo = 'xZenLabs/zen-fm'
$ZenfmPkg = 'org.zenlabs.zenfm'
$PlatformToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

function Show-Usage {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 14 | ForEach-Object { $_ -replace '^# ?', '' }
}
function Say([string]$Text) { Write-Host $Text }
function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" }
function Fail([string]$Text) {
    Write-Host "Error: $Text" -ForegroundColor Red
    exit 1
}

foreach ($arg in $args) {
    if ($arg -in '-h', '--help', '/?') { Show-Usage; exit 0 }
    Write-Host "This script takes no options: it asks what to install. ($arg)"
    Show-Usage
    exit 1
}

# Asks a yes/no question; $Default ('y' or 'n') is taken on Enter or without a terminal.
$interactive = -not [Console]::IsInputRedirected
function Ask([string]$Question, [string]$Default) {
    if (-not $interactive) { return $Default -eq 'y' }
    $hint = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host "$Question $hint"
        if ($answer -eq '') { return $Default -eq 'y' }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Say 'Please answer y or n.'
    }
}

Set-Location -LiteralPath $PSScriptRoot

# Exactly one release file of each kind, next to this script.
function Find-One([string]$Pattern, [string]$Label) {
    $found = @(Get-ChildItem -LiteralPath . -Filter $Pattern -File | Sort-Object Name)
    if ($found.Count -eq 0) { Fail "$Label not found next to this script." }
    if ($found.Count -gt 1) {
        Fail "More than one $Label here: $(($found | ForEach-Object Name) -join ' '). Keep only one release in this folder."
    }
    return $found[0].Name
}
# At most one: its name, or $null if there is none.
function Find-Optional([string]$Pattern, [string]$Label) {
    $found = @(Get-ChildItem -LiteralPath . -Filter $Pattern -File | Sort-Object Name)
    if ($found.Count -gt 1) {
        Fail "More than one $Label here: $(($found | ForEach-Object Name) -join ' '). Keep only one release in this folder."
    }
    if ($found.Count -eq 1) { return $found[0].Name }
    return $null
}
$helperApk = Find-One 'nookwifi-helper-*.apk' 'nookwifi-helper-<version>.apk'
$pluginZip = Find-One 'nookwifi.koplugin-*.zip' 'nookwifi.koplugin-<version>.zip'
$launcherApk = Find-Optional 'koreader-home-*.apk' 'koreader-home-<version>.apk'
$koreaderApk = Find-Optional 'koreader-android-*.apk' 'koreader-android-<version>.apk'
if (-not (Test-Path -LiteralPath $Patch -PathType Leaf)) { $launcherApk = $null }
$nookFiles = $true
foreach ($f in $NookPatches + $EventMap) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $nookFiles = $false }
}
$fontsFile = Test-Path -LiteralPath $FontsZip -PathType Leaf
$guidePresent = Test-Path -LiteralPath $GuideEpub -PathType Leaf

# adb: on the PATH, or in a platform-tools folder next to this script (where the download
# below puts it).
function Find-Adb {
    $local = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $cmd = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}
$adb = Find-Adb
if (-not $adb) {
    Say 'adb (Android platform-tools) was not found.'
    if (-not $interactive) { Fail 'adb is needed. Install Android platform-tools (see the README) and try again.' }
    if (-not (Ask "Download Google's platform-tools into this folder now?" 'y')) {
        Fail 'adb is needed. Install Android platform-tools (see the README) and try again.'
    }
    # Windows PowerShell 5.1 does not enable TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $toolsZip = Join-Path $PSScriptRoot 'platform-tools-latest-windows.zip'
    Say "Downloading $PlatformToolsUrl ..."
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes the download very slow in 5.1
    Invoke-WebRequest -Uri $PlatformToolsUrl -OutFile $toolsZip -UseBasicParsing
    Expand-Archive -LiteralPath $toolsZip -DestinationPath $PSScriptRoot -Force
    Remove-Item -LiteralPath $toolsZip
    $adb = Find-Adb
    if (-not $adb) { Fail 'The download did not contain adb.exe.' }
    Say "adb installed in $(Join-Path $PSScriptRoot 'platform-tools')."
}

$sums = $null
if (Test-Path -LiteralPath 'SHA256SUMS' -PathType Leaf) {
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath 'SHA256SUMS') {
        if ($line -match '^([0-9a-fA-F]{64})  (.+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
}
# Checks one file against SHA256SUMS (if there is one).
function Test-Sum([string]$File) {
    if ($null -eq $sums) { return }
    if (-not $sums.ContainsKey($File)) { Fail "$File is not listed in SHA256SUMS." }
    $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($hash -ne $sums[$File]) { Fail "$File does not match SHA256SUMS. Download it again." }
}

# Runs adb and returns its output (stdout and stderr) as one string, with the exit code in
# $script:AdbExit. Windows PowerShell 5.1 turns a native command's stderr into errors that
# stop the script when $ErrorActionPreference is 'Stop', so lower it for the call.
function Invoke-Adb {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $adb @args 2>&1 | ForEach-Object { "$_" }
        $script:AdbExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return (($out -join "`n") -replace "`r", '').Trim()
}
# Like Invoke-Adb, but stops with a message if adb fails.
function Invoke-AdbChecked([string]$What) {
    $out = Invoke-Adb @args
    if ($script:AdbExit -ne 0) {
        if ($out) { Write-Host $out }
        Fail $What
    }
    return $out
}

Step 'Checking the Nook'
$listing = Invoke-AdbChecked 'adb did not run.' devices
# Only device records ("serial<TAB>state"): the output also holds the header and, when adb
# starts its server, "* daemon not running; starting now..." lines (stderr is merged here).
$devices = @($listing -split "`n" | Where-Object { $_ -match '^\S+\t\S' })
if ($devices.Count -eq 0) { Fail 'No device found. Connect the Nook by USB and turn on USB debugging (see the README).' }
if ($devices.Count -gt 1) { Fail 'More than one device is connected. Connect only the Nook.' }
if ($devices[0] -match 'unauthorized') {
    Fail 'The Nook has not allowed this computer yet. Unlock it, accept the USB debugging prompt, and try again.'
}
if ($devices[0] -match 'offline') { Fail 'The Nook is offline. Reconnect the cable and try again.' }
if ($devices[0] -match 'no permissions') {
    Fail "This computer may not open the Nook's USB connection (on Linux, add a udev rule: see the README)."
}
$model = Invoke-AdbChecked 'Could not read the device model.' shell getprop ro.product.model
$sdk = Invoke-AdbChecked 'Could not read the Android version.' shell getprop ro.build.version.sdk
if (-not $model -or -not $sdk) { Fail "Could not read the device's model over adb. Reconnect the Nook and try again." }
if ($model -notin $NookModels -or $sdk -ne '27') {
    Say "This is not a Nook GlowLight 4 or GlowLight 4 Plus (model $model, Android API $sdk). Nothing here is tested on it."
    if (-not $interactive) { Fail 'Not a Nook GlowLight 4 or GlowLight 4 Plus; stopping.' }
    if (-not (Ask 'Continue anyway?' 'n')) { Fail 'Stopped; nothing was changed.' }
}
function Test-Installed([string]$Package) {
    $out = Invoke-Adb shell pm list packages $Package
    return @($out -split "`n" | Where-Object { $_.Trim() -eq "package:$Package" }).Count -gt 0
}
# The installed plugin's version from its _meta.lua, 'unknown' if its folder is there without
# a readable version, or $null if it is not installed.
function Get-PluginVersion([string]$Plugin) {
    $meta = Invoke-Adb shell "cat $Plugins/$Plugin/_meta.lua 2>/dev/null"
    if ($meta -match '(?<!\w)version\s*=\s*"([^"]*)"') { return $Matches[1] }
    if ((Invoke-Adb shell "[ -d $Plugins/$Plugin ] && echo yes") -eq 'yes') { return 'unknown' }
    return $null
}
$koreader = Test-Installed $KoreaderPkg
$appstoreHave = Get-PluginVersion 'appstore.koplugin'
# ZenFM is a plugin plus a companion app; each is tracked on its own, so a partial install
# gets only the missing part and an installed part is never replaced.
$zenfmPluginHave = Get-PluginVersion 'zenfm.koplugin'
$zenfmAppHave = $null
if (Test-Installed $ZenfmPkg) {
    $dump = Invoke-Adb shell dumpsys package $ZenfmPkg
    if ($dump -match '(?m)^\s*versionName=(\S+)') { $zenfmAppHave = $Matches[1] } else { $zenfmAppHave = 'unknown' }
}
$nook = switch ($model) {
    'BNRV1300' { 'Nook GlowLight 4 Plus' }
    'BNRV1100' { 'Nook GlowLight 4' }
    default { "Nook ($model)" }
}
if ($koreader) { Say "Found a $nook with KOReader." } else { Say "Found a $nook; KOReader is not installed." }

Step 'Choosing what to install'
Say 'Always: Nook Wi-Fi Helper and the Nook Wi-Fi KOReader plugin, with their permissions.'
$installKoreader = $false
$nookSetup = $false
$installFonts = $false
$installDict = $false
$dictDir = $null
$dictDate = $null
$installGuide = $false
$launcher = $false
$setHome = $false
$appstore = $false
$zenfm = $false
$zenfmPlugin = $false
$zenfmApp = $false
$zenfmRelease = 'latest'
$version = $null
if (-not $koreader) {
    if ($koreaderApk) {
        $version = $koreaderApk -replace '^koreader-android-[^-]+-', '' -replace '\.apk$', ''
        Say ''
        Say "KOReader $version is in this folder: the build this project is tested with."
        $installKoreader = Ask 'Install KOReader?' 'y'
    } else {
        Say 'Warning: KOReader is not installed and its APK is not in this folder. Install KOReader before using the plugin.'
    }
}
if ($nookFiles) {
    Say ''
    Say "Page buttons and frontlight: the Nook's page buttons turn pages in KOReader, and"
    Say "KOReader's own brightness and warmth sliders replace Android's light dialog."
    $nookSetup = Ask 'Set them up?' 'y'
}
if ($fontsFile -and ($koreader -or $installKoreader)) {
    Say ''
    Say "Reading fonts for KOReader's font menu: Atkinson Hyperlegible Next and Lexend (made for"
    Say 'legibility), and Literata and Bitter (book serifs). Free fonts under the SIL Open Font License.'
    $installFonts = Ask 'Install the reading fonts?' 'y'
}
if ($koreader -or $installKoreader) {
    # An installed copy (in KOReader's folder from its own downloader, or one copied there by
    # hand) is updated in place, so KOReader does not list the dictionary twice.
    $dictFound = @((Invoke-Adb shell "find $Dict -maxdepth 2 -name $DictIfo 2>/dev/null") -split "`n" |
        Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    Say ''
    if ($dictFound.Count -eq 0) {
        Say 'English dictionary for looking up words in KOReader: reader.dict, made from Wiktionary,'
        Say 'with word histories (etymologies). Free (CC BY-SA 4.0); downloads about 62 MB from reader-dict.com.'
        if (Ask 'Install the dictionary?' 'n') { $installDict = $true; $dictDir = "$Dict/$DictName" }
    } elseif ($dictFound.Count -gt 1) {
        Say "The reader.dict English dictionary is in more than one folder in $Dict; leaving it as it is."
    } else {
        $dictDir = $dictFound[0].Substring(0, $dictFound[0].Length - $DictIfo.Length - 1)
        if ($dictDir.Contains("'")) {
            Say "The reader.dict English dictionary is in $dictDir; its folder name has a ' in it,"
            Say 'so it is left as it is.'
            $dictDir = $null
        } else {
            $ifoText = Invoke-Adb shell "cat '$($dictFound[0])'"
            if ($ifoText -match '(?m)^date=(\S+)') { $dictDate = $Matches[1] }
            $edition = if ($dictDate) { " (edition of $dictDate)" } else { '' }
            Say "English dictionary: reader.dict$edition is installed in $dictDir."
            Say 'reader-dict.com publishes a new edition about once a month (about 62 MB).'
            $installDict = Ask 'Update it to the newest edition?' 'n'
        }
    }
}
if ($guidePresent) {
    Say ''
    Say "User guide: how to use everything this installs, as an e-book in the Nook's NOOK folder."
    $installGuide = Ask 'Copy the user guide to the Nook?' 'y'
}
if ($launcherApk) {
    Say ''
    if ($koreader -or $installKoreader) {
        Say 'KOReader Home: a small launcher that opens KOReader whenever you press Home, so the'
        Say "Nook starts in KOReader. KOReader's Exit becomes Restart KOReader."
        if (Ask 'Install KOReader Home?' 'n') {
            $launcher = $true
            Say 'As the default Home app, it opens KOReader at start-up and on every Home press.'
            Say 'You can switch back later (the README shows how).'
            $setHome = Ask 'Make KOReader Home the default Home app now?' 'n'
        }
    } else {
        Say 'Skipping KOReader Home: it needs KOReader.'
    }
}
Say ''
if ($appstoreHave -eq 'unknown') {
    Say 'App Store is already installed (it updates itself).'
} elseif ($appstoreHave) {
    Say "App Store $appstoreHave is already installed (it updates itself)."
} else {
    Say 'App Store: browse and install community KOReader plugins and patches (from GitHub).'
    $appstore = Ask 'Install App Store?' 'n'
}
Say ''
if ($zenfmPluginHave -and $zenfmAppHave) {
    if ($zenfmPluginHave -eq 'unknown') { Say 'ZenFM is already installed (it updates itself).' }
    else { Say "ZenFM $zenfmPluginHave is already installed (it updates itself)." }
} elseif (-not $zenfmPluginHave -and -not $zenfmAppHave) {
    Say "ZenFM: manage the Nook's files from your computer's web browser (from GitHub)."
    if (Ask 'Install ZenFM?' 'n') { $zenfm = $true; $zenfmPlugin = $true; $zenfmApp = $true }
} elseif ($zenfmPluginHave -eq 'unknown') {
    Say 'ZenFM is partly installed: its plugin is there, but the companion app is missing and the'
    Say "plugin's version could not be read. Install the app from github.com/$ZenfmRepo by hand."
} elseif ($zenfmPluginHave) {
    Say "ZenFM is partly installed: plugin $zenfmPluginHave is there, but its companion app is missing."
    Say "The companion app from the same release ($zenfmPluginHave) can be added; the plugin is left as it is."
    if (Ask 'Install the ZenFM companion app?' 'n') { $zenfm = $true; $zenfmApp = $true; $zenfmRelease = "tags/v$zenfmPluginHave" }
} elseif ($zenfmAppHave -eq 'unknown') {
    Say 'ZenFM is partly installed: its companion app is there, but the plugin is missing and the'
    Say "app's version could not be read. Install the plugin from github.com/$ZenfmRepo by hand."
} else {
    Say "ZenFM is partly installed: companion app $zenfmAppHave is there, but the plugin is missing."
    Say "The plugin from the same release ($zenfmAppHave) can be added; the app is left as it is."
    if (Ask 'Install the ZenFM plugin?' 'n') { $zenfm = $true; $zenfmPlugin = $true; $zenfmRelease = "tags/v$zenfmAppHave" }
}

Step 'Summary'
if ($installKoreader) { Say "- KOReader $version" }
Say '- Nook Wi-Fi Helper and the Nook Wi-Fi plugin, with their permissions'
if ($koreader -or $installKoreader) { Say "- KOReader's permissions for the frontlight and its files" }
if ($nookSetup) { Say '- Page buttons and frontlight setup' }
if ($installFonts) { Say '- Reading fonts: Atkinson Hyperlegible Next, Lexend, Literata and Bitter' }
if ($installDict) {
    if ($dictDate) { Say '- Newest edition of the reader.dict English dictionary (downloaded from reader-dict.com)' }
    else { Say '- English dictionary: reader.dict (downloaded from reader-dict.com)' }
}
if ($installGuide) { Say "- User guide ($Books/$GuideEpub)" }
if ($launcher) {
    if ($setHome) { Say '- KOReader Home, as the default Home app' } else { Say '- KOReader Home (not the default Home app)' }
}
if ($appstore) { Say "- App Store (downloaded from github.com/$AppstoreRepo)" }
if ($zenfmPlugin -and $zenfmApp) {
    Say "- ZenFM and its companion app (downloaded from github.com/$ZenfmRepo)"
} elseif ($zenfmApp) {
    Say "- ZenFM's companion app, release $zenfmPluginHave (downloaded from github.com/$ZenfmRepo)"
} elseif ($zenfmPlugin) {
    Say "- ZenFM's plugin, release $zenfmAppHave (downloaded from github.com/$ZenfmRepo)"
}
if ($interactive -and -not (Ask 'Go ahead?' 'y')) {
    Say 'Stopped; nothing was changed.'
    exit 0
}

Step 'Checking the release files'
$files = @($helperApk, $pluginZip)
if ($installKoreader) { $files += $koreaderApk }
if ($nookSetup) { $files += $NookPatches + $EventMap }
if ($installFonts) { $files += $FontsZip }
if ($installGuide) { $files += $GuideEpub }
if ($launcher) { $files += @($launcherApk, $Patch) }
if ($null -ne $sums) {
    foreach ($f in $files) { Test-Sum $f }
    Say 'Checksums match.'
} else {
    Say 'No SHA256SUMS here; skipping the checksum check.'
}

# adb install prints its own errors; explain the one people hit when switching builds.
function Install-Apk([string]$Apk, [string]$Name, [string]$Package) {
    $out = Invoke-Adb install -r $Apk
    if ($script:AdbExit -eq 0 -and $out -match 'Success') { Say "Installed $(Split-Path -Leaf $Apk)."; return }
    Write-Host $out
    if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Fail ("The $Name already on the Nook is signed with a different key (for example a build from source).`n" +
            "Uninstall it first with: adb uninstall $Package`n" +
            'That also removes its permissions; run this script again afterwards to restore them.')
    }
    Fail "Could not install $Apk."
}

if ($installKoreader) {
    Step 'Installing KOReader'
    Install-Apk $koreaderApk 'KOReader' $KoreaderPkg
    $koreader = $true
}

Step 'Installing Nook Wi-Fi Helper'
Install-Apk $helperApk 'Nook Wi-Fi Helper' $HelperPkg

Step "Setting the helper's permissions"
# Location: Android only shows Wi-Fi network names and nearby Bluetooth devices to apps
# that have it. The helper never uses your location.
Invoke-AdbChecked 'Could not allow location access.' shell pm grant $HelperPkg android.permission.ACCESS_COARSE_LOCATION | Out-Null
Say 'Location access: allowed.'
# Modify system settings: only for Nook power off after sleeping.
Invoke-AdbChecked 'Could not allow modifying system settings.' shell appops set $HelperPkg WRITE_SETTINGS allow | Out-Null
Say 'Modify system settings: allowed.'

if ($koreader) {
    Step "Setting KOReader's permissions"
    # Modify system settings: KOReader changes the frontlight brightness and warmth (and
    # its own screen timeout) through Android's system settings. Without it, the light
    # controls do nothing.
    Invoke-AdbChecked "Could not allow KOReader to modify system settings." shell appops set $KoreaderPkg WRITE_SETTINGS allow | Out-Null
    Say 'Modify system settings (frontlight): allowed.'
    # Storage: KOReader asks for this on its first start; granting it here skips the prompt.
    Invoke-AdbChecked "Could not allow KOReader's storage access." shell pm grant $KoreaderPkg android.permission.READ_EXTERNAL_STORAGE | Out-Null
    Invoke-AdbChecked "Could not allow KOReader's storage access." shell pm grant $KoreaderPkg android.permission.WRITE_EXTERNAL_STORAGE | Out-Null
    Say 'Storage access: allowed.'
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nookwifi-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Step 'Installing the KOReader plugin'
    $pluginTmp = Join-Path $tmp 'plugin'
    Expand-Archive -LiteralPath $pluginZip -DestinationPath $pluginTmp
    $pluginDir = Join-Path $pluginTmp 'nookwifi.koplugin'
    if (-not (Test-Path -LiteralPath (Join-Path $pluginDir 'main.lua') -PathType Leaf)) {
        Fail "$pluginZip does not contain nookwifi.koplugin."
    }
    Invoke-AdbChecked 'Could not create the plugins folder.' shell mkdir -p $Plugins | Out-Null
    # Replace the folder, so files removed in a newer version do not linger. It holds only
    # the plugin's code; its settings live in KOReader's own settings file.
    Invoke-AdbChecked 'Could not remove the old plugin.' shell rm -rf "$Plugins/nookwifi.koplugin" | Out-Null
    Invoke-AdbChecked 'Could not copy the plugin to the Nook.' push $pluginDir "$Plugins/" | Out-Null
    Say "Plugin copied to $Plugins/nookwifi.koplugin."

    if ($nookSetup) {
        Step 'Installing the Nook button and frontlight setup'
        Invoke-AdbChecked 'Could not create the patches folder.' shell mkdir -p $Patches $Settings | Out-Null
        foreach ($f in $NookPatches) {
            Invoke-AdbChecked "Could not copy $f to the Nook." push $f "$Patches/" | Out-Null
            Say "Patch copied to $Patches/$f."
        }
        # The key map is a personal settings file: never overwrite one that differs from ours.
        # Compared without comments and spacing, so only a different mapping counts.
        function Get-Mappings([string[]]$Lines) {
            ($Lines | ForEach-Object { ($_ -replace '--.*', '') -replace '\s', '' } | Where-Object { $_ }) -join "`n"
        }
        $theirs = Invoke-Adb shell "cat $Settings/$EventMap 2>/dev/null"
        if ($theirs) {
            if ((Get-Mappings ($theirs -split "`n")) -eq (Get-Mappings (Get-Content -LiteralPath $EventMap))) {
                Say "Key map already in place: $Settings/$EventMap."
            } else {
                Say "Kept your own $Settings/$EventMap (it differs from this release's $EventMap)."
                Say "To use the release's key map, copy $EventMap from this folder over it."
            }
        } else {
            Invoke-AdbChecked "Could not copy $EventMap to the Nook." push $EventMap "$Settings/" | Out-Null
            Say "Key map copied to $Settings/$EventMap."
        }
    }

    if ($installFonts) {
        Step 'Installing the reading fonts'
        $fontsTmp = Join-Path $tmp 'fonts'
        Expand-Archive -LiteralPath $FontsZip -DestinationPath $fontsTmp
        Invoke-AdbChecked 'Could not create the fonts folder.' shell mkdir -p $Fonts | Out-Null
        foreach ($f in $FontFamilies) {
            $familyDir = Join-Path $fontsTmp $f
            if (-not (Test-Path -LiteralPath (Join-Path $familyDir 'OFL.txt') -PathType Leaf)) { Fail "$FontsZip does not contain $f." }
            # Replace only a folder this project installed (it carries our SOURCE.txt); a folder
            # of the same name with your own fonts is left alone.
            if ((Invoke-Adb shell "[ -e $Fonts/$f ] && echo yes") -eq 'yes' -and
                (Invoke-Adb shell "grep -q 'KOReader-first Nook' $Fonts/$f/SOURCE.txt 2>/dev/null && echo yes") -ne 'yes') {
                Say "Kept your own $Fonts/$f; this release's $f was not installed."
                continue
            }
            Invoke-AdbChecked "Could not remove the old $f." shell rm -rf "$Fonts/$f" | Out-Null
            Invoke-AdbChecked "Could not copy $f to the Nook." push $familyDir "$Fonts/" | Out-Null
            Say "Fonts copied to $Fonts/$f."
        }
    }

    if ($installGuide) {
        Step 'Copying the user guide'
        Invoke-AdbChecked 'Could not create the NOOK folder.' shell mkdir -p $Books | Out-Null
        Invoke-AdbChecked "Could not copy $GuideEpub to the Nook." push $GuideEpub "$Books/" | Out-Null
        Say "Guide copied to $Books/$GuideEpub."
    }

    if ($launcher) {
        Step 'Installing the KOReader Home launcher'
        Install-Apk $launcherApk 'KOReader Home launcher' $LauncherPkg
        Invoke-AdbChecked 'Could not create the patches folder.' shell mkdir -p $Patches | Out-Null
        Invoke-AdbChecked "Could not copy $Patch to the Nook." push $Patch "$Patches/" | Out-Null
        Say "Patch copied to $Patches/$Patch."
        if ($setHome) {
            Invoke-AdbChecked 'Could not set the default Home app.' shell cmd package set-home-activity "$LauncherPkg/.HomeActivity" | Out-Null
            $resolved = Invoke-Adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
            # Not $home: PowerShell's read-only $HOME has the same name (names ignore case).
            $homeApp = ($resolved -split "`n" | Select-Object -Last 1).Trim()
            if ($homeApp -ne "$LauncherPkg/.HomeActivity") { Fail "Could not make the launcher the default Home app (Home is $homeApp)." }
            Say 'Default Home app: KOReader Home.'
        } else {
            Say 'Not changed: the default Home app. Android may ask which Home app to use the next time you press Home.'
        }
    }

    if ($appstore -or $zenfm -or $installDict) {
        # Windows PowerShell 5.1 does not enable TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads very slow in 5.1
    }
    # GitHub release metadata of $Repo: $Ref is 'latest' (the newest stable release) or
    # 'tags/<tag>'. Read it once per install, so every file comes from the same release.
    function Get-Release([string]$Repo, [string]$Ref) {
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/$Ref" `
                -Headers @{ Accept = 'application/vnd.github+json' } -UseBasicParsing
        } catch {
            Fail "Could not read release $($Ref -replace '^tags/', '') of $Repo from GitHub."
        }
        if (-not $release.tag_name) { Fail "Could not read a release tag from GitHub's reply." }
        return $release
    }
    # The asset of release $Info matching $Pattern (its name and download URL).
    function Get-ReleaseAsset($Info, [string]$Pattern) {
        $asset = @($Info.assets | Where-Object { $_.name -like $Pattern }) | Select-Object -First 1
        if (-not $asset) { Fail "Release $($Info.tag_name) has no file matching $Pattern." }
        return @{ Url = $asset.browser_download_url; Name = $asset.name }
    }
    function Get-Download([string]$Url, [string]$OutFile) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } catch {
            Fail "Could not download $Url."
        }
    }
    # Unzips $Zip, checks it holds the folder $Plugin (with a main.lua), and copies it to the Nook.
    function Push-PluginZip([string]$Zip, [string]$Plugin) {
        $extra = Join-Path $tmp 'extra'
        if (Test-Path -LiteralPath $extra) { Remove-Item -LiteralPath $extra -Recurse -Force }
        Expand-Archive -LiteralPath $Zip -DestinationPath $extra
        $dir = Join-Path $extra $Plugin
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'main.lua') -PathType Leaf)) {
            Fail "$(Split-Path -Leaf $Zip) does not contain $Plugin."
        }
        Invoke-AdbChecked "Could not copy $Plugin to the Nook." push $dir "$Plugins/" | Out-Null
    }

    if ($installDict) {
        Step 'Installing the dictionary'
        Say "Downloading $DictUrl (about 62 MB)..."
        $dictZip = Join-Path $tmp 'dict.zip'
        Get-Download $DictUrl $dictZip
        $dictTmp = Join-Path $tmp 'dict'
        try {
            Expand-Archive -LiteralPath $dictZip -DestinationPath $dictTmp
        } catch {
            Fail 'The dictionary download is not a valid zip file.'
        }
        # Only reader.dict's own StarDict files, with no folders: anything else is not copied.
        $others = @(Get-ChildItem -LiteralPath $dictTmp -Recurse -Force |
            Where-Object { $_.PSIsContainer -or $_.Name -notlike 'reader.dict-en.*' })
        if ($others.Count -gt 0) { Fail "The dictionary download holds unexpected files: $(($others | ForEach-Object Name) -join ' ')" }
        foreach ($f in @($DictIfo, 'reader.dict-en.idx', 'reader.dict-en.dict.dz')) {
            if (-not (Test-Path -LiteralPath (Join-Path $dictTmp $f) -PathType Leaf)) { Fail "The dictionary download has no $f." }
        }
        $ifoLines = Get-Content -LiteralPath (Join-Path $dictTmp $DictIfo)
        if (-not ($ifoLines | Where-Object { $_ -like 'bookname=reader.dict EN*' })) {
            Fail 'The download is not the reader.dict English dictionary.'
        }
        $newDate = ($ifoLines | Where-Object { $_ -like 'date=*' } | Select-Object -First 1) -replace '^date=', ''
        Invoke-AdbChecked 'Could not prepare the dictionary folder.' shell "rm -rf $DictStage && mkdir -p $DictStage" | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $dictTmp -File) {
            Invoke-AdbChecked 'Could not copy the dictionary to the Nook.' push $item.FullName "$DictStage/" | Out-Null
        }
        # Replaces only reader.dict's own files (and KOReader's lookup caches of them) in that folder.
        $moved = Invoke-Adb shell "mkdir -p '$dictDir' && rm -f '$dictDir'/reader.dict-en.* && mv $DictStage/* '$dictDir'/ && rmdir $DictStage && echo OK"
        if ($moved -ne 'OK') { Fail "Could not move the dictionary into $dictDir." }
        $edition = if ($newDate) { " (edition of $newDate)" } else { '' }
        Say "Dictionary$edition copied to $dictDir."
        Say 'reader.dict is made from Wiktionary data, under CC BY-SA 4.0 (www.reader-dict.com).'
    }

    if ($appstore) {
        Step 'Installing App Store'
        $release = Get-Release $AppstoreRepo 'latest'
        $found = Get-ReleaseAsset $release 'appstore.koplugin.zip'
        $appstoreZip = Join-Path $tmp $found.Name
        Get-Download $found.Url $appstoreZip
        Push-PluginZip $appstoreZip 'appstore.koplugin'
        Say "App Store $($release.tag_name) copied to $Plugins/appstore.koplugin (from github.com/$AppstoreRepo)."
    }

    if ($zenfm) {
        Step 'Installing ZenFM'
        # On Android, ZenFM is a KOReader plugin plus a companion app that runs its server.
        # Both parts come from one release (read once), so they match: the newest stable one for
        # a fresh install, or the installed part's own release when adding the missing part.
        $release = Get-Release $ZenfmRepo $zenfmRelease
        if ($zenfmApp) {
            $apkAsset = Get-ReleaseAsset $release 'ZenFM-android-*.apk'
            $zenfmApk = Join-Path $tmp $apkAsset.Name
            Get-Download $apkAsset.Url $zenfmApk
            Install-Apk $zenfmApk 'ZenFM companion app' $ZenfmPkg
            Say "ZenFM companion app $($release.tag_name) installed (from github.com/$ZenfmRepo)."
        }
        if ($zenfmPlugin) {
            $zipAsset = Get-ReleaseAsset $release 'ZenFM-koreader-android-*.zip'
            $zenfmZip = Join-Path $tmp $zipAsset.Name
            Get-Download $zipAsset.Url $zenfmZip
            Push-PluginZip $zenfmZip 'zenfm.koplugin'
            Say "ZenFM $($release.tag_name) copied to $Plugins/zenfm.koplugin (from github.com/$ZenfmRepo)."
        }
        Say 'The first time you start it, approve the "Start ZenFM?" prompt (see its README).'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Step 'Done'
Say 'If KOReader is open, exit it and open it again: it loads plugins and patches only when it starts.'
Say 'Then look for Settings -> Network -> Nook Wi-Fi.'
if ($installGuide) { Say "The user guide is in the NOOK folder: $GuideEpub." }
if ($setHome) {
    Say ''
    Say 'To make another launcher the default again, list them with'
    Say '  adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
    Say "and set one, for example the Nook's own home screen:"
    Say '  adb shell cmd package set-home-activity com.nook.partner/.FacadeLauncherActivity'
    Say 'or run uninstall.cmd, which asks which Home app to use.'
}
exit 0
