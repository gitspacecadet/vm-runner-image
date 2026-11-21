################################################################################
##  File:  Invoke-Cleanup.ps1
##  Desc:  Cleanup WinSxS, temp, cache and compress some directories
################################################################################

Import-Module ImageHelpers -ErrorAction Stop
. (Join-Path (Get-Module ImageHelpers).ModuleBase 'BuildImageTelemetry-ALGo.ps1')
$stage = Start-BuildImageStage -Name 'cleanup'
$succeeded = $false
try {
Write-Host "Cleanup WinSxS"
dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase
if ($LASTEXITCODE -ne 0) {
    throw "Failed to cleanup WinSxS"
}

Write-Host "Clean up various directories"
@(
    "$env:SystemDrive\Recovery",
    "$env:SystemRoot\logs",
    "$env:SystemRoot\winsxs\manifestcache",
    "$env:SystemRoot\Temp",
    "$env:SystemDrive\Users\$env:INSTALL_USER\AppData\Local\Temp",
    "$env:TEMP",
    "$env:AZURE_CONFIG_DIR\logs",
    "$env:AZURE_CONFIG_DIR\commands",
    "$env:AZURE_CONFIG_DIR\telemetry"
) | ForEach-Object {
    if (Test-Path $_) {
        Write-Host "Removing $_"
        cmd /c "takeown /d Y /R /f $_ 2>&1" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to take ownership of $_"
        }
        cmd /c "icacls $_ /grant:r administrators:f /t /c /q 2>&1" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to grant administrators full control of $_"
        }
        Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# Remove AllUsersAllHosts profile
Remove-Item $profile.AllUsersAllHosts -Force -ErrorAction SilentlyContinue | Out-Null

# Clean yarn and npm cache (only if installed)
if (Get-Command yarn -ErrorAction SilentlyContinue) {
    cmd /c "yarn cache clean 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: Failed to clean yarn cache"
    }
} else {
    Write-Host "Yarn not installed, skipping yarn cache cleanup"
}

if (Get-Command npm -ErrorAction SilentlyContinue) {
    cmd /c "npm cache clean --force 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: Failed to clean npm cache"
    }
} else {
    Write-Host "NPM not installed, skipping npm cache cleanup"
}

# LZX compaction is deliberately omitted in BOTH prototype arms. It is a
# separate CPU/IO treatment; Docker, BC, artifacts and action caches remain.
$succeeded = $true
} finally { Stop-BuildImageStage -Stage $stage -Succeeded $succeeded }
