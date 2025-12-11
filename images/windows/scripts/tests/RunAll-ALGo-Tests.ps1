################################################################################
##  File:  RunAll-ALGo-Tests.ps1
##  Desc:  Run only tests relevant to the AL-Go minimal image.
##         This skips tests for tools not included in toolset-2022-algo.json.
################################################################################

# Tests to run for AL-Go minimal image
$algoTests = @(
    "ActionArchiveCache",   # Actions cache
    "BcCache",              # BC container cache
    "CLI.Tools",            # Azure CLI, GitHub CLI
    "Docker-ALGo",          # Docker (without Compose test)
    "DotnetSDK",            # .NET SDK
    "Git",                  # Git
    "Node",                 # Node.js
    "PowerShellModules",    # PowerShell modules
    "Shell",                # PowerShell Core
    "Toolset",              # General toolset validation
    "WindowsFeatures"       # Windows features
)

# Run each test file
foreach ($test in $algoTests) {
    Write-Host "Running test: $test" -ForegroundColor Cyan
    Invoke-PesterTests -TestFile $test
}

Write-Host "AL-Go tests completed" -ForegroundColor Green
