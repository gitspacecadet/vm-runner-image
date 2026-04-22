################################################################################
##  File:  Install-GitHubRunner.ps1
##  Desc:  Download GitHub Actions runner ZIP for VMSS runtime extraction
##
##  APPROACH: Download the ZIP file but DON'T extract it during image build.
##  VMSS instances will extract at runtime, avoiding the Runner.Listener.exe
##  extraction issue that occurs during Packer build/Sysprep.
##
##  Benefits:
##  - Avoids Windows Defender quarantine during image generalization
##  - Still much faster than downloading at runtime (~5s vs ~60s)
##  - Simple and proven - no complex extraction logic needed
################################################################################

Write-Host "Downloading GitHub Actions Runner ZIP for VMSS..."

# Resolve latest runner release from the GitHub API at build time.
# Mirrors GitHub's documented self-hosted setup flow; recorded in
# runner-metadata.json below for downstream traceability.
Write-Host "Resolving latest actions/runner release..."
$apiHeaders = @{
    'User-Agent' = 'packer-image-builder'
    'Accept'     = 'application/vnd.github+json'
}
if ($env:GITHUB_TOKEN) {
    $apiHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}
$latestRelease = Invoke-RestMethod `
    -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
    -Headers $apiHeaders `
    -UseBasicParsing `
    -ErrorAction Stop
$runnerVersion = $latestRelease.tag_name.TrimStart('v')
if ([string]::IsNullOrWhiteSpace($runnerVersion)) {
    throw "Failed to resolve runner version from GitHub API response."
}

$runnerInstallDir = "C:\ProgramData\runner"

Write-Host "Runner version: $runnerVersion"
Write-Host "Install location: $runnerInstallDir"

# Construct download URL
$downloadUrl = "https://github.com/actions/runner/releases/download/v$runnerVersion/actions-runner-win-x64-$runnerVersion.zip"
Write-Host "Download URL: $downloadUrl"

# Create install directory
New-Item -ItemType Directory -Force -Path $runnerInstallDir | Out-Null
Write-Host "Created directory: $runnerInstallDir"

# Download ZIP file (but DON'T extract it - VMSS will do that at runtime)
$archivePath = Invoke-DownloadWithRetry -Url $downloadUrl

# Copy ZIP to install directory
$zipDestination = Join-Path $runnerInstallDir "actions-runner-win-x64-$runnerVersion.zip"
Copy-Item -Path $archivePath -Destination $zipDestination -Force
Write-Host "Runner ZIP copied to: $zipDestination"

# Verify ZIP was copied successfully
if (Test-Path $zipDestination) {
    $fileSize = (Get-Item $zipDestination).Length
    Write-Host "ZIP file verified - size: $fileSize bytes"

    # Quick sanity check - verify it's a valid ZIP
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipDestination)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-Host "ZIP file is valid - contains $entryCount entries"
    } catch {
        throw "ZIP file appears to be corrupted: $_"
    }
} else {
    throw "Failed to copy runner ZIP to $zipDestination"
}

# Write metadata file for diagnostics
$metadata = @{
    Version = $runnerVersion
    DownloadDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    ZipPath = $zipDestination
    DownloadUrl = $downloadUrl
    InstalledBy = "Packer"
    ExtractionMethod = "Runtime - VMSS will extract at instance startup"
} | ConvertTo-Json -Depth 10

$metadataPath = Join-Path $runnerInstallDir "runner-metadata.json"
$metadata | Out-File -FilePath $metadataPath -Encoding utf8 -Force
Write-Host "Metadata written to: $metadataPath"

Write-Host "GitHub Actions Runner ZIP downloaded successfully"
Write-Host "ZIP available at: $zipDestination"
Write-Host "VMSS instances will extract this at runtime to avoid build-time issues"

# Run Pester tests to validate download
Invoke-PesterTests -TestFile "GitHubRunner"
