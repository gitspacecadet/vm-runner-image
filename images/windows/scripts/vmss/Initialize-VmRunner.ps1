################################################################################
##  File:  Initialize-VmRunner.ps1
##  Desc:  Initialize GitHub Actions runner on VMSS instance
##
##  This script registers a VMSS instance as a GitHub Actions self-hosted runner
##  using pre-installed runner binaries from the VM image. Supports Azure Key
##  Vault integration for secure PAT retrieval via Managed Identity.
##
##  Version: 2.0
##  Enhanced: Key Vault integration, retry logic, diagnostics
################################################################################

param
(
    [Parameter(Mandatory = $false)]
    [string] $gitHubPAT = "",

    [Parameter(Mandatory = $true)]
    [string] $gitHubOrg,

    [Parameter(Mandatory = $false)]
    [string] $gitHubRepo = "",

    [Parameter(Mandatory = $false)]
    [string] $runnerLabels = "self-hosted,windows-latest-vmss,az-custom-image",

    [Parameter(Mandatory = $false)]
    [string] $keyVaultName = "",

    [Parameter(Mandatory = $false)]
    [string] $secretName = "github-pat"
)

Start-Transcript -Path "c:\vmss-runner-setup.log"
$errorActionPreference = "Stop"

Write-Host "=== VMSS GitHub Runner Setup (Image-Based) v2.0 ==="
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "GitHub Org: $gitHubOrg"
Write-Host "GitHub Repo: $gitHubRepo"
Write-Host "Runner Labels: $runnerLabels"
Write-Host "Key Vault: $keyVaultName"

try {
    # ========================================================================
    # STEP 1: Retrieve GitHub PAT (Key Vault or Parameter)
    # ========================================================================

    if ([string]::IsNullOrEmpty($gitHubPAT)) {
        if ([string]::IsNullOrEmpty($keyVaultName)) {
            throw "Either gitHubPAT parameter or keyVaultName must be provided"
        }

        Write-Host "Retrieving GitHub PAT from Azure Key Vault: $keyVaultName"

        try {
            # Get Managed Identity token for Key Vault
            Write-Host "Obtaining Managed Identity token..."
            $miTokenUrl = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net"
            $miResponse = Invoke-RestMethod -Uri $miTokenUrl -Method Get -Headers @{Metadata="true"} -TimeoutSec 10
            $accessToken = $miResponse.access_token
            Write-Host "Managed Identity token obtained"

            # Retrieve secret from Key Vault
            Write-Host "Retrieving secret '$secretName' from Key Vault..."
            $kvUrl = "https://$keyVaultName.vault.azure.net/secrets/$secretName`?api-version=7.4"
            $secretResponse = Invoke-RestMethod -Uri $kvUrl -Method Get -Headers @{Authorization="Bearer $accessToken"} -TimeoutSec 10
            $gitHubPAT = $secretResponse.value
            Write-Host "GitHub PAT retrieved successfully from Key Vault"

        } catch {
            Write-Error "Failed to retrieve GitHub PAT from Key Vault: $($_.Exception.Message)"
            Write-Host ""
            Write-Host "TROUBLESHOOTING TIPS:"
            Write-Host "1. Verify VMSS has Managed Identity enabled"
            Write-Host "2. Verify Managed Identity has 'Get' permission on Key Vault secrets"
            Write-Host "3. Verify Key Vault name is correct: $keyVaultName"
            Write-Host "4. Verify secret name exists: $secretName"
            Write-Host "5. Check Azure Metadata Service is accessible (169.254.169.254)"
            throw
        }
    } else {
        Write-Host "Using GitHub PAT from parameter"
    }

    if ([string]::IsNullOrEmpty($gitHubPAT)) {
        throw "GitHub PAT is empty after retrieval"
    }

    # ========================================================================
    # STEP 2: Verify pre-installed runner binaries
    # ========================================================================

    $runnerSourceDir = "C:\ProgramData\runner"
    if (!(Test-Path $runnerSourceDir)) {
        Write-Error "GitHub runner not found at $runnerSourceDir - image may not be built correctly"
        Write-Host ""
        Write-Host "TROUBLESHOOTING TIPS:"
        Write-Host "1. Verify you are using the correct custom image"
        Write-Host "2. Check image build logs for Install-GitHubRunner.ps1 execution"
        Write-Host "3. Verify Install-GitHubRunner.ps1 completed successfully during build"
        Write-Host "4. Run Test-VmssSetup.ps1 to diagnose image issues"
        exit 1
    }

    Write-Host "Found pre-installed runner at: $runnerSourceDir"

    # Check if we have the ZIP file or extracted files
    $zipFile = Get-ChildItem -Path $runnerSourceDir -Filter "actions-runner-win-x64-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
    $extractedFiles = Get-ChildItem -Path $runnerSourceDir -Filter "*.cmd" -ErrorAction SilentlyContinue

    if ($zipFile -and $extractedFiles.Count -eq 0) {
        Write-Host "Found runner ZIP file: $($zipFile.Name)"
        Write-Host "Extracting runner software..."

        # Extract the ZIP file to a temp location first
        $tempExtractDir = Join-Path $env:TEMP "RunnerExtract"
        if (Test-Path $tempExtractDir) {
            Remove-Item -Path $tempExtractDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null

        # Extract using .NET method for reliability
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipFile.FullName, $tempExtractDir)

        Write-Host "Runner software extracted successfully"
        $runnerSourceDir = $tempExtractDir
    } elseif ($extractedFiles.Count -gt 0) {
        Write-Host "GitHub runner software already extracted in image"
    } else {
        Write-Error "No GitHub runner ZIP file or extracted files found at $runnerSourceDir"
        Write-Host ""
        Write-Host "TROUBLESHOOTING TIPS:"
        Write-Host "1. Verify Install-GitHubRunner.ps1 ran successfully during image build"
        Write-Host "2. Check that runner files were not removed during image cleanup"
        Write-Host "3. Run Test-VmssSetup.ps1 to validate image setup"
        exit 1
    }

    # Debug: Show what's in the source directory
    Write-Host "Contents of source directory ${runnerSourceDir}:"
    Get-ChildItem -Path $runnerSourceDir | ForEach-Object {
        Write-Host "  $($_.Name) ($($_.GetType().Name))"
    }

    # ========================================================================
    # STEP 3: Setup runner directory
    # ========================================================================

    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "dd-MM-yy-HH-mm"
    $shortGuid = [guid]::NewGuid().ToString().Substring(0,4)
    $runnerName = "vmss-$timestamp-$shortGuid"
    $runnerDir = "C:\actions-runner\$runnerName"

    # Determine if we're registering for org or repo
    $isOrgRunner = [string]::IsNullOrEmpty($gitHubRepo)
    if ($isOrgRunner) {
        $githubApiUrl = "https://api.github.com/orgs/$gitHubOrg/actions/runners/registration-token"
        $githubRunnerUrl = "https://github.com/$gitHubOrg"
        Write-Host "Setting up runner for organization: $gitHubOrg"
    } else {
        $githubApiUrl = "https://api.github.com/repos/$gitHubOrg/$gitHubRepo/actions/runners/registration-token"
        $githubRunnerUrl = "https://github.com/$gitHubOrg/$gitHubRepo"
        Write-Host "Setting up runner for repository: $gitHubOrg/$gitHubRepo"
    }

    # ========================================================================
    # STEP 4: Get registration token with retry logic
    # ========================================================================

    Write-Host "Getting runner registration token from GitHub..."
    Write-Host "API URL: $githubApiUrl"

    $headers = @{
        Authorization = "token $gitHubPAT"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $maxRetries = 3
    $retryDelay = 2
    $runnerToken = $null

    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            $response = Invoke-RestMethod -Uri $githubApiUrl -Method Post -Headers $headers -TimeoutSec 30
            $runnerToken = $response.token
            Write-Host "Registration token obtained successfully"
            break
        } catch {
            if ($i -eq ($maxRetries - 1)) {
                Write-Error "Failed to get registration token after $maxRetries attempts: $($_.Exception.Message)"
                Write-Host ""
                Write-Host "TROUBLESHOOTING TIPS:"
                Write-Host "1. Verify GitHub PAT has 'repo' and 'admin:org' scopes"
                Write-Host "2. Check network connectivity to api.github.com"
                Write-Host "3. Verify organization name is correct: $gitHubOrg"
                if (-not $isOrgRunner) {
                    Write-Host "4. Verify repository name is correct: $gitHubRepo"
                    Write-Host "5. Verify repository exists in organization"
                }
                Write-Host "6. Check if GitHub is experiencing issues: https://www.githubstatus.com/"
                Write-Host "7. Review full error details in C:\vmss-runner-setup.log"
                Write-Host "8. Verify PAT has not expired"
                throw
            }

            Write-Host "Retry $($i+1)/$maxRetries after $retryDelay seconds... (Error: $($_.Exception.Message))"
            Start-Sleep -Seconds $retryDelay
            $retryDelay *= 2
        }
    }

    if ([string]::IsNullOrEmpty($runnerToken)) {
        throw "Registration token is empty after retrieval"
    }

    # ========================================================================
    # STEP 5: Copy runner files to unique directory
    # ========================================================================

    Write-Host "Setting up runner directory: $runnerDir"
    New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null

    # Copy ALL runner files and directories from the pre-installed location
    Write-Host "Copying runner files from: $runnerSourceDir"
    Copy-Item -Path "$runnerSourceDir\*" -Destination $runnerDir -Recurse -Force

    # Verify config.cmd exists
    $configPath = Join-Path $runnerDir "config.cmd"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.cmd not found at $configPath"
        Write-Host "Contents of runner directory:"
        Get-ChildItem -Path $runnerDir | ForEach-Object { Write-Host "  $($_.Name)" }
        Write-Host ""
        Write-Host "TROUBLESHOOTING TIPS:"
        Write-Host "1. Verify source directory had all runner files: $runnerSourceDir"
        Write-Host "2. Check disk space on C: drive"
        Write-Host "3. Verify no antivirus quarantine of runner files"
        Write-Host "4. Run Test-VmssSetup.ps1 to validate runner installation"
        exit 1
    }
    Write-Host "config.cmd found at: $configPath"

    # ========================================================================
    # STEP 6: Configure and start the runner
    # ========================================================================

    Set-Location $runnerDir
    Write-Host "Configuring runner: $runnerName"
    Write-Host "Runner URL: $githubRunnerUrl"
    Write-Host "Runner Labels: $runnerLabels"

    # Capture output from config.cmd for debugging
    Write-Host "Running config.cmd with parameters..."
    $configOutput = & .\config.cmd --unattended --url "$githubRunnerUrl" --token "$runnerToken" --name "$runnerName" --labels "$runnerLabels" --runAsService --windowslogonaccount "NT AUTHORITY\SYSTEM" 2>&1

    Write-Host "Config.cmd output:"
    Write-Host $configOutput
    Write-Host "Config.cmd exit code: $LASTEXITCODE"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Runner '$runnerName' configured and started successfully"
        Write-Host "VMSS instance is now ready for GitHub Actions!"
        Write-Host ""
        Write-Host "Runner Details:"
        Write-Host "  Name: $runnerName"
        Write-Host "  Directory: $runnerDir"
        Write-Host "  Organization: $gitHubOrg"
        if (-not $isOrgRunner) {
            Write-Host "  Repository: $gitHubRepo"
        }
        Write-Host "  Labels: $runnerLabels"
        Write-Host "  Service: actions.runner.$gitHubOrg.$runnerName"
    } else {
        Write-Error "Runner configuration failed with exit code $LASTEXITCODE"
        Write-Host ""
        Write-Host "TROUBLESHOOTING TIPS:"
        Write-Host "1. Check if registration token has expired (tokens expire after 1 hour)"
        Write-Host "2. Verify runner name is unique: $runnerName"
        Write-Host "3. Check if service account 'NT AUTHORITY\SYSTEM' has required permissions"
        Write-Host "4. Review config.cmd output above for specific errors"
        Write-Host "5. Check Windows Event Logs for service installation errors"
        exit 1
    }

} catch {
    Write-Error "Setup failed: $_"
    Write-Host ""
    Write-Host "Full error details:"
    Write-Host $_.Exception | Format-List -Force
    Write-Host ""
    Write-Host "For support, review the complete log: C:\vmss-runner-setup.log"
    exit 1
} finally {
    Stop-Transcript
}

Write-Host "=== Setup Complete ==="
