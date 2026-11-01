# Removes KOReader-first Nook from a Nook over USB (ADB).
#
#   uninstall.cmd      (double-click it, or run it in a Command Prompt)
#
# It looks at what is installed, asks what to remove, and shows a summary before
# changing anything: Nook Wi-Fi (the helper app and its KOReader plugin), the KOReader
# Home launcher (choosing another default Home app first, if it is the default), the
# page-button and frontlight setup, the reading fonts, and optionally KOReader itself
# with its koreader folder (books in that folder are moved to the NOOK folder first). Run
# it in a terminal, with only the Nook connected and USB debugging turned on.
#
# Windows version of uninstall.sh: keep the two in step (same questions, checks, steps and
# messages). Runs on Windows PowerShell 5.1 (built into Windows 10 and 11) and PowerShell 7.
# Keep this file ASCII: PowerShell 5.1 misreads other characters in files without a
# byte-order mark.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

$ErrorActionPreference = 'Stop'

$HelperPkg = 'dev.nookwifi.helper'
$LauncherPkg = 'dev.nookkoreader.launcher'
$LauncherHome = "$LauncherPkg/.HomeActivity"
$NookHome = 'com.nook.partner/.FacadeLauncherActivity'
$Plugins = '/sdcard/koreader/plugins'
$Patches = '/sdcard/koreader/patches'
$KoreaderPkg = 'org.koreader.launcher'
$KoreaderDir = '/sdcard/koreader'
$BooksDir = '/sdcard/NOOK'
$ZenfmPkg = 'org.zenlabs.zenfm'
$Settings = '/sdcard/koreader/settings'
$Plugin = 'nookwifi.koplugin'
$HomePatch = '2-koreader-home.lua'
$NookPatches = @('2-nook-frontlight-widget.lua')
$EventMap = 'event_map.lua'
$Fonts = '/sdcard/koreader/fonts'
$FontFamilies = @('AtkinsonHyperlegibleNext', 'Lexend', 'Literata', 'Bitter')

function Show-Usage {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 10 | ForEach-Object { $_ -replace '^# ?', '' }
}
function Say([string]$Text) { Write-Host $Text }
function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" }
function Fail([string]$Text) {
    Write-Host "Error: $Text" -ForegroundColor Red
    exit 1
}

foreach ($arg in $args) {
    if ($arg -in '-h', '--help', '/?') { Show-Usage; exit 0 }
    Write-Host "This script takes no options: it asks what to remove. ($arg)"
    Show-Usage
    exit 1
}

# Removing things needs answers: unlike install.ps1, there are no safe defaults to take
# without a terminal.
if ([Console]::IsInputRedirected) { Fail 'This script asks before removing anything; run it in a terminal.' }
# Asks a yes/no question; $Default ('y' or 'n') is taken on Enter.
function Ask([string]$Question, [string]$Default) {
    $hint = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host "$Question $hint"
        if ($answer -eq '') { return $Default -eq 'y' }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Say 'Please answer y or n.'
    }
}
# Asks for a number from 1 to $Count (1 on Enter).
function Choose([int]$Count) {
    while ($true) {
        $answer = Read-Host "Choose 1-$Count [1]"
        if ($answer -eq '') { return 1 }
        if ($answer -match '^[0-9]+$' -and [int]$answer -ge 1 -and [int]$answer -le $Count) { return [int]$answer }
        Say "Please enter a number from 1 to $Count."
    }
}

Set-Location -LiteralPath $PSScriptRoot

# adb: on the PATH, or in a platform-tools folder next to this script (where install.ps1
# downloads it).
$adb = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) {
    $cmd = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Fail 'adb not found. Install Android platform-tools (see the README) and try again.' }
    $adb = $cmd.Source
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
if (-not $model) { Fail "Could not read the device's model over adb. Reconnect the Nook and try again." }
function Test-Installed([string]$Package) {
    $out = Invoke-Adb shell pm list packages $Package
    return @($out -split "`n" | Where-Object { $_.Trim() -eq "package:$Package" }).Count -gt 0
}
function Test-Exists([string]$Path) { return (Invoke-Adb shell "[ -e $Path ] && echo yes") -eq 'yes' }
# Quotes $Text for the Nook's shell. Only single quotes: Windows PowerShell 5.1 mangles
# double quotes inside arguments to native programs.
function Quote([string]$Text) { return "'" + ($Text -replace "'", "'\''") + "'" }
function Test-There([string]$Path) { return (Invoke-Adb shell "[ -e $(Quote $Path) ] && echo yes") -eq 'yes' }
# The Home app Android opens now: a component, or Android's chooser if there is no default.
function Get-DefaultHome {
    $out = Invoke-Adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
    return @($out -split "`n")[-1].Trim()
}

$helper = Test-Installed $HelperPkg
$pluginThere = Test-Exists "$Plugins/$Plugin"
$launcher = Test-Installed $LauncherPkg
$homePatchThere = Test-Exists "$Patches/$HomePatch"
$nookPatchesThere = @($NookPatches | Where-Object { Test-Exists "$Patches/$_" })
# The key map is a personal settings file: only one with the same mappings as this
# release's is ours to remove. Compared without comments and spacing.
function Get-Mappings([string[]]$Lines) {
    ($Lines | ForEach-Object { ($_ -replace '--.*', '') -replace '\s', '' } | Where-Object { $_ }) -join "`n"
}
$eventMapState = 'none'
if (Test-Exists "$Settings/$EventMap") {
    $theirs = Invoke-Adb shell "cat $Settings/$EventMap"
    if ((Test-Path -LiteralPath $EventMap -PathType Leaf) -and
        (Get-Mappings ($theirs -split "`n")) -eq (Get-Mappings (Get-Content -LiteralPath $EventMap))) {
        $eventMapState = 'ours'
    } else {
        $eventMapState = 'theirs'
    }
}
# Only font folders this project installed: they carry its SOURCE.txt.
$fontsThere = @($FontFamilies | Where-Object {
    (Invoke-Adb shell "grep -q 'KOReader-first Nook' $Fonts/$_/SOURCE.txt 2>/dev/null && echo yes") -eq 'yes'
})
$homeNow = Get-DefaultHome
$koreader = Test-Installed $KoreaderPkg
$koreaderDirThere = Test-Exists $KoreaderDir
$zenfmApp = Test-Installed $ZenfmPkg
Say "Found a Nook ($model)."

if (-not $helper -and -not $pluginThere -and -not $launcher -and -not $homePatchThere -and
    $nookPatchesThere.Count -eq 0 -and $eventMapState -ne 'ours' -and $fontsThere.Count -eq 0 -and
    -not $koreader -and -not $koreaderDirThere) {
    Say 'Nothing from KOReader-first Nook is installed.'
    exit 0
}

# KOReader's own folders inside the koreader folder (datastorage.lua, plus the Android
# build's help, scripts and fonts): deleted with it, never moved. Screenshots are moved.
$KoreaderOwn = 'cache|clipboard|data|docsettings|fonts|hashdocsettings|help|history|ota|patches|plugins|scripts|settings|styletweaks'
# Lists paths in the koreader folder (relative to it) with find's tests $Tests, leaving out
# KOReader's own folders and anything inside a .sdr folder. Returns $null unless the
# listing completed: the Nook's shell must report find's success, or nothing could be told
# apart from an empty folder.
function Get-KoreaderPaths([string]$Tests) {
    $out = Invoke-Adb shell "cd $KoreaderDir && find . $Tests; echo END:`$?"
    if ($script:AdbExit -ne 0) { return $null }
    $listed = @($out -split "`n" | ForEach-Object { $_.TrimEnd() })
    if ($listed.Count -eq 0 -or $listed[-1] -ne 'END:0') { return $null }
    return ,@($listed | Select-Object -SkipLast 1 | ForEach-Object { $_ -replace '^\./', '' } | Where-Object {
        $_ -and $_ -notmatch "^($KoreaderOwn)/|\.sdr/"
    })
}
# The user's own files: every file except those in KOReader's own folders, its settings
# and logs at the top, and the .sdr folders (moved with their book, or on their own).
# Anything else is kept, whatever its type.
function Get-Books {
    $files = Get-KoreaderPaths '-type f'
    if ($null -eq $files) { return $null }
    return ,@($files | Where-Object { $_ -notmatch '^[^/]*\.(lua|lua\.old|log)$' })
}
# The path without its file name's extension ("Books/Title.epub" -> "Books/Title"; a
# dot in a folder name, or a name with no extension, is left alone).
function Remove-Extension([string]$Path) {
    $dot = $Path.LastIndexOf('.')
    if ($dot -gt $Path.LastIndexOf('/') + 1) { return $Path.Substring(0, $dot) }
    return $Path
}
# Highlights folders (Title.sdr) whose book is not among $BookPaths: from books stored
# elsewhere, or left behind by an earlier run that stopped after moving the book. They
# are moved on their own, so a retry never deletes highlights.
function Get-OrphanSdrs([string[]]$BookPaths) {
    $sdrs = Get-KoreaderPaths "-type d -name '*.sdr'"
    if ($null -eq $sdrs) { return $null }
    $withBook = @($BookPaths | ForEach-Object { "$(Remove-Extension $_).sdr" })
    return ,@($sdrs | Where-Object { $withBook -notcontains $_ })
}

Step 'Choosing what to remove'
$removeKoreader = $false
$removeWifi = $false
$removeLauncher = $false
$removeSetup = $false
$removeFonts = $false
$newHome = $null
$books = @()
$orphans = @()
if ($koreader -or $koreaderDirThere) {
    Say ''
    Say "KOReader: the app and its $KoreaderDir folder, with KOReader's settings, reading"
    Say 'statistics, dictionaries, fonts and plugins (App Store, ZenFM). Your own files in that'
    Say "folder (books and anything else not KOReader's) are moved to $BooksDir first, each book"
    Say 'with its highlights; books elsewhere stay where they are.'
    if (Ask 'Remove KOReader and its folder?' 'n') {
        $removeKoreader = $true
        # Everything else from this project lives in KOReader or its folder.
        if ($helper -or $pluginThere) { $removeWifi = $true }
        if ($launcher -or $homePatchThere) { $removeLauncher = $true }
        if ($nookPatchesThere.Count -gt 0 -or $eventMapState -ne 'none') { $removeSetup = $true }
        if ($koreaderDirThere) {
            $books = Get-Books
            if ($null -eq $books) { Fail "Could not list the files in $KoreaderDir. Nothing was changed." }
            $orphans = Get-OrphanSdrs $books
            if ($null -eq $orphans) { Fail "Could not list the files in $KoreaderDir. Nothing was changed." }
        }
    }
}
if (-not $removeKoreader -and ($helper -or $pluginThere)) {
    Say ''
    Say "Nook Wi-Fi: the helper app and its KOReader plugin. KOReader's Wi-Fi items go back to"
    Say 'opening Android settings, and Nook power off after sleeping goes back to never.'
    $removeWifi = Ask 'Remove Nook Wi-Fi?' 'y'
}
if ($launcher -or $homePatchThere) {
    if (-not $removeKoreader) {
        Say ''
        Say 'KOReader Home: the launcher that opens KOReader when you press Home.'
        $removeLauncher = Ask 'Remove KOReader Home?' 'y'
    }
    if ($removeLauncher) {
        if ($homeNow -eq $LauncherHome) {
            # Every other Home app: skip this launcher, Android's fallback (negative
            # priority) and Settings' own fallback screen. The Nook's own home goes first.
            $listingHomes = Invoke-Adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME
            $homes = @()
            $priority = 0
            foreach ($line in ($listingHomes -split "`n")) {
                $line = $line.Trim()
                if ($line -match '^priority=(-?\d+)') { $priority = [int]$Matches[1]; continue }
                if ($line -match '/') {
                    $c = ($line -split '\s+')[0]
                    if ($priority -ge 0 -and -not $c.StartsWith("$LauncherPkg/") -and -not $c.StartsWith('com.android.settings/')) {
                        $homes += $c
                    }
                    $priority = 0
                }
            }
            $homes = @($homes | Where-Object { $_ -eq $NookHome }) + @($homes | Where-Object { $_ -ne $NookHome })
            if ($homes.Count -eq 0) {
                Say 'KOReader Home is the default Home app, and there is no other to switch to:'
                Say 'Android will ask which Home app to use the next time you press Home.'
            } else {
                Say 'KOReader Home is the default Home app. Which Home app should take its place?'
                for ($i = 0; $i -lt $homes.Count; $i++) {
                    $c = $homes[$i]
                    if ($c -eq $NookHome) { $label = "The Nook's own home screen" }
                    elseif ($c.StartsWith('app.olauncher/')) { $label = 'Olauncher' }
                    else { $label = ($c -split '/')[0] }
                    Say "  $($i + 1). $label ($c)"
                }
                $newHome = $homes[(Choose $homes.Count) - 1]
            }
        }
    }
}
if (-not $removeKoreader -and ($nookPatchesThere.Count -gt 0 -or $eventMapState -eq 'ours')) {
    Say ''
    Say "Page buttons and frontlight: without them the Nook's page buttons stop turning pages in"
    Say "KOReader, and Android's light dialog comes back."
    $removeSetup = Ask 'Remove the page-button and frontlight setup?' 'n'
}
if (-not $removeKoreader -and $fontsThere.Count -gt 0) {
    Say ''
    Say 'Reading fonts: Atkinson Hyperlegible Next, Lexend, Literata and Bitter. Books set to'
    Say "use them go back to KOReader's default font."
    $removeFonts = Ask 'Remove the reading fonts?' 'n'
}
if (-not $removeKoreader -and -not $removeWifi -and -not $removeLauncher -and -not $removeSetup -and -not $removeFonts) {
    Say ''
    Say 'Nothing chosen; nothing was changed.'
    exit 0
}

Step 'Summary'
if ($removeWifi) { Say '- Remove Nook Wi-Fi (helper app and plugin)' }
if ($removeLauncher) {
    if ($newHome) { Say "- Make $newHome the default Home app" }
    Say '- Remove KOReader Home (launcher app and its KOReader patch)'
}
if ($removeSetup) { Say '- Remove the page-button and frontlight setup' }
if ($removeFonts) { Say '- Remove the reading fonts' }
if ($eventMapState -eq 'theirs' -and $removeSetup -and -not $removeKoreader) {
    Say "  (your own $Settings/$EventMap differs from this release's and is kept)"
}
if ($removeKoreader) {
    if ($books.Count -gt 0) {
        Say "- Move $($books.Count) file(s) from $KoreaderDir to ${BooksDir}:"
        foreach ($b in $books) { Say "    $b" }
    }
    if ($orphans.Count -gt 0) {
        Say "- Move $($orphans.Count) highlights folder(s) whose book is not there to ${BooksDir}:"
        foreach ($d in $orphans) { Say "    $d" }
    }
    if ($koreader) { Say '- Uninstall KOReader' }
    if ($zenfmApp) { Say '- Uninstall the ZenFM companion app' }
    if ($koreaderDirThere) { Say "- Delete $KoreaderDir (KOReader's settings, statistics, dictionaries, fonts and plugins)" }
    Say "Kept: books outside $KoreaderDir, and the Nook's own apps."
} else {
    Say "Kept: KOReader, your books and KOReader's settings, and any other plugins."
}
if (-not (Ask 'Go ahead?' 'n')) { Say 'Stopped; nothing was changed.'; exit 0 }

# adb uninstall reports a failure in its output, not always in its exit status.
function Uninstall-Apk([string]$Package, [string]$Name) {
    $out = Invoke-Adb uninstall $Package
    if ($out -match 'Success') { Say "Uninstalled $Name."; return }
    Write-Host $out
    Fail "Could not uninstall $Name."
}

# Moves a file or folder on the Nook, never over an existing one; $true only if it moved.
function Invoke-NookMove([string]$From, [string]$To) {
    if (Test-There $To) { return $false }
    $parent = $To.Substring(0, $To.LastIndexOf('/'))
    Invoke-Adb shell "mkdir -p $(Quote $parent) && mv $(Quote $From) $(Quote $To)" | Out-Null
    return (Test-There $To) -and -not (Test-There $From)
}
function Move-OnNook([string]$From, [string]$To) {
    if (-not (Invoke-NookMove $From $To)) {
        Fail "Could not move $From to $To. Nothing was removed; files moved so far are in $BooksDir."
    }
}

# Switch the default Home app first: Home never points at a removed app, and once
# KOReader Home is no longer the default it cannot reopen KOReader when KOReader is
# stopped below. A setting, not a removal: it can be switched back.
if ($removeLauncher -and $newHome) {
    Invoke-Adb shell cmd package set-home-activity $newHome | Out-Null
    $now = Get-DefaultHome
    if ($now -ne $newHome) { Fail "Could not make $newHome the default Home app (Home is $now). Nothing was removed." }
    Say "Default Home app: $newHome."
}

# Stop KOReader before moving anything, so it cannot write into its folder (a book's
# highlights or reading position when paused, a screenshot) after the files are moved.
# Then list again, so anything it wrote since the summary is moved too.
if ($removeKoreader -and $koreaderDirThere) {
    if ($koreader) { Invoke-Adb shell am force-stop $KoreaderPkg | Out-Null }
    $books = Get-Books
    if ($null -eq $books) { Fail "Could not list the files in $KoreaderDir. Nothing was removed." }
    $orphans = Get-OrphanSdrs $books
    if ($null -eq $orphans) { Fail "Could not list the files in $KoreaderDir. Nothing was removed." }
}

# Files first: if any move fails, nothing has been removed yet.
if ($books.Count -gt 0) {
    Step "Moving your files to $BooksDir"
    foreach ($b in $books) {
        $src = "$KoreaderDir/$b"
        $dst = "$BooksDir/$b"
        # Never overwrite: "Title.epub" becomes "Title (2).epub", and so on.
        $n = 1
        while ((Test-There $dst) -or (Test-There "$(Remove-Extension $dst).sdr")) {
            $n++
            $dst = "$BooksDir/$(Remove-Extension $b) ($n)$($b.Substring((Remove-Extension $b).Length))"
        }
        Move-OnNook $src $dst
        # The book's highlights, notes and reading position (Title.epub -> Title.sdr). If
        # they cannot follow, move the book back: a retry then finds the pair together and
        # moves them to matching names (the book may have been renamed " (n)").
        $srcSdr = "$(Remove-Extension $src).sdr"
        $dstSdr = "$(Remove-Extension $dst).sdr"
        if ((Test-There $srcSdr) -and -not (Invoke-NookMove $srcSdr $dstSdr)) {
            if (-not (Invoke-NookMove $dst $src)) {
                Fail "Could not move $srcSdr to $dstSdr, nor move $dst back. Nothing was removed; the book is at $dst and its highlights at $srcSdr."
            }
            Fail "Could not move $srcSdr to $dstSdr; the book was moved back. Nothing was removed; files moved so far are in $BooksDir."
        }
        Say "Moved $b."
    }
}
if ($orphans.Count -gt 0) {
    Step "Moving highlights folders to $BooksDir"
    foreach ($d in $orphans) {
        $dst = "$BooksDir/$d"
        $n = 1
        while (Test-There $dst) {
            $n++
            $dst = "$BooksDir/$($d.Substring(0, $d.Length - 4)) ($n).sdr"
        }
        Move-OnNook "$KoreaderDir/$d" $dst
        Say "Moved $d."
    }
}

if ($removeLauncher) {
    Step 'Removing KOReader Home'
    if ($launcher) { Uninstall-Apk $LauncherPkg 'KOReader Home' }
    if ($homePatchThere) {
        Invoke-AdbChecked "Could not remove $Patches/$HomePatch." shell rm -f "$Patches/$HomePatch" | Out-Null
        Say "Removed $Patches/$HomePatch."
    }
}

if ($removeWifi) {
    Step 'Removing Nook Wi-Fi'
    if ($helper) { Uninstall-Apk $HelperPkg 'Nook Wi-Fi Helper' }
    if ($pluginThere) {
        Invoke-AdbChecked "Could not remove $Plugins/$Plugin." shell rm -rf "$Plugins/$Plugin" | Out-Null
        Say "Removed $Plugins/$Plugin."
    }
}

if ($removeSetup) {
    Step 'Removing the page-button and frontlight setup'
    foreach ($f in $nookPatchesThere) {
        Invoke-AdbChecked "Could not remove $Patches/$f." shell rm -f "$Patches/$f" | Out-Null
        Say "Removed $Patches/$f."
    }
    if ($eventMapState -eq 'ours') {
        Invoke-AdbChecked "Could not remove $Settings/$EventMap." shell rm -f "$Settings/$EventMap" | Out-Null
        Say "Removed $Settings/$EventMap."
    } elseif ($eventMapState -eq 'theirs' -and -not $removeKoreader) {
        Say "Kept your own $Settings/$EventMap."
    }
}

if ($removeFonts) {
    Step 'Removing the reading fonts'
    foreach ($f in $fontsThere) {
        Invoke-AdbChecked "Could not remove $Fonts/$f." shell rm -rf "$Fonts/$f" | Out-Null
        Say "Removed $Fonts/$f."
    }
}

if ($removeKoreader) {
    Step 'Removing KOReader'
    if ($koreader) { Uninstall-Apk $KoreaderPkg 'KOReader' }
    if ($zenfmApp) { Uninstall-Apk $ZenfmPkg 'the ZenFM companion app' }
    if ($koreaderDirThere) {
        Invoke-Adb shell rm -rf $KoreaderDir | Out-Null
        if (Test-Exists $KoreaderDir) { Fail "Could not delete $KoreaderDir." }
        Say "Deleted $KoreaderDir."
    }
}

Step 'Done'
if ($removeKoreader) {
    if ($books.Count -gt 0) { Say "Your files from $KoreaderDir are in $BooksDir." }
    Say 'Networks you joined and remotes you paired stay saved in Android.'
    exit 0
}
Say 'If KOReader is open, exit it and open it again: it loads plugins and patches only when it starts.'
Say 'Networks you joined and remotes you paired stay saved in Android.'
