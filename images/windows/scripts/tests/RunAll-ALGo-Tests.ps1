################################################################################
##  File:  RunAll-ALGo-Tests.ps1
##  Desc:  Run only tests relevant to the AL-Go minimal image.
##         This skips tests for tools not included in toolset-2022-algo.json.
################################################################################

# Tests to run for AL-Go minimal image
# NOTE: DotnetSDK removed - .NET SDK download hangs on Akamai CDN
# NOTE: Node removed - not needed for BC AL-Go workflows
# NOTE: Toolset removed - toolcache is empty, test finds 0 tests and fails
# BC containers include their own .NET runtime, AL-Go uses AL compiler from BC artifacts
$algoTests = @(
    "ActionArchiveCache",   # Actions cache
    "BcCache",              # BC container cache
    "CLI.Tools",            # Azure CLI, GitHub CLI
    "Docker-ALGo",          # Docker (without Compose test)
    "Git",                  # Git
    "PowerShellModules",    # PowerShell modules
    "Shell",                # PowerShell Core
    "WindowsFeatures"       # Windows features
)

# Run each test file
foreach ($test in $algoTests) {
    Write-Host "Running test: $test" -ForegroundColor Cyan
    Invoke-PesterTests -TestFile $test
}

Write-Host "AL-Go tests completed" -ForegroundColor Green
