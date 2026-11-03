# GitHub checks only: installs Inno Setup (pinned version, checked by SHA-256) and builds
# Swoopy-Setup.exe + Swoopy-Setup.exe.sha256 from the x64 and ARM64 app folders.
param(
    [Parameter(Mandatory)] [string]$DistX64,
    [Parameter(Mandatory)] [string]$DistArm64,
    [string]$Version = '2.0.0-beta',
    [string]$NumericVersion = '2.0.0.0',
    [string]$Out = 'installer-out'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$innoUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
$innoSha = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'

$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$work = Join-Path ($env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()) 'inno'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$setup = Join-Path $work 'innosetup-6.7.3.exe'
Invoke-WebRequest -Uri $innoUrl -OutFile $setup -MaximumRetryCount 3 -RetryIntervalSec 3
$actual = (Get-FileHash -Algorithm SHA256 -Path $setup).Hash.ToLowerInvariant()
if ($actual -ne $innoSha) { throw "Unexpected Inno Setup download: $actual" }
$p = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
if ($p.ExitCode -ne 0 -or -not (Test-Path $iscc)) { throw "Inno Setup didn't install (code $($p.ExitCode))" }

foreach ($dist in $DistX64, $DistArm64) {
    foreach ($file in 'Swoopy.exe', 'SwoopyEngine.dll', 'SwoopyTool.exe') {
        if (-not (Test-Path (Join-Path $dist $file))) { throw "Missing $file in $dist" }
    }
}

$script = Join-Path $PSScriptRoot '..\Swoopy.iss'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
& $iscc "/DAppVersion=$Version" "/DNumericVersion=$NumericVersion" `
    "/DDistX64=$((Resolve-Path $DistX64).Path)" "/DDistArm64=$((Resolve-Path $DistArm64).Path)" `
    "/O$((Resolve-Path $Out).Path)" $script
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

$exe = Join-Path $Out 'Swoopy-Setup.exe'
$hash = (Get-FileHash -Algorithm SHA256 -Path $exe).Hash.ToLowerInvariant()
"$hash  Swoopy-Setup.exe" | Out-File -FilePath "$exe.sha256" -Encoding ascii -NoNewline
Get-ChildItem $Out | Format-Table Name, Length | Out-String | Write-Host
Write-Host "SHA-256: $hash"
