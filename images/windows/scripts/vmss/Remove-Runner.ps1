################################################################################
##  File:  Remove-Runner.ps1
##  Desc:  Gracefully unregister and remove GitHub Actions runner
##
##  This script is designed for VMSS scale-down events to properly unregister
##  the runner from GitHub before the instance is terminated. This prevents
##  orphaned runners in the GitHub organization.
##
##  Version: 1.0
################################################################################

param
(
    [Parameter(Mandatory = $false)]
    [string] $gitHubPAT = "",

    [Parameter(Mandatory = $false)]
    [string] $keyVaultName = "",

    [Parameter(Mandatory = $false)]
    [string] $secretName = "github-pat"
)

Start-Transcript -Path "c:\vmss-runner-removal.log"
$errorActionPreference = "Continue"  # Continue on errors to attempt full cleanup

Write-Host "=== VMSS GitHub Runner Removal ==="
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

try {
    # ========================================================================
    # STEP 1: Find runner service and directory
    # ========================================================================

    Write-Host "Searching for GitHub runner service..."
    $runnerService = Get-Service | Where-Object { $_.Name -like "actions.runner.*" } | Select-Object -First 1

    if (-not $runnerService) {
        Write-Host "No runner service found - may already be removed"
        Write-Host "Checking for runner directories..."

        # Look for runner directories
        $runnerBaseDir = "C:\actions-runner"
        if (Test-Path $runnerBaseDir) {
            $runnerDirs = Get-ChildItem -Path $runnerBaseDir -Directory
            Write-Host "Found $($runnerDirs.Count) runner directories in $runnerBaseDir"
        } else {
            Write-Host "No runner base directory found at $runnerBaseDir"
            Write-Host "Runner appears to be already removed"
            exit 0
        }
    } else {
        Write-Host "Found runner service: $($runnerService.Name)"
        Write-Host "Service status: $($runnerService.Status)"
    }

    # ========================================================================
    # STEP 2: Stop runner service if running
    # ========================================================================

    if ($runnerService -and $runnerService.Status -eq 'Running') {
        Write-Host "Stopping runner service..."
        try {
            Stop-Service -Name $runnerService.Name -Force -ErrorAction Stop
            Write-Host "Service stopped successfully"

            # Wait for service to fully stop
            $timeout = 30
            $elapsed = 0
            while ((Get-Service -Name $runnerService.Name).Status -ne 'Stopped' -and $elapsed -lt $timeout) {
                Start-Sleep -Seconds 1
                $elapsed++
            }

            if ((Get-Service -Name $runnerService.Name).Status -eq 'Stopped') {
                Write-Host "Service fully stopped after $elapsed seconds"
            } else {
                Write-Host "WARNING: Service did not stop within $timeout seconds"
            }
        } catch {
            Write-Host "ERROR stopping service: $($_.Exception.Message)"
        }
    }

    # ========================================================================
    # STEP 3: Determine runner directory
    # ========================================================================

    $runnerDir = $null

    if ($runnerService) {
        # Extract directory from service path
        $servicePath = (Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $runnerService.Name }).PathName
        if ($servicePath -match '([C-Z]:\\[^"]+)\\bin\\') {
            $runnerDir = $matches[1]
            Write-Host "Runner directory from service: $runnerDir"
        }
    }

    # Fallback: find most recent runner directory
    if (-not $runnerDir -or -not (Test-Path $runnerDir)) {
        $runnerBaseDir = "C:\actions-runner"
        if (Test-Path $runnerBaseDir) {
            $runnerDir = Get-ChildItem -Path $runnerBaseDir -Directory |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName

            if ($runnerDir) {
                Write-Host "Using most recent runner directory: $runnerDir"
            }
        }
    }

    if (-not $runnerDir) {
        Write-Host "ERROR: Could not determine runner directory"
        exit 1
    }

    if (-not (Test-Path $runnerDir)) {
        Write-Host "ERROR: Runner directory does not exist: $runnerDir"
        exit 1
    }

    # ========================================================================
    # STEP 4: Get GitHub PAT (Key Vault or Parameter)
    # ========================================================================

    if ([string]::IsNullOrEmpty($gitHubPAT)) {
        if ([string]::IsNullOrEmpty($keyVaultName)) {
            Write-Host "WARNING: No GitHub PAT or Key Vault provided"
            Write-Host "Will attempt config.cmd remove without token (may fail for org runners)"
        } else {
            Write-Host "Retrieving GitHub PAT from Azure Key Vault: $keyVaultName"

            try {
                # Get Managed Identity token
                $miTokenUrl = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net"
                $miResponse = Invoke-RestMethod -Uri $miTokenUrl -Method Get -Headers @{Metadata="true"} -TimeoutSec 10
                $accessToken = $miResponse.access_token

                # Retrieve secret from Key Vault
                $kvUrl = "https://$keyVaultName.vault.azure.net/secrets/$secretName`?api-version=7.4"
                $secretResponse = Invoke-RestMethod -Uri $kvUrl -Method Get -Headers @{Authorization="Bearer $accessToken"} -TimeoutSec 10
                $gitHubPAT = $secretResponse.value
                Write-Host "GitHub PAT retrieved from Key Vault"
            } catch {
                Write-Host "ERROR retrieving PAT from Key Vault: $($_.Exception.Message)"
                Write-Host "Will attempt removal without PAT"
            }
        }
    }

    # ========================================================================
    # STEP 5: Run config.cmd remove
    # ========================================================================

    Set-Location $runnerDir
    $configCmd = Join-Path $runnerDir "config.cmd"

    if (Test-Path $configCmd) {
        Write-Host "Running config.cmd remove..."

        if (-not [string]::IsNullOrEmpty($gitHubPAT)) {
            Write-Host "Using PAT for removal"
            $removeOutput = & .\config.cmd remove --token $gitHubPAT 2>&1
        } else {
            Write-Host "Attempting removal without PAT"
            $removeOutput = & .\config.cmd remove 2>&1
        }

        Write-Host "config.cmd remove output:"
        Write-Host $removeOutput
        Write-Host "Exit code: $LASTEXITCODE"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Runner unregistered successfully"
        } else {
            Write-Host "WARNING: config.cmd remove exited with code $LASTEXITCODE"
            Write-Host "Proceeding with directory cleanup anyway"
        }
    } else {
        Write-Host "WARNING: config.cmd not found at $configCmd"
        Write-Host "Cannot unregister from GitHub - proceeding with local cleanup"
    }

    # ========================================================================
    # STEP 6: Remove runner directory
    # ========================================================================

    Write-Host "Removing runner directory: $runnerDir"

    try {
        # First, try to remove service if it still exists
        if ($runnerService) {
            try {
                $serviceName = $runnerService.Name
                sc.exe delete $serviceName
                Write-Host "Service $serviceName deleted"
            } catch {
                Write-Host "WARNING: Could not delete service: $($_.Exception.Message)"
            }
        }

        # Remove directory
        if (Test-Path $runnerDir) {
            Remove-Item -Path $runnerDir -Recurse -Force -ErrorAction Stop
            Write-Host "Runner directory removed successfully"
        }

        # Check if base directory is empty and remove it
        $runnerBaseDir = "C:\actions-runner"
        if (Test-Path $runnerBaseDir) {
            $remainingDirs = Get-ChildItem -Path $runnerBaseDir -Directory
            if ($remainingDirs.Count -eq 0) {
                Remove-Item -Path $runnerBaseDir -Force
                Write-Host "Removed empty base directory: $runnerBaseDir"
            }
        }

    } catch {
        Write-Host "ERROR removing runner directory: $($_.Exception.Message)"
        exit 1
    }

    Write-Host "Runner removal completed successfully"

} catch {
    Write-Host "ERROR during runner removal: $_"
    Write-Host $_.Exception | Format-List -Force
    exit 1
} finally {
    Stop-Transcript
}

Write-Host "=== Removal Complete ==="
Write-Host "Log file: C:\vmss-runner-removal.log"
exit 0
