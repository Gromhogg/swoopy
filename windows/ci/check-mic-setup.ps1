# GitHub checks only: checks what "SwoopyTool setup-mic", "restore-names" and "remove-cable" did,
# by reading "SwoopyTool diag". -Expect: named | original | removed
param(
    [Parameter(Mandatory)] [string]$Tool,
    [Parameter(Mandatory)] [ValidateSet('named', 'original', 'removed')] [string]$Expect,
    [Parameter(Mandatory)] [string]$Out
)
$ErrorActionPreference = 'Stop'
$json = (& $Tool diag) -join "`n"
$json | Out-File -FilePath $Out -Encoding utf8
$diag = $json | ConvertFrom-Json
$cable = @($diag.endpoints | Where-Object { $_.adapter -eq 'VB-Audio Virtual Cable' })
$active = @($cable | Where-Object { $_.state -eq 'active' })
$mic = @($active | Where-Object { $_.direction -eq 'recording' })
$feeds = @($active | Where-Object { $_.direction -eq 'playback' })
$cable | Format-Table direction, state, name | Out-String | Write-Host

$failures = @()
switch ($Expect) {
    'named' {
        if ($mic.Count -ne 1 -or $mic[0].description -ne 'Swoopy Mic') { $failures += "recording side should be 'Swoopy Mic'" }
        if (-not ($feeds | Where-Object { $_.description -eq 'Swoopy Mic Feed' })) { $failures += "playback side should be 'Swoopy Mic Feed'" }
        if ($feeds | Where-Object { $_.description -like '*16*' }) { $failures += 'the 16-channel input should be hidden' }
        if (-not $diag.cable.present) { $failures += 'the engine should find the cable' }
    }
    'original' {
        if ($mic.Count -ne 1 -or $mic[0].description -ne 'CABLE Output') { $failures += "recording side should be 'CABLE Output' again" }
        if (-not ($feeds | Where-Object { $_.description -eq 'CABLE Input' })) { $failures += "playback side should be 'CABLE Input' again" }
        if (-not ($feeds | Where-Object { $_.description -like '*16*' })) { $failures += 'the 16-channel input should be back' }
    }
    'removed' {
        if ($active.Count -ne 0) { $failures += 'VB-CABLE should be gone' }
    }
}
if ($failures.Count) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host "OK: $Expect"
