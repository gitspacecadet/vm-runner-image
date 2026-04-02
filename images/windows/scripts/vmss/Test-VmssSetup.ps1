################################################################################
##  File:  Test-VmssSetup.ps1
##  Desc:  Validate VMSS setup scripts and runner installation
##
##  This diagnostic script verifies that all required components for VMSS runner
##  initialization are present and correctly configured in the VM image.
##
##  Returns: Exit code 0 if all checks pass, 1 if any check fails
################################################################################

$errorActionPreference = "Stop"

Write-Host "=== VMSS Setup Validation Report ===" -ForegroundColor Cyan
Write-Host ""

$allChecksPassed = $true

# ========================================================================
# CHECK 1: VMSS Scripts Directory
# ========================================================================

Write-Host "[CHECK] VMSS scripts directory..." -NoNewline
$vmssScriptsDir = "C:\ProgramData\vmss-scripts"
if (Test-Path $vmssScriptsDir) {
    Write-Host " [PASS]" -ForegroundColor Green
    Write-Host "  Location: $vmssScriptsDir"
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: Directory not found: $vmssScriptsDir"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 2: Initialize-VmRunner.ps1
# ========================================================================

Write-Host "[CHECK] Initialize-VmRunner.ps1..." -NoNewline
$initScript = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
if (Test-Path $initScript) {
    # Validate PowerShell syntax
    $scriptContent = Get-Content $initScript -Raw
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null

    if ($errors.Count -eq 0) {
        Write-Host " [PASS]" -ForegroundColor Green
        Write-Host "  Size: $((Get-Item $initScript).Length) bytes"
        Write-Host "  Syntax: Valid PowerShell"
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  ERROR: PowerShell syntax errors detected"
        $errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        $allChecksPassed = $false
    }
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: File not found: $initScript"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 3: Test-VmssSetup.ps1
# ========================================================================

Write-Host "[CHECK] Test-VmssSetup.ps1..." -NoNewline
$testScript = Join-Path $vmssScriptsDir "Test-VmssSetup.ps1"
if (Test-Path $testScript) {
    # Validate PowerShell syntax
    $scriptContent = Get-Content $testScript -Raw
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null

    if ($errors.Count -eq 0) {
        Write-Host " [PASS]" -ForegroundColor Green
        Write-Host "  Size: $((Get-Item $testScript).Length) bytes"
        Write-Host "  Syntax: Valid PowerShell"
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  ERROR: PowerShell syntax errors detected"
        $allChecksPassed = $false
    }
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: File not found: $testScript"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 4: Remove-Runner.ps1
# ========================================================================

Write-Host "[CHECK] Remove-Runner.ps1..." -NoNewline
$removeScript = Join-Path $vmssScriptsDir "Remove-Runner.ps1"
if (Test-Path $removeScript) {
    # Validate PowerShell syntax
    $scriptContent = Get-Content $removeScript -Raw
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null

    if ($errors.Count -eq 0) {
        Write-Host " [PASS]" -ForegroundColor Green
        Write-Host "  Size: $((Get-Item $removeScript).Length) bytes"
        Write-Host "  Syntax: Valid PowerShell"
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  ERROR: PowerShell syntax errors detected"
        $allChecksPassed = $false
    }
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: File not found: $removeScript"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 5: GitHub Runner Binaries
# ========================================================================

Write-Host "[CHECK] GitHub runner binaries..." -NoNewline
$runnerDir = "C:\ProgramData\runner"
if (Test-Path $runnerDir) {
    $criticalFiles = @("config.cmd", "run.cmd", "Runner.Listener.exe")
    $missingFiles = @()

    foreach ($file in $criticalFiles) {
        $filePath = Join-Path $runnerDir $file
        if (-not (Test-Path $filePath)) {
            $missingFiles += $file
        }
    }

    if ($missingFiles.Count -eq 0) {
        Write-Host " [PASS]" -ForegroundColor Green
        Write-Host "  Location: $runnerDir"
        Write-Host "  Critical files present: $($criticalFiles -join ', ')"
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  ERROR: Missing files: $($missingFiles -join ', ')"
        $allChecksPassed = $false
    }
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: Runner directory not found: $runnerDir"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 6: Metadata File
# ========================================================================

Write-Host "[CHECK] Metadata file..." -NoNewline
$metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
if (Test-Path $metadataPath) {
    try {
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        if ($metadata.InstallDate) {
            Write-Host " [PASS]" -ForegroundColor Green
            Write-Host "  Install Date: $($metadata.InstallDate)"
            if ($metadata.ScriptVersion) {
                Write-Host "  Script Version: $($metadata.ScriptVersion)"
            }
        } else {
            Write-Host " [FAIL]" -ForegroundColor Red
            Write-Host "  ERROR: Metadata missing InstallDate field"
            $allChecksPassed = $false
        }
    } catch {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  ERROR: Invalid JSON in metadata file"
        $allChecksPassed = $false
    }
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: File not found: $metadataPath"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 7: README File
# ========================================================================

Write-Host "[CHECK] README file..." -NoNewline
$readmePath = Join-Path $vmssScriptsDir "README.md"
if (Test-Path $readmePath) {
    Write-Host " [PASS]" -ForegroundColor Green
    Write-Host "  Location: $readmePath"
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: File not found: $readmePath"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 8: PowerShell Version
# ========================================================================

Write-Host "[CHECK] PowerShell version..." -NoNewline
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -ge 5) {
    Write-Host " [PASS]" -ForegroundColor Green
    Write-Host "  Version: $($psVersion.Major).$($psVersion.Minor).$($psVersion.Build)"
} else {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: PowerShell 5.0 or higher required (found: $psVersion)"
    $allChecksPassed = $false
}

# ========================================================================
# CHECK 9: Disk Space
# ========================================================================

Write-Host "[CHECK] Available disk space..." -NoNewline
$drive = Get-PSDrive C
$freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
if ($freeSpaceGB -gt 10) {
    Write-Host " [PASS]" -ForegroundColor Green
    Write-Host "  Free space: $freeSpaceGB GB"
} else {
    Write-Host " [WARN]" -ForegroundColor Yellow
    Write-Host "  WARNING: Low disk space: $freeSpaceGB GB (recommend >10GB)"
}

# ========================================================================
# CHECK 10: Network Connectivity
# ========================================================================

Write-Host "[CHECK] GitHub API connectivity..." -NoNewline
try {
    $testUrl = "https://api.github.com"
    $response = Invoke-WebRequest -Uri $testUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    Write-Host " [PASS]" -ForegroundColor Green
    Write-Host "  Status: $($response.StatusCode)"
} catch {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  ERROR: Cannot reach $testUrl"
    Write-Host "  Details: $($_.Exception.Message)"
    $allChecksPassed = $false
}

# ========================================================================
# FINAL SUMMARY
# ========================================================================

Write-Host ""
Write-Host "=== Validation Summary ===" -ForegroundColor Cyan

if ($allChecksPassed) {
    Write-Host "All checks passed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "The VMSS instance is ready for runner initialization." -ForegroundColor Green
    Write-Host "Next step: Run Initialize-VmRunner.ps1 to register the runner" -ForegroundColor Green
    exit 0
} else {
    Write-Host "One or more checks failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please review the errors above and:" -ForegroundColor Yellow
    Write-Host "1. Verify you are using the correct custom image" -ForegroundColor Yellow
    Write-Host "2. Check image build logs for errors" -ForegroundColor Yellow
    Write-Host "3. Contact support if issues persist" -ForegroundColor Yellow
    exit 1
}
