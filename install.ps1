# Swoopy for Windows (beta): installs or updates Swoopy. Paste this into PowerShell:
#
#   irm https://raw.githubusercontent.com/Gromhogg/swoopy/main/install.ps1 | iex
#
# It finds the newest Swoopy release on GitHub, downloads Swoopy-Setup.exe, checks it against
# its SHA-256 file, and runs it. Windows asks for permission once ("Do you want to allow this app...?").
# Running it again updates Swoopy.
#
# Works in Windows PowerShell 5.1 and PowerShell 7. Uses "return" (not "exit") so your window stays open.

function Install-Swoopy {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'  # makes downloads much faster in Windows PowerShell
    $repo = 'Gromhogg/swoopy'

    Write-Host ''
    Write-Host 'Swoopy for Windows (beta)' -ForegroundColor Magenta
    Write-Host ''

    # GitHub needs TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Windows 11 or newer (build 22000+).
    $build = [Environment]::OSVersion.Version.Build
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or $build -lt 22000) {
        Write-Host "Swoopy needs Windows 11. This PC has Windows build $build." -ForegroundColor Red
        return
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('SwoopyInstall-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $setup = Join-Path $work 'Swoopy-Setup.exe'
    $shaFile = "$setup.sha256"

    if ($env:PITCHSHIFT_SETUP_EXE) {
        # For testing a build that isn't released yet (the GitHub checks use this).
        Write-Host "Using $env:PITCHSHIFT_SETUP_EXE"
        Copy-Item -LiteralPath $env:PITCHSHIFT_SETUP_EXE -Destination $setup
        Copy-Item -LiteralPath "$env:PITCHSHIFT_SETUP_EXE.sha256" -Destination $shaFile
        $version = 'test build'
    } else {
        Write-Host 'Looking for the newest version...'
        try {
            $releases = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repo/releases?per_page=30" `
                -Headers @{ 'User-Agent' = 'Swoopy-Installer'; 'Accept' = 'application/vnd.github+json' }
        } catch {
            Write-Host "Couldn't reach GitHub. Check your internet connection and try again." -ForegroundColor Red
            Write-Host "($($_.Exception.Message))"
            return
        }
        $release = $null
        $asset = $null
        foreach ($r in $releases) {
            if ($r.draft) { continue }
            $names = @($r.assets | ForEach-Object { $_.name })
            # Releases from before the name Swoopy have PitchShift-Setup.exe.
            $asset = @('Swoopy-Setup.exe', 'PitchShift-Setup.exe') |
                Where-Object { $names -contains $_ -and $names -contains "$_.sha256" } | Select-Object -First 1
            if ($asset) { $release = $r; break }
        }
        if (-not $release) {
            Write-Host "There's no Windows version of Swoopy to download yet." -ForegroundColor Red
            return
        }
        $version = $release.tag_name
        Write-Host "Downloading Swoopy $version..."
        $exeUrl = ($release.assets | Where-Object { $_.name -eq $asset }).browser_download_url
        $shaUrl = ($release.assets | Where-Object { $_.name -eq "$asset.sha256" }).browser_download_url
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $exeUrl -OutFile $setup
            Invoke-WebRequest -UseBasicParsing -Uri $shaUrl -OutFile $shaFile
        } catch {
            Write-Host "The download didn't finish. Please try again." -ForegroundColor Red
            Write-Host "($($_.Exception.Message))"
            return
        }
    }

    # Check the download is exactly the file that was published.
    $expected = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        Write-Host "The download doesn't match its checksum, so it wasn't opened. Please try again." -ForegroundColor Red
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Unblock-File -LiteralPath $setup

    Write-Host ''
    Write-Host 'Click Yes when Windows asks.' -ForegroundColor Yellow
    Write-Host 'If VB-Audio''s window opens, click "Install Driver" (this adds Swoopy Mic for your voice).'
    Write-Host ''
    # Setup asks Windows for permission itself, so Swoopy opens afterwards as you (not as administrator).
    $setupArgs = @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    if ($env:PITCHSHIFT_SETUP_ARGS) { $setupArgs += $env:PITCHSHIFT_SETUP_ARGS -split ' ' }  # GitHub checks only
    try {
        # Not "-Wait": that would also wait for Swoopy itself, which Setup opens at the end.
        $p = Start-Process -FilePath $setup -ArgumentList $setupArgs -PassThru
        $null = $p.Handle  # keeps the exit code readable
        $p.WaitForExit()
    } catch {
        Write-Host "Setup didn't start. ($($_.Exception.Message))" -ForegroundColor Red
        return
    }
    $code = $p.ExitCode
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    $restart = $false
    try {
        $restart = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Pitch Shift' -Name RestartNeeded -ErrorAction Stop).RestartNeeded -eq 1
    } catch { }

    if ($code -eq 0) {
        Write-Host "Swoopy $version is installed." -ForegroundColor Green
        Write-Host 'Open it any time from the Start menu or the Desktop.'
        if ($restart) { Write-Host 'Restart your PC to finish setting up Swoopy Mic (for your voice).' -ForegroundColor Yellow }
    } elseif ($code -eq 1 -or $code -eq 2 -or $code -eq 5) {
        # 1-2: Setup stopped before installing (for example "No" when Windows asked). 5: cancelled and undone.
        Write-Host 'Setup stopped before it finished. Nothing was changed.' -ForegroundColor Yellow
    } else {
        Write-Host "Installing didn't finish (code $code). Please try again, or download Swoopy-Setup.exe from" -ForegroundColor Red
        Write-Host "https://github.com/$repo/releases"
    }
}

Install-Swoopy
