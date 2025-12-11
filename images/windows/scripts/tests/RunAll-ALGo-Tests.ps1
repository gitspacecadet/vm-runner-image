################################################################################
##  File:  RunAll-ALGo-Tests.ps1
##  Desc:  Run only tests relevant to the AL-Go minimal image.
##         This skips tests for tools not included in toolset-2022-algo.json.
##
##  Note:  Unlike the upstream RunAll-Tests.ps1 which uses Invoke-PesterTests "*",
##         we run a curated list of tests and generate testResults.xml directly.
##         This approach keeps Helpers.psm1 unchanged for easy upstream sync.
################################################################################

# Import required modules
# Pester must be imported BEFORE using [PesterConfiguration] type
Import-Module Pester -ErrorAction Stop

# Import ImageHelpers for Update-Environment function
Import-Module ImageHelpers -ErrorAction Stop

# Tests to run for AL-Go minimal image
# NOTE: DotnetSDK removed - .NET SDK download hangs on Akamai CDN
# BC containers include their own .NET runtime, AL-Go uses AL compiler from BC artifacts
$algoTests = @(
    "ActionArchiveCache",   # Actions cache
    "BcCache",              # BC container cache
    "CLI.Tools-ALGo",       # Azure CLI, GitHub CLI (AL-Go version - no AWS/Aliyun)
    "Docker-ALGo",          # Docker (without Compose test)
    "Git",                  # Git
    "Node",                 # Node.js
    "PowerShellModules",    # PowerShell modules
    "Shell",                # PowerShell Core
    "Toolset",              # General toolset validation
    "WindowsFeatures"       # Windows features
)

# Build the list of test file paths
$testPaths = $algoTests | ForEach-Object { "C:\image\tests\$_.Tests.ps1" }

# Verify all test files exist
$missingTests = $testPaths | Where-Object { -not (Test-Path $_) }
if ($missingTests) {
    Write-Error "Missing test files: $($missingTests -join ', ')"
    exit 1
}

Write-Host "Running AL-Go tests: $($algoTests -join ', ')" -ForegroundColor Cyan

# Configure Pester to run all AL-Go tests and generate testResults.xml
$configuration = [PesterConfiguration] @{
    Run = @{
        Path = $testPaths
        PassThru = $true
    }
    Output = @{
        Verbosity = "Detailed"
        RenderMode = "Plaintext"
    }
    TestResult = @{
        Enabled = $true
        OutputPath = "C:\image\tests\testResults.xml"
        OutputFormat = "NUnitXml"
    }
}

# Update environment variables without reboot
Update-Environment

# Run tests with error action stop to catch silent failures
$backupErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Stop"
$results = Invoke-Pester -Configuration $configuration
$ErrorActionPreference = $backupErrorActionPreference

Write-Host "AL-Go tests completed" -ForegroundColor Green

# Verify testResults.xml was generated
if (-not (Test-Path "C:\image\tests\testResults.xml")) {
    Write-Error "An error occurred: C:\image\tests\testResults.xml not found"
    exit 1
}

# Fail if any tests failed or no tests ran
if (-not ($results -and ($results.FailedCount -eq 0) -and ($results.PassedCount -gt 0))) {
    Write-Error "Test run has failed. Passed: $($results.PassedCount), Failed: $($results.FailedCount)"
    exit 1
}

Write-Host "All $($results.PassedCount) tests passed. Results saved to C:\image\tests\testResults.xml" -ForegroundColor Green
