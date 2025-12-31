################################################################################
##  File:  Install-GitHubRunner.ps1
##  Desc:  Pre-install GitHub Actions runner for VMSS auto-registration
##
##  This script downloads and extracts the GitHub Actions runner to
##  C:\ProgramData\runner during image build. VMSS instances will copy
##  this pre-installed runner to unique directories instead of downloading
##  at startup, reducing instance registration time from ~60s to <5s.
##
##  FIX: Adds Windows Defender exclusion BEFORE extraction to prevent
##       Runner.Listener.exe from being silently quarantined.
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

# ============================================================================
# CRITICAL FIX: Add Windows Defender exclusion BEFORE extraction
# ============================================================================
# Runner.Listener.exe is flagged as potentially unwanted software (PUP)
# and silently quarantined during extraction. Add exclusion temporarily.
# ============================================================================

Write-Host "Adding Windows Defender exclusion for runner directory..."
try {
    Add-MpPreference -ExclusionPath $runnerInstallDir -ErrorAction Stop
    Write-Host "Defender exclusion added: $runnerInstallDir"
} catch {
    Write-Warning "Failed to add Defender exclusion (may not be supported): $_"
    Write-Host "Continuing anyway - extraction may fail if Defender quarantines files"
}

# List contents of ZIP before extraction (diagnostic)
Write-Host "Listing ZIP archive contents..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
$hasRunnerListener = $false
foreach ($entry in $zip.Entries) {
    if ($entry.Name -eq "Runner.Listener.exe") {
        $hasRunnerListener = $true
        Write-Host "[OK] Found Runner.Listener.exe in ZIP - size: $($entry.Length) bytes"
    }
}
$zip.Dispose()

if (-not $hasRunnerListener) {
    throw "Runner.Listener.exe not found in downloaded ZIP archive - download may be corrupted"
}

# Extract runner using file-by-file extraction for reliability
Write-Host "Extracting runner to $runnerInstallDir..."
try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    $extractedCount = 0
    $listenerFound = $false

    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -like "*/") {
            # Skip directories - they'll be created automatically
            continue
        }

        $destinationPath = Join-Path $runnerInstallDir $entry.FullName
        $destinationDir = Split-Path $destinationPath -Parent

        # Create directory if it doesn't exist
        if (!(Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        # Extract file
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destinationPath, $true)
        $extractedCount++

        # Immediately verify Runner.Listener.exe after extracting it
        if ($entry.Name -eq "Runner.Listener.exe") {
            Start-Sleep -Milliseconds 500  # Give filesystem time to sync
            if (Test-Path $destinationPath) {
                $listenerFound = $true
                Write-Host "[SUCCESS] Runner.Listener.exe extracted and verified at: $destinationPath"
                Write-Host "          File size: $(Get-Item $destinationPath).Length bytes"
            } else {
                Write-Host "[CRITICAL] Runner.Listener.exe was extracted but immediately disappeared from: $destinationPath"
                Write-Host "           This suggests filesystem or security software interference"
            }
        }
    }

    $zip.Dispose()
    Write-Host "Extraction complete - $extractedCount files extracted"

    if (!$listenerFound) {
        throw "Runner.Listener.exe was never extracted from ZIP (should not happen - we verified it exists)"
    }

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
    $additionalFiles = $totalFiles - 20
    Write-Host "  Total: $totalFiles files - $additionalFiles additional files not shown"
}

# Check Windows Defender quarantine and provide detailed diagnostics
Write-Host "Checking Windows Defender status..."
$defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($defenderStatus) {
    Write-Host "Windows Defender Real-Time Protection: $($defenderStatus.RealTimeProtectionEnabled)"
    Write-Host "Windows Defender Behavior Monitoring: $($defenderStatus.BehaviorMonitorEnabled)"
    Write-Host "Windows Defender Cloud Protection: $($defenderStatus.CloudProtectionEnabled)"

    # Check for any recent threat detections
    $recentThreats = Get-MpThreatDetection -ErrorAction SilentlyContinue
    if ($recentThreats) {
        $runnerThreats = $recentThreats | Where-Object { $_.Resources -like "*Runner*" -or $_.Resources -like "*$runnerInstallDir*" }
        if ($runnerThreats) {
            Write-Host ""
            Write-Host "CRITICAL: Windows Defender QUARANTINED runner files despite exclusion:"
            $runnerThreats | ForEach-Object {
                Write-Host "  Threat: $($_.ThreatName)"
                Write-Host "  Resource: $($_.Resources)"
                Write-Host "  Action: $($_.ActionSuccess)"
            }
            Write-Host ""
            Write-Host "Attempting to restore quarantined files..."
            try {
                Restore-MpThreat -ErrorAction Stop
                Write-Host "Restore command executed - check if Runner.Listener.exe now exists"
            } catch {
                Write-Host "Failed to restore: $_"
            }
        } else {
            Write-Host "No Runner-related threats detected"
        }
    } else {
        Write-Host "No recent threat detections found"
    }

    # Check exclusion paths
    $exclusions = Get-MpPreference | Select-Object -ExpandProperty ExclusionPath -ErrorAction SilentlyContinue
    if ($exclusions -contains $runnerInstallDir) {
        Write-Host "Confirmed: Exclusion path is active for $runnerInstallDir"
    } else {
        Write-Host "WARNING: Exclusion path NOT found in active exclusions!"
        Write-Host "Active exclusions: $($exclusions -join ', ')"
    }
} else {
    Write-Host "Windows Defender cmdlets not available (may be disabled)"
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
    DefenderExclusion = $true
} | ConvertTo-Json -Depth 10

$metadataPath = Join-Path $runnerInstallDir "runner-metadata.json"
$metadata | Out-File -FilePath $metadataPath -Encoding utf8 -Force
Write-Host "Metadata written to: $metadataPath"

Write-Host "GitHub Actions Runner installation complete"
Write-Host "Runner files available at: $runnerInstallDir"

# Run Pester tests to validate installation
Invoke-PesterTests -TestFile "GitHubRunner"
