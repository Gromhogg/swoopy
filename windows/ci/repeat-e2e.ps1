# GitHub checks only: runs "What you hear" (e2e-music) many times on one runner, to see whether its checks are
# steady. Writes how many runs passed, which checks failed how often (with their values), and every run's log and
# report to -Out. Recordings are kept only for runs with a failed check. Always ends with success: the counts are the
# result (a failed run would send an email each time).
param(
    [Parameter(Mandatory)] [string]$Tool,
    [Parameter(Mandatory)] [int]$Times,
    [string]$Out = 'repeat-out',
    [string]$Arch = '',
    [string]$ExtraArgs = ''  # more e2e-music options, like "--only-later 40"
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$passed = 0
$failedChecks = @{}
$runs = @()
$extra = @($ExtraArgs -split ' ' | Where-Object { $_ })
for ($i = 1; $i -le $Times; $i++) {
    $name = 'run-{0:D2}' -f $i
    $folder = Join-Path $Out $name
    Write-Host "::group::$name"
    $started = Get-Date
    & $Tool e2e-music --out $folder @extra 2>&1 | Tee-Object -FilePath (Join-Path $Out "$name.log") | Out-Host
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'
    # A run that stopped early could leave test players playing; they would spoil the next run.
    Get-Process SwoopyTool, FakePlayer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $fails = @()
    $hiccups = $false  # a listening window with a hiccup in it (its recordings are worth keeping)
    $report = Join-Path $folder 'e2e_music.json'
    if (Test-Path $report) {
        $r = Get-Content $report -Raw | ConvertFrom-Json
        foreach ($p in $r.checks.PSObject.Properties) {
            if (-not $p.Value.pass) {
                $fails += "$($p.Name) = $($p.Value.value | ConvertTo-Json -Compress -Depth 5)"
                $failedChecks[$p.Name] = 1 + [int]$failedChecks[$p.Name]
            }
        }
        foreach ($p in $r.info.PSObject.Properties) {
            if ($p.Name -like '*_window' -and ($p.Value.lowest_piece_db -lt -1 -or ($p.Value.cable_silent_ms | Measure-Object).Count -gt 0)) {
                $hiccups = $true
            }
        }
    } else {
        $fails += "no report (exit code $code)"
        $failedChecks['(no report)'] = 1 + [int]$failedChecks['(no report)']
    }
    if ($code -eq 0 -and $fails.Count -eq 0) { $passed++ }
    if ($code -eq 0 -and $fails.Count -eq 0 -and -not $hiccups) {
        Get-ChildItem $folder -Filter *.wav -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    Write-Host ("{0}: {1} in {2} s{3}" -f $name, $(if ($fails.Count) { 'FAIL' } else { 'pass' }), $seconds,
        $(if ($fails.Count) { ' - ' + ($fails -join '; ') } else { '' }))
    $runs += [ordered]@{ run = $name; exit_code = $code; seconds = $seconds; failed = $fails }
}

$summary = [ordered]@{ arch = $Arch; runs = $Times; passed = $passed; failed_checks = $failedChecks; each_run = $runs }
$summary | ConvertTo-Json -Depth 6 | Out-File (Join-Path $Out 'summary.json') -Encoding utf8
$lines = @("## What you hear, $Times runs ($Arch): $passed passed", '')
if ($failedChecks.Count) {
    $lines += '| check | failed |', '|---|---|'
    foreach ($k in $failedChecks.Keys) { $lines += "| $k | $($failedChecks[$k]) |" }
    $lines += ''
}
foreach ($run in $runs) {
    if ($run.failed.Count) { $lines += "- $($run.run): $($run.failed -join '; ')" }
}
$text = $lines -join "`n"
Write-Host $text
$text | Out-File (Join-Path $Out 'summary.md') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { $text | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
$global:LASTEXITCODE = 0
exit 0
