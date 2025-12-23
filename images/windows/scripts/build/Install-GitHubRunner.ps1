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
$archivePath = Start-DownloadWithRetry -Url $downloadUrl -Name "actions-runner.zip"

# Create install directory
New-Item -ItemType Directory -Force -Path $runnerInstallDir | Out-Null
Write-Host "Created directory: $runnerInstallDir"

# Extract runner
Write-Host "Extracting runner to $runnerInstallDir..."
Expand-7ZipArchive -Path $archivePath -DestinationPath $runnerInstallDir
Write-Host "Extraction complete"

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
