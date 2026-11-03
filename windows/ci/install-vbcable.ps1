# GitHub checks only: installs VB-CABLE (a virtual audio cable) on a GitHub runner, so the tests have
# a full sound path: whatever plays to "CABLE Input" comes out of "CABLE Output" where it is recorded.
# (Real users get VB-CABLE through the Swoopy installer, which shows VB-Audio's own setup window.)
#
# Tries VB-CABLE Driver Pack 45 first (Microsoft-signed, x64 + ARM64). Windows Server may refuse that
# signature, so on failure it falls back to Mozilla cubeb's CI recipe: Pack 43 + trust VB-Audio's
# certificate + devcon (x64 only).
param(
    [ValidateSet('auto', 'pack45', 'pack43')]
    [string]$Method = 'auto'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$work = Join-Path ($env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()) 'vbcable'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$packs = @{
    'VBCABLE_Driver_Pack45' = 'b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb'
    'VBCABLE_Driver_Pack43' = '66fd0a4d9f4896ff41632b7e3d53892c085c4561f53e8ae8d0f0bc10eedd1cdd'
}
$devconUrl = 'https://github.com/LABSN/sound-ci-helpers/raw/20a2b9bbd21fd005d8fe89933901506dba84ea4e/windows/devcon.exe'
$devconSha = '97cff42f8c0fe4fbdf991273159516bf78090625a933c3983ebd6f62284e329a'

function Get-Checked([string]$Url, [string]$Path, [string]$Sha) {
    Invoke-WebRequest -Uri $Url -OutFile $Path -MaximumRetryCount 3 -RetryIntervalSec 3
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Sha) { throw "Unexpected hash for $Url : $actual" }
}

function Get-Pack([string]$Name) {
    $zip = Join-Path $work "$Name.zip"
    Get-Checked "https://download.vb-audio.com/Download_CABLE/$Name.zip" $zip $packs[$Name]
    $dir = Join-Path $work $Name
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    return $dir
}

function Get-CableEndpoints {
    Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*CABLE*' }
}

function Wait-Cable([int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        $ok = @(Get-CableEndpoints | Where-Object { $_.Status -eq 'OK' })
        if ($ok.Count -ge 2) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Show-CableDevices {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like '*CABLE*' -or $_.FriendlyName -like '*VB-Audio*' } |
        Format-Table -AutoSize Status, Class, FriendlyName, InstanceId, Problem | Out-String -Width 300 | Write-Host
}

function Remove-CableDriver {
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'VBAudioVACWDM' } | ForEach-Object {
        Write-Host "Removing device $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId | Out-Host
    }
    Get-WindowsDriver -Online -All -ErrorAction SilentlyContinue |
        Where-Object { $_.OriginalFileName -like '*vbMmeCable*' } | ForEach-Object {
            Write-Host "Removing driver package $($_.Driver)"
            pnputil /delete-driver $_.Driver /uninstall /force | Out-Host
        }
}

# The Windows sound services must be running.
foreach ($service in 'AudioEndpointBuilder', 'Audiosrv') {
    Set-Service -Name $service -StartupType Automatic
    Start-Service -Name $service
}
Get-Service AudioEndpointBuilder, Audiosrv | Format-Table -AutoSize Name, Status, StartType | Out-String | Write-Host

$installed = $null
if (@(Get-CableEndpoints | Where-Object { $_.Status -eq 'OK' }).Count -ge 2) {
    $installed = 'already'
}

if (-not $installed -and $Method -in 'auto', 'pack45') {
    $dir = Get-Pack 'VBCABLE_Driver_Pack45'
    Write-Host 'Installing VB-CABLE Pack 45 (VBCABLE_Setup_x64.exe -i -h)'
    $p = Start-Process -FilePath (Join-Path $dir 'VBCABLE_Setup_x64.exe') -ArgumentList '-i', '-h' -Wait -PassThru
    Write-Host "Setup finished with code $($p.ExitCode)"
    if (Wait-Cable 60) {
        $installed = 'pack45'
    } else {
        Write-Host 'Pack 45 did not bring up working CABLE endpoints:'
        Show-CableDevices
    }
}

if (-not $installed -and $Method -in 'auto', 'pack43') {
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'The Pack 43 fallback only works on x64.' }
    Remove-CableDriver
    $dir = Get-Pack 'VBCABLE_Driver_Pack43'
    $devcon = Join-Path $work 'devcon.exe'
    Get-Checked $devconUrl $devcon $devconSha
    $signature = Get-AuthenticodeSignature -FilePath (Join-Path $dir 'vbaudio_cable64_win7.cat')
    $cert = Join-Path $work 'vbcable.cer'
    [IO.File]::WriteAllBytes($cert, $signature.SignerCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    certutil.exe -addstore -f TrustedPublisher $cert | Out-Host
    Write-Host 'Installing VB-CABLE Pack 43 with devcon'
    & $devcon install (Join-Path $dir 'vbMmeCable64_win7.inf') VBAudioVACWDM | Out-Host
    if (Wait-Cable 60) { $installed = 'pack43' } else { Show-CableDevices }
}

if (-not $installed) { throw 'VB-CABLE could not be installed.' }
Write-Host "VB-CABLE ready ($installed)"
Show-CableDevices
if ($env:GITHUB_OUTPUT) { "method=$installed" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
if ($env:GITHUB_STEP_SUMMARY) { "VB-CABLE installed with: **$installed**" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
