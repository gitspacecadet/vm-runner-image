################################################################################
##  File:  Install-GitHubRunner.ps1
##  Desc:  Pre-install GitHub Actions runner for VMSS auto-registration
##
##  This script downloads and extracts the GitHub Actions runner to
##  C:\ProgramData\runner during image build. VMSS instances will copy
##  this pre-installed runner to unique directories instead of downloading
##  at startup, reducing instance registration time from ~60s to <5s.
################################################################################

Write-Host "Installing GitHub Actions Runner..."

# Runner version (update as needed)
$runnerVersion = "2.321.0"
$runnerInstallDir = "C:\ProgramData\runner"

Write-Host "Runner version: $runnerVersion"
Write-Host "Install location: $runnerInstallDir"

# Construct download URL
$downloadUrl = "https://github.com/actions/runner/releases/download/v$runnerVersion/actions-runner-win-x64-$runnerVersion.zip"
Write-Host "Download URL: $downloadUrl"

# Download with retry logic using ImageHelpers
$archivePath = Invoke-DownloadWithRetry -Url $downloadUrl

# Create install directory
New-Item -ItemType Directory -Force -Path $runnerInstallDir | Out-Null
Write-Host "Created directory: $runnerInstallDir"

# List contents of ZIP before extraction (diagnostic)
Write-Host "Listing ZIP archive contents..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
$hasRunnerListener = $false
foreach ($entry in $zip.Entries) {
    if ($entry.Name -eq "Runner.Listener.exe") {
        $hasRunnerListener = $true
        Write-Host "✓ Found Runner.Listener.exe in ZIP - size: $($entry.Length) bytes"
    }
}
$zip.Dispose()

if (-not $hasRunnerListener) {
    throw "Runner.Listener.exe not found in downloaded ZIP archive - download may be corrupted"
}

# Extract runner using PowerShell native ZIP extraction
Write-Host "Extracting runner to $runnerInstallDir..."
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $runnerInstallDir)
    Write-Host "Extraction complete"
} catch {
    throw "Failed to extract runner archive: $_"
}

# List what was actually extracted (diagnostic)
Write-Host "Files extracted to $runnerInstallDir :"
$extractedFiles = Get-ChildItem -Path $runnerInstallDir -Recurse -File | Select-Object -First 20 Name, Length
foreach ($file in $extractedFiles) {
    Write-Host "  - $($file.Name) - $($file.Length) bytes"
}
$totalFiles = (Get-ChildItem -Path $runnerInstallDir -Recurse -File).Count
if ($totalFiles -gt 20) {
    Write-Host "  Total: $totalFiles files ($($totalFiles - 20) additional files not shown)"
}

# Check Windows Defender quarantine
Write-Host "Checking Windows Defender status..."
$defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($defenderStatus -and $defenderStatus.RealTimeProtectionEnabled) {
    Write-Host "WARNING: Windows Defender Real-Time Protection is ENABLED"
    $recentThreats = Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.Resources -like "*Runner*" }
    if ($recentThreats) {
        Write-Host "WARNING: Windows Defender detected threats related to Runner:"
        $recentThreats | ForEach-Object { Write-Host "  - $($_.ThreatName): $($_.Resources)" }
    }
}

# Verify critical files exist
$criticalFiles = @(
    "config.cmd",
    "run.cmd",
    "Runner.Listener.exe"
)

foreach ($file in $criticalFiles) {
    $filePath = Join-Path $runnerInstallDir $file
    if (-not (Test-Path $filePath)) {
        throw "Critical file not found: $filePath"
    }
    Write-Host "Verified: $file"
}

# Write metadata file for diagnostics
$metadata = @{
    Version = $runnerVersion
    InstallDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    InstallPath = $runnerInstallDir
    DownloadUrl = $downloadUrl
    InstalledBy = "Packer"
} | ConvertTo-Json -Depth 10

$metadataPath = Join-Path $runnerInstallDir "runner-metadata.json"
$metadata | Out-File -FilePath $metadataPath -Encoding utf8 -Force
Write-Host "Metadata written to: $metadataPath"

Write-Host "GitHub Actions Runner installation complete"
Write-Host "Runner files available at: $runnerInstallDir"

# Run Pester tests to validate installation
Invoke-PesterTests -TestFile "GitHubRunner"
