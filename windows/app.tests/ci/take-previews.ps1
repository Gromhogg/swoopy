# GitHub checks only: pictures of the window in many states, light and dark (no sound, no clicking).
# Uses Swoopy.exe --preview <states> --screenshot <file> (see windows/app/Preview.cs).
param(
    [Parameter(Mandatory)] [string]$Exe,
    [string]$Out = 'shots',
    [double]$Scale = 2
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path

# name = preview states (like the Mac screenshots: on, waiting, typing, recording...)
$states = [ordered]@{
    'on'        = 'hear-on,voice-on,cartoon'
    'waiting'   = 'hear-on,waiting,cartoon'
    'typing'    = 'hear-on,typing,cartoon'
    'recording' = 'hear-on,voice-on,cartoon,recording'
    'playing'   = 'hear-on,voice-on,playing'
    'in-use'    = 'hear-on,voice-on,in-use,all'
    'two-apps'  = 'hear-on,two-apps,voice-on'
    'off'       = ''
    'repair'    = 'hear-on,repair'
    'restart'   = 'hear-on,restart'
    'allow-mic' = 'hear-on,voice-on,allow-mic'
    'no-mic'    = 'hear-on,no-mic'
    'menu'      = 'hear-on,voice-on,menu'
    'hover'     = 'hear-on,voice-on,hover'
    'listening' = 'hear-on,voice-on,listening,recording,waiting'
    # "Advanced processing" switch on (the pictures above show it off), with the card on and off.
    'advanced'          = 'hear-on,voice-on,cartoon,advanced'
    'advanced-hear-off' = 'voice-on,advanced'
    # The alert shown when "Advanced processing" is turned on (it may add delay).
    'advanced-alert'    = 'hear-on,voice-on,cartoon,advanced-alert'
}
# Window sizes (inside the frame), like the Mac pictures: wide, largest, tall (cards stacked), narrow, wide and short.
$sizes = [ordered]@{
    'wide'       = '900x452'
    'largest'    = '1000x640'
    'tall'       = '600x640'
    'narrow'     = '306x640'
    'wide-short' = '1000x352'
}
$failed = 0
function Take([string]$File, [string[]]$Arguments) {
    $p = Start-Process -FilePath $Exe -ArgumentList ($Arguments + @('--scale', "$Scale", '--screenshot', "`"$File`"")) -PassThru
    if (-not $p.WaitForExit(60000)) { $p.Kill(); Write-Host "Timed out: $File"; return $false }
    if ((Test-Path $File) -and $p.ExitCode -eq 0) { Write-Host "Saved $File"; return $true }
    Write-Host "No picture: $File, exit $($p.ExitCode)"
    return $false
}
foreach ($theme in 'light', 'dark') {
    foreach ($name in $states.Keys) {
        if (-not (Take (Join-Path $Out "$name-$theme.png") @('--preview', "`"$($states[$name])`"", '--theme', $theme))) { $failed++ }
    }
    foreach ($name in $sizes.Keys) {
        $file = Join-Path $Out "size-$name-$theme.png"
        if (-not (Take $file @('--preview', 'hear-on,voice-on', '--theme', $theme, '--size', $sizes[$name]))) { $failed++ }
    }
    # The biggest window with "Advanced processing" on (its row grows with everything else).
    if (-not (Take (Join-Path $Out "size-largest-advanced-$theme.png") @('--preview', 'hear-on,voice-on,advanced', '--theme', $theme, '--size', $sizes['largest']))) { $failed++ }
    # The alert in the narrowest window (it has to fit).
    if (-not (Take (Join-Path $Out "size-narrow-advanced-alert-$theme.png") @('--preview', 'hear-on,voice-on,advanced-alert', '--theme', $theme, '--size', $sizes['narrow']))) { $failed++ }
}
$log = Join-Path $env:LOCALAPPDATA 'Pitch Shift\app-log.txt'
if (Test-Path $log) { Write-Host '--- app log ---'; Get-Content $log | Write-Host }
if ($failed) { throw "$failed picture(s) missing" }
