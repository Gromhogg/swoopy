# GitHub checks only: installs Swoopy on a fresh runner with the real installer, checks what it did,
# runs the app, updates over a running copy, then uninstalls and checks everything is cleaned up.
# With -FromOld, the runner first gets an older version (named Pitch Shift), running, and Swoopy updates it.
param(
    [Parameter(Mandatory)] [string]$Setup,   # Swoopy-Setup.exe
    [Parameter(Mandatory)] [string]$Tool,    # a SwoopyTool.exe from the build (for checks before installing)
    [string]$Out = 'install-out',
    [switch]$RemoveCable,                    # uninstall with /REMOVECABLE /DELETESETTINGS
    [switch]$ViaScript,                      # install with install.ps1 (as `irm ... | iex` would) instead of directly
    [string]$FromOld = ''                    # an older version's PitchShift-Setup.exe, installed first
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Tool = (Resolve-Path $Tool).Path
$Setup = (Resolve-Path $Setup).Path
if ($FromOld) { $FromOld = (Resolve-Path $FromOld).Path }

$checks = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name, $Pass, $Value = '') {
    $mark = if ($null -eq $Pass) { 'info' } elseif ($Pass) { 'pass' } else { 'FAIL' }
    Write-Host ("{0,-5} {1}  {2}" -f $mark.ToUpper(), $Name, $Value)
    $checks.Add([pscustomobject]@{ name = $Name; result = $mark; value = "$Value" })
}

function Diag([string]$Exe, [string]$Name) {
    $text = & $Exe diag | Out-String
    $text | Out-File -FilePath (Join-Path $Out "$Name.json") -Encoding utf8
    return $text | ConvertFrom-Json
}
function DefaultId($d, [string]$Direction) {
    ($d.endpoints | Where-Object { $_.direction -eq $Direction -and $_.default } | Select-Object -First 1).id
}
# The cable's working sides, by their short names (what Sound settings shows).
function CableNames($d) {
    $active = @($d.endpoints | Where-Object { $_.adapter -eq 'VB-Audio Virtual Cable' -and $_.state -eq 'active' })
    [pscustomobject]@{
        Mic   = (@($active | Where-Object { $_.direction -eq 'recording' }) | ForEach-Object description) -join ', '
        Feeds = @($active | Where-Object { $_.direction -eq 'playback' } | ForEach-Object description)
        Count = $active.Count
    }
}
function Machine([string]$Path) {
    $f = [IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 4096
        [void]$f.Read($b, 0, 4096)
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        switch ([BitConverter]::ToUInt16($b, $pe + 4)) { 0x8664 { 'x64' } 0xAA64 { 'arm64' } default { 'other' } }
    } finally { $f.Dispose() }
}
function WaitUntil([scriptblock]$Test, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds * 2; $i++) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 500 }
    return [bool](& $Test)
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
# An update keeps the older version's folder.
$app = Join-Path $env:ProgramFiles $(if ($FromOld) { 'Pitch Shift' } else { 'Swoopy' })
$startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$desktop = Join-Path $env:PUBLIC 'Desktop'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{6F1C2B7E-4D8A-4E3B-9A61-7C2E5D0B8F14}_is1'
$settingsFile = Join-Path $env:APPDATA 'Pitch Shift\settings.json'

# A real PC has its sound services on; a fresh runner may not.
foreach ($service in 'AudioEndpointBuilder', 'Audiosrv') {
    Set-Service -Name $service -StartupType Automatic
    Start-Service -Name $service
}

$before = Diag $Tool 'diag-before'
$playBefore = DefaultId $before 'playback'
$recBefore = DefaultId $before 'recording'
Check 'sound devices before installing' $null "$(@($before.endpoints).Count) device(s); cable: $($before.cable.present)"

# ---------- Install ----------
$log = Join-Path $Out 'setup.log'
if ($FromOld) {
    $p = Start-Process -FilePath $FromOld -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOLAUNCH', '/CABLESILENT', "/LOG=`"$(Join-Path $Out 'setup-old.log')`"" -Wait -PassThru
    Check 'older version (Pitch Shift) installs' (($p.ExitCode -eq 0) -and (Test-Path (Join-Path $app 'PitchShift.exe'))) "exit code $($p.ExitCode)"
    $old = Start-Process -FilePath (Join-Path $app 'PitchShift.exe') -PassThru
    Start-Sleep -Seconds 6
    Check 'older version runs' (-not $old.HasExited)
}
if ($ViaScript) {
    # The one-line installer, pointed at this build. VB-CABLE's window can't be clicked here, so
    # VB-CABLE goes in without it (/CABLESILENT). Swoopy opens at the end, like for a person.
    $env:PITCHSHIFT_SETUP_EXE = $Setup
    $env:PITCHSHIFT_SETUP_ARGS = "/CABLESILENT /LOG=$log"
    $script = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\..\install.ps1')
    $transcript = Invoke-Expression $script *>&1 | Out-String
    $transcript | Out-File (Join-Path $Out 'install-ps1.txt') -Encoding utf8
    Write-Host $transcript
    Check 'install.ps1 reports success' ($transcript -match 'is installed') ($transcript.Trim() -split "`n" | Select-Object -Last 2)
    Check 'install.ps1 says to click Yes' ($transcript -match 'Click Yes when Windows asks')
    Check 'Swoopy opens after installing' (WaitUntil { @(Get-Process Swoopy -ErrorAction SilentlyContinue).Count -gt 0 } 30)
    Start-Sleep -Seconds 3
    Start-Process -FilePath (Join-Path $app 'Swoopy.exe') -ArgumentList '--quit' -Wait
    Check 'it quits when asked (--quit)' (WaitUntil { @(Get-Process Swoopy -ErrorAction SilentlyContinue).Count -eq 0 } 30)
} else {
    $p = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOLAUNCH', '/CABLESILENT', "/LOG=`"$log`"" -Wait -PassThru
    Check 'setup finished' ($p.ExitCode -eq 0) "exit code $($p.ExitCode)"
}
if ($FromOld) {
    Check 'update closed the older version' ($old.HasExited)
    Check 'nothing of the older version still running' (@(Get-Process PitchShift, PitchShiftTool -ErrorAction SilentlyContinue).Count -eq 0)
    foreach ($file in 'PitchShift.exe', 'PitchShiftEngine.dll', 'PitchShiftTool.exe') {
        Check "older $file removed" (-not (Test-Path (Join-Path $app $file)))
    }
    foreach ($link in (Join-Path $startMenu 'Pitch Shift.lnk'), (Join-Path $startMenu 'Pitch Shift Diagnostics.lnk'), (Join-Path $desktop 'Pitch Shift.lnk')) {
        Check "older shortcut $(Split-Path -Leaf $link) removed" (-not (Test-Path $link))
    }
}

# ---------- Files, shortcuts, uninstall entry ----------
foreach ($file in 'Swoopy.exe', 'SwoopyEngine.dll', 'SwoopyTool.exe', 'LICENSE.txt', 'NOTICE.txt', 'unins000.exe') {
    Check "installed $file" (Test-Path (Join-Path $app $file))
}
foreach ($file in 'Swoopy.exe', 'SwoopyEngine.dll', 'SwoopyTool.exe') {
    $m = if (Test-Path (Join-Path $app $file)) { Machine (Join-Path $app $file) } else { 'missing' }
    Check "$file is built for $arch" ($m -eq $arch) $m
}
$shell = New-Object -ComObject WScript.Shell
foreach ($link in @(
        @{ Path = Join-Path $startMenu 'Swoopy.lnk'; Args = '' },
        @{ Path = Join-Path $startMenu 'Swoopy Diagnostics.lnk'; Args = '--diag' },
        @{ Path = Join-Path $desktop 'Swoopy.lnk'; Args = '' })) {
    $ok = Test-Path $link.Path
    $value = ''
    if ($ok) {
        $s = $shell.CreateShortcut($link.Path)
        $value = "$($s.TargetPath) $($s.Arguments)"
        $ok = $s.TargetPath -like "*\$(Split-Path -Leaf $app)\Swoopy.exe" -and $s.Arguments -eq $link.Args
    }
    Check "shortcut $(Split-Path -Leaf $link.Path)" $ok $value
}
$entry = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
Check 'uninstall entry' ($entry -and $entry.DisplayName -eq 'Swoopy (beta)') "$($entry.DisplayName) $($entry.DisplayVersion)"

# ---------- Swoopy Mic ----------
$after = Diag (Join-Path $app 'SwoopyTool.exe') 'diag-after-install'
$reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Pitch Shift' -ErrorAction SilentlyContinue
Check 'VB-CABLE installed' ($after.cable.present -eq $true) "restart needed: $($after.cable.restart_needed)"
$names = CableNames $after
Check 'recording side is named "Swoopy Mic"' ($names.Mic -eq 'Swoopy Mic') $names.Mic
Check 'playback side is named "Swoopy Mic Feed"' ($names.Feeds -contains 'Swoopy Mic Feed') ($names.Feeds -join ', ')
Check 'extra 16-channel cable input is hidden' (-not ($names.Feeds -like '*16*')) ($names.Feeds -join ', ')
Check 'Swoopy noted that it installed VB-CABLE' ($reg.InstalledByPitchShift -eq 1) $reg.InstalledByPitchShift
$playAfter = DefaultId $after 'playback'
$recAfter = DefaultId $after 'recording'
if ($playBefore) { Check 'default speakers unchanged' ($playAfter -eq $playBefore) $playAfter } else { Check 'default speakers (none before; Windows picks one)' $null $playAfter }
if ($recBefore) { Check 'default microphone unchanged' ($recAfter -eq $recBefore) $recAfter } else { Check 'default microphone (none before; Windows picks one)' $null $recAfter }

# ---------- Run the installed app ----------
$exe = Join-Path $app 'Swoopy.exe'
$shot = Join-Path $Out "installed-preview-$arch.png"
$p = Start-Process -FilePath $exe -ArgumentList '--preview', 'hear-on,voice-on,cartoon', '--screenshot', "`"$shot`"" -PassThru
Check 'installed app draws its window' ($p.WaitForExit(60000) -and (Test-Path $shot))

$running = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 6
Check 'installed app keeps running' (-not $running.HasExited)
$live = Join-Path $Out "installed-running-$arch.png"
Start-Process -FilePath $exe -ArgumentList '--shot', "`"$live`"" -Wait
Check 'running app answers (picture of itself)' (Test-Path $live)

$report = Join-Path $Out 'diagnostics.txt'
Start-Process -FilePath $exe -ArgumentList '--diag', '--out', "`"$report`"" -Wait
$text = if (Test-Path $report) { Get-Content -Raw $report } else { '' }
Check 'diagnostics report' (($text -match 'Swoopy diagnostics') -and ($text -match '"cable"') -and ($text -match '"started"')) "$($text.Length) characters"
$userDesktop = [Environment]::GetFolderPath('Desktop')
$desktopReport = Join-Path $userDesktop 'Swoopy diagnostics.txt'
Start-Process -FilePath (Join-Path $startMenu 'Swoopy Diagnostics.lnk')
Check 'Diagnostics shortcut puts a report on the Desktop' (WaitUntil { Test-Path $desktopReport } 30) $desktopReport

# ---------- Update over a running copy ----------
$p = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOLAUNCH', '/CABLESILENT', "/LOG=`"$(Join-Path $Out 'setup-update.log')`"" -Wait -PassThru
Check 'installing again (update) works while the app runs' ($p.ExitCode -eq 0) "exit code $($p.ExitCode)"
Check 'update closed the running app' ($running.HasExited)
Check 'settings file was saved by the app' (Test-Path $settingsFile)

# ---------- Uninstall ----------
$uninstallArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $Out 'uninstall.log')`"")
if ($RemoveCable) { $uninstallArgs += '/REMOVECABLE', '/DELETESETTINGS' }
Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList $uninstallArgs -Wait
# The uninstaller hands over to a copy of itself; wait for it to finish.
$gone = WaitUntil { -not (Test-Path $uninstallKey) -and -not (Test-Path (Join-Path $app 'Swoopy.exe')) } 180
Check 'uninstall finished' $gone
Start-Sleep -Seconds 3
Check 'program folder removed' (-not (Test-Path $app)) ((Get-ChildItem $app -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
Check 'shortcuts removed' (-not (Test-Path (Join-Path $startMenu 'Swoopy.lnk')) -and -not (Test-Path (Join-Path $startMenu 'Swoopy Diagnostics.lnk')) -and -not (Test-Path (Join-Path $desktop 'Swoopy.lnk')))
Check 'nothing left running' (@(Get-Process Swoopy, SwoopyTool, PitchShift, PitchShiftTool -ErrorAction SilentlyContinue).Count -eq 0)
$runOnce = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).'!PitchShiftRestore'
Check 'no sign-in repair left behind' (-not $runOnce) $runOnce
Check 'no app volumes left lowered' (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'Pitch Shift\restore.json')))

$end = Diag $Tool 'diag-after-uninstall'
$names = CableNames $end
if ($RemoveCable) {
    Check 'VB-CABLE removed (asked for)' ($names.Count -eq 0) "$($names.Count) cable device(s) left"
    Check 'Swoopy registry notes removed' (-not (Test-Path 'HKLM:\SOFTWARE\Pitch Shift'))
    Check 'settings deleted (asked for)' (-not (Test-Path $settingsFile))
} else {
    Check 'VB-CABLE kept' ($end.cable.present -eq $true)
    Check 'VB-CABLE has its own names back' ($names.Mic -eq 'CABLE Output' -and $names.Feeds -contains 'CABLE Input') "$($names.Mic) / $($names.Feeds -join ', ')"
    Check 'settings kept' (Test-Path $settingsFile)
}
$playEnd = DefaultId $end 'playback'
$recEnd = DefaultId $end 'recording'
if ($playBefore) { Check 'default speakers same as before' ($playEnd -eq $playBefore) $playEnd }
if ($recBefore) { Check 'default microphone same as before' ($recEnd -eq $recBefore) $recEnd }

# ---------- Report ----------
$failed = @($checks | Where-Object { $_.result -eq 'FAIL' }).Count
$checks | ConvertTo-Json -Depth 3 | Out-File (Join-Path $Out 'install-checks.json') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
    $title = if ($ViaScript) { 'install.ps1' } elseif ($FromOld) { 'Update from Pitch Shift' } else { 'Installer' }
    $lines = @("## $title checks ($arch)", '', '| check | result | value |', '|---|---|---|')
    foreach ($c in $checks) { $lines += "| $($c.name) | $(if ($c.result -eq 'FAIL') { '**FAIL**' } else { $c.result }) | $($c.value -replace '\|', '/') |" }
    ($lines -join "`n") + "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
Write-Host "$($checks.Count - $failed) passed or info, $failed failed"
if ($failed -gt 0) { exit 1 }
