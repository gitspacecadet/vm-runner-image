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

    Write-Host "  ✓ Copied and validated: $scriptName"
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

# Create README for VMSS administrators
# NOTE: Temporarily disabled due to Packer here-string handling issues
# TODO: Create README.md as a separate static file instead
<#
Write-Host "Creating README..."
$readme = @"
# VMSS Runner Setup Scripts

This directory contains scripts for managing GitHub Actions self-hosted runners on VMSS instances.

## Scripts

### Initialize-VmRunner.ps1
**Purpose**: Register VMSS instance as GitHub Actions self-hosted runner

**Features**:
- Azure Key Vault integration for secure PAT retrieval (via Managed Identity)
- Retry logic for GitHub API calls (3 retries, exponential backoff)
- Enhanced error diagnostics with troubleshooting hints
- Backward compatible with parameter-based PAT

**Parameters**:
- ``gitHubPAT`` (Optional) - GitHub Personal Access Token (or use Key Vault)
- ``gitHubOrg`` (Mandatory) - GitHub organization name
- ``gitHubRepo`` (Optional) - Repository name (if empty, creates org-level runner)
- ``runnerLabels`` (Optional) - Comma-separated labels (default: "self-hosted,windows-latest-vmss,az-custom-image")
- ``keyVaultName`` (Optional) - Azure Key Vault name for PAT retrieval
- ``secretName`` (Optional) - Key Vault secret name (default: "github-pat")

**Example Usage**:
``````powershell
# Using Key Vault (recommended for production)
.\Initialize-VmRunner.ps1 ``
  -gitHubOrg "your-org" ``
  -keyVaultName "your-keyvault" ``
  -runnerLabels "self-hosted,windows,custom"

# Using parameter (testing/dev)
.\Initialize-VmRunner.ps1 ``
  -gitHubPAT "ghp_xxxxxxxxxxxx" ``
  -gitHubOrg "your-org"
``````

**Logs**: ``C:\vmss-runner-setup.log``

---

### Test-VmssSetup.ps1
**Purpose**: Validate runner setup prerequisites

**Checks**:
- Pre-staged scripts present and valid
- GitHub runner binaries installed
- Metadata files valid
- PowerShell version compatible
- Disk space available
- Network connectivity to GitHub

**Usage**:
``````powershell
.\Test-VmssSetup.ps1
``````

**Exit Codes**: 0 = all checks passed, 1 = one or more checks failed

---

### Remove-Runner.ps1
**Purpose**: Gracefully unregister runner (for scale-down events)

**Operations**:
- Stops runner service
- Unregisters from GitHub (requires PAT)
- Removes runner directory
- Cleans up service registration

**Parameters**:
- ``gitHubPAT`` (Optional) - GitHub PAT (or use Key Vault)
- ``keyVaultName`` (Optional) - Key Vault name
- ``secretName`` (Optional) - Secret name (default: "github-pat")

**Usage**:
``````powershell
.\Remove-Runner.ps1 -keyVaultName "your-keyvault"
``````

**Logs**: ``C:\vmss-runner-removal.log``

---

## Terraform Integration

### Custom Script Extension Example

``````hcl
resource "azurerm_virtual_machine_scale_set_extension" "runner_init" {
  name                         = "InitializeGhRunner"
  virtual_machine_scale_set_id = azurerm_windows_virtual_machine_scale_set.main.id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File C:\\ProgramData\\vmss-scripts\\Initialize-VmRunner.ps1 -gitHubOrg '${var.github_org}' -keyVaultName '${var.key_vault_name}' -runnerLabels '${local.runner_labels}'"
  })

  protected_settings = jsonencode({
    timestamp = formatdate("YYYYMMDDhhmmss", timestamp())
  })
}
``````

### Prerequisites

1. **Azure Key Vault** with GitHub PAT secret
2. **VMSS Managed Identity** with Key Vault ``Get`` permission
3. **Custom VM Image** with pre-installed runner binaries

### Key Vault Setup

``````bash
# Create Key Vault secret
az keyvault secret set ``
  --vault-name your-keyvault ``
  --name github-pat ``
  --value "ghp_xxxxxxxxxxxx"

# Grant VMSS access
az keyvault set-policy ``
  --name your-keyvault ``
  --object-id <vmss-managed-identity-object-id> ``
  --secret-permissions get
``````

---

## Troubleshooting

### Test Before Initialization
Run ``Test-VmssSetup.ps1`` to validate all prerequisites are met.

### Check Logs
- Initialization: ``C:\vmss-runner-setup.log``
- Removal: ``C:\vmss-runner-removal.log``

### Common Issues

**Issue**: Runner not found at C:\ProgramData\runner
**Solution**: Verify using correct custom image, check image build logs

**Issue**: Key Vault access denied
**Solution**: Verify Managed Identity has Get permission on Key Vault secrets

**Issue**: GitHub API rate limit
**Solution**: Script includes retry logic, wait and retry will happen automatically

**Issue**: config.cmd fails
**Solution**: Check PAT has required scopes (repo, admin:org), verify token not expired

---

## Version Information

**Script Version**: 2.0
**Installed**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Installed By**: Packer Image Build
**Image**: Windows Server 2022 AL-Go Runner Image

---

## Support

For issues or questions:
1. Review logs in C:\vmss-runner-*.log
2. Run Test-VmssSetup.ps1 for diagnostics
3. Check image build logs for Install-RunnerSetupScript.ps1 execution
4. Verify Azure resources (Key Vault, Managed Identity) are configured correctly

"@

$readmePath = Join-Path $vmssScriptsDir "README.md"
$readme | Out-File -FilePath $readmePath -Encoding utf8 -Force
Write-Host "README written to: $readmePath"
#>

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
    Write-Host "  - $($_.Name) ($size)"
}

Write-Host "VMSS runner setup scripts installation complete"

# Run Pester tests to validate installation
Invoke-PesterTests -TestFile "VmssRunnerSetup"
