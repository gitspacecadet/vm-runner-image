################################################################################
##  File:  Install-RunnerSetupScript.ps1
##  Desc:  Pre-stage VMSS runner initialization scripts in image
##
##  This script copies VMSS runner setup scripts to a well-known location
##  for VMSS Custom Script Extension to execute at instance startup.
##  Scripts are validated during build to ensure they will work at runtime.
################################################################################

Write-Host "Installing VMSS runner setup scripts..."

# Create VMSS scripts directory
$vmssScriptsDir = "C:\ProgramData\vmss-scripts"
New-Item -ItemType Directory -Force -Path $vmssScriptsDir | Out-Null
Write-Host "Created directory: $vmssScriptsDir"

# Define source scripts
$sourceDir = Join-Path $env:IMAGE_FOLDER "scripts\vmss"
$scripts = @(
    "Initialize-VmRunner.ps1",
    "Test-VmssSetup.ps1",
    "Remove-Runner.ps1"
)

Write-Host "Source directory: $sourceDir"

# Copy and validate each script
$copiedScripts = @()
foreach ($scriptName in $scripts) {
    $sourcePath = Join-Path $sourceDir $scriptName
    $destPath = Join-Path $vmssScriptsDir $scriptName

    if (-not (Test-Path $sourcePath)) {
        throw "Source script not found: $sourcePath"
    }

    Write-Host "Copying $scriptName..."
    Copy-Item -Path $sourcePath -Destination $destPath -Force

    if (-not (Test-Path $destPath)) {
        throw "Failed to copy $scriptName to $destPath"
    }

    # Validate PowerShell syntax (parse but don't execute)
    Write-Host "Validating $scriptName syntax..."
    $scriptContent = Get-Content $destPath -Raw
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        Write-Host "PowerShell syntax errors in $scriptName :"
        $errors | ForEach-Object { Write-Host "  - $_" }
        throw "$scriptName has PowerShell syntax errors"
    }

    Write-Host "  [OK] Copied and validated: $scriptName"
    $copiedScripts += $scriptName
}

# Create metadata file for diagnostics
Write-Host "Creating metadata file..."
$metadata = @{
    ScriptVersion = "2.0"
    InstallDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    InstallPath = $vmssScriptsDir
    InstalledBy = "Packer"
    Description = "VMSS runner initialization scripts for GitHub Actions self-hosted runners"
    Scripts = $copiedScripts
    Dependencies = @{
        GitHubRunner = "Pre-installed at C:\ProgramData\runner"
        PowerShell = "5.1 or higher"
        AzureServices = @(
            "Azure Metadata Service - 169.254.169.254",
            "Azure Key Vault - optional, for PAT retrieval",
            "GitHub API - api.github.com"
        )
    }
    Features = @{
        KeyVaultIntegration = "Azure Key Vault PAT retrieval via Managed Identity"
        RetryLogic = "GitHub API calls with exponential backoff - 3 retries"
        EnhancedDiagnostics = "Troubleshooting hints in error messages"
        ValidationTool = "Test-VmssSetup.ps1 for pre-flight checks"
        GracefulCleanup = "Remove-Runner.ps1 for scale-down events"
    }
    Usage = "Execute via Azure VMSS Custom Script Extension at instance startup"
} | ConvertTo-Json -Depth 10

$metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
$metadata | Out-File -FilePath $metadataPath -Encoding utf8 -Force
Write-Host "Metadata written to: $metadataPath"

# Verify all expected files are present
Write-Host "Verifying installation..."
$expectedFiles = @(
    "Initialize-VmRunner.ps1",
    "Test-VmssSetup.ps1",
    "Remove-Runner.ps1",
    "README.md",
    "vmss-scripts-metadata.json"
)

$missingFiles = @()
foreach ($file in $expectedFiles) {
    $filePath = Join-Path $vmssScriptsDir $file
    if (-not (Test-Path $filePath)) {
        $missingFiles += $file
    }
}

if ($missingFiles.Count -gt 0) {
    throw "Missing expected files: $($missingFiles -join ', ')"
}

Write-Host "All files verified present"

# List installed files
Write-Host "Installed files in $vmssScriptsDir :"
Get-ChildItem -Path $vmssScriptsDir | ForEach-Object {
    $size = if ($_.PSIsContainer) { "DIR" } else { "$($_.Length) bytes" }
    Write-Host "  - $($_.Name) - $size"
}

Write-Host "VMSS runner setup scripts installation complete"

# Run Pester tests to validate installation
Invoke-PesterTests -TestFile "VmssRunnerSetup"
