# Installs KOReader-first Nook on a Nook GlowLight 4 Plus over USB (ADB), from the release
# files next to this script, and sets the permissions the apps need.
#
#   install.cmd                       helper + plugin + permissions
#   install.cmd --launcher            also the KOReader Home launcher and its KOReader patch
#   install.cmd --launcher --set-home
#                                     ...and make the launcher the default Home app
#
# It also gives KOReader the permissions its frontlight (brightness and warmth) and file
# access need. Run it with only the Nook connected, with USB debugging allowed. It never
# uninstalls anything, and never changes the default Home app unless you pass --set-home.
#
# Windows version of install.sh: keep the two in step (same checks, steps and messages).
# Runs on Windows PowerShell 5.1 (built into Windows 10 and 11) and PowerShell 7. Keep this
# file ASCII: PowerShell 5.1 misreads other characters in files without a byte-order mark.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

$ErrorActionPreference = 'Stop'

$HelperPkg = 'dev.nookwifi.helper'
$LauncherPkg = 'dev.nookkoreader.launcher'
$KoreaderPkg = 'org.koreader.launcher'
$NookModel = 'BNRV1300'
$Plugins = '/sdcard/koreader/plugins'
$Patches = '/sdcard/koreader/patches'
$Patch = '2-koreader-home.lua'
$PlatformToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

function Show-Usage {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 11 | ForEach-Object { $_ -replace '^# ?', '' }
}
function Say([string]$Text) { Write-Host $Text }
function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" }
function Fail([string]$Text) {
    Write-Host "Error: $Text" -ForegroundColor Red
    exit 1
}

$launcher = $false
$setHome = $false
$force = $false
foreach ($arg in $args) {
    switch -CaseSensitive ($arg) {
        '--launcher' { $launcher = $true }
        '--set-home' { $setHome = $true }
        '--force' { $force = $true }
        { $_ -in '-h', '--help', '/?' } { Show-Usage; exit 0 }
        default { Write-Host "Unknown option: $arg"; Show-Usage; exit 1 }
    }
}
if ($setHome -and -not $launcher) { Fail '--set-home needs --launcher.' }

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
$helperApk = Find-One 'nookwifi-helper-*.apk' 'nookwifi-helper-<version>.apk'
$pluginZip = Find-One 'nookwifi.koplugin-*.zip' 'nookwifi.koplugin-<version>.zip'
$launcherApk = $null
if ($launcher) {
    $launcherApk = Find-One 'koreader-home-*.apk' 'koreader-home-<version>.apk'
    if (-not (Test-Path -LiteralPath $Patch -PathType Leaf)) { Fail "$Patch not found next to this script." }
}

# adb: on the PATH, or in a platform-tools folder next to this script (where the download
# below puts it).
function Find-Adb {
    $local = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $cmd = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

Step 'Checking the release files'
$adb = Find-Adb
if (-not $adb) {
    Say 'adb (Android platform-tools) was not found.'
    $answer = Read-Host "Download Google's platform-tools into this folder now? [y/N]"
    if ($answer -notmatch '^[Yy]') { Fail 'adb is needed. Install Android platform-tools and try again.' }
    # Windows PowerShell 5.1 does not enable TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $PSScriptRoot 'platform-tools-latest-windows.zip'
    Say "Downloading $PlatformToolsUrl ..."
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes the download very slow in 5.1
    Invoke-WebRequest -Uri $PlatformToolsUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $PSScriptRoot -Force
    Remove-Item -LiteralPath $zip
    $adb = Find-Adb
    if (-not $adb) { Fail 'The download did not contain adb.exe.' }
    Say "adb installed in $(Join-Path $PSScriptRoot 'platform-tools')."
}

if (Test-Path -LiteralPath 'SHA256SUMS' -PathType Leaf) {
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath 'SHA256SUMS') {
        if ($line -match '^([0-9a-fA-F]{64})  (.+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    # Only the files this run installs; SHA256SUMS may list more.
    $files = @($helperApk, $pluginZip)
    if ($launcher) { $files += @($launcherApk, $Patch) }
    foreach ($f in $files) {
        if (-not $sums.ContainsKey($f)) { Fail "$f is not listed in SHA256SUMS." }
        $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        if ($hash -ne $sums[$f]) { Fail "$f does not match SHA256SUMS. Download it again." }
    }
    Say 'Checksums match.'
} else {
    Say 'No SHA256SUMS here; skipping the checksum check.'
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
$devices = @($listing -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() })
if ($devices.Count -eq 0) { Fail 'No device found. Connect the Nook by USB and allow USB debugging.' }
if ($devices.Count -gt 1) { Fail 'More than one device is connected. Connect only the Nook.' }
if ($devices[0] -match 'unauthorized') {
    Fail 'The Nook has not allowed this computer yet. Unlock it, accept the USB debugging prompt, and try again.'
}
if ($devices[0] -match 'offline') { Fail 'The Nook is offline. Reconnect the cable and try again.' }
$model = Invoke-AdbChecked 'Could not read the device model.' shell getprop ro.product.model
$sdk = Invoke-AdbChecked 'Could not read the Android version.' shell getprop ro.build.version.sdk
if ($model -ne $NookModel -or $sdk -ne '27') {
    if (-not $force) {
        Fail "This is not a Nook GlowLight 4 Plus (model $model, Android API $sdk). Use --force to install anyway."
    }
    Say "Warning: model $model, API $sdk is untested. Continuing because of --force."
}
function Test-Installed([string]$Package) {
    $out = Invoke-Adb shell pm list packages $Package
    return @($out -split "`n" | Where-Object { $_.Trim() -eq "package:$Package" }).Count -gt 0
}
$koreader = Test-Installed $KoreaderPkg
if ($koreader) {
    Say 'Nook GlowLight 4 Plus with KOReader found.'
} else {
    if ($launcher) { Fail "KOReader ($KoreaderPkg) is not installed. The launcher needs it; install KOReader first." }
    Say "Warning: KOReader ($KoreaderPkg) is not installed. Install it before using the plugin."
}

# adb install prints its own errors; explain the one people hit when switching builds.
function Install-Apk([string]$Apk, [string]$Name, [string]$Package) {
    $out = Invoke-Adb install -r $Apk
    if ($script:AdbExit -eq 0 -and $out -match 'Success') { Say "Installed $Apk."; return }
    Write-Host $out
    if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Fail ("The $Name already on the Nook is signed with a different key (for example a build from source).`n" +
            "Uninstall it first with: adb uninstall $Package`n" +
            'That also removes its permissions; run this script again afterwards to restore them.')
    }
    Fail "Could not install $Apk."
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

Step 'Installing the KOReader plugin'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nookwifi-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Expand-Archive -LiteralPath $pluginZip -DestinationPath $tmp
    $pluginDir = Join-Path $tmp 'nookwifi.koplugin'
    if (-not (Test-Path -LiteralPath (Join-Path $pluginDir 'main.lua') -PathType Leaf)) {
        Fail "$pluginZip does not contain nookwifi.koplugin."
    }
    Invoke-AdbChecked 'Could not create the plugins folder.' shell mkdir -p $Plugins | Out-Null
    # Replace the folder, so files removed in a newer version do not linger. It holds only
    # the plugin's code; its settings live in KOReader's own settings file.
    Invoke-AdbChecked 'Could not remove the old plugin.' shell rm -rf "$Plugins/nookwifi.koplugin" | Out-Null
    Invoke-AdbChecked 'Could not copy the plugin to the Nook.' push $pluginDir "$Plugins/" | Out-Null
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Say "Plugin copied to $Plugins/nookwifi.koplugin."

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

Step 'Done'
Say 'Exit KOReader and open it again: it loads plugins and patches only when it starts.'
Say 'Then look for Settings -> Network -> Nook Wi-Fi.'
if ($setHome) {
    Say ''
    Say 'To make another launcher the default again, list them with'
    Say '  adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
    Say 'and set one, for example Olauncher:'
    Say '  adb shell cmd package set-home-activity app.olauncher/.MainActivity'
}
exit 0
